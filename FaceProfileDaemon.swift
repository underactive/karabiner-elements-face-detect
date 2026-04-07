// FaceProfileDaemon.swift
// Run standalone:  swift FaceProfileDaemon.swift
// Compile binary:  swiftc -O FaceProfileDaemon.swift -o face-profile-daemon
//
// FacePresenceDetector is embedded inline below so this file is self-contained.
// When compiling the release binary the Makefile compiles only this file.

import Foundation
import AVFoundation
import Vision
import IOKit
import IOKit.hid

// MARK: - Embedded FacePresenceDetector
// (canonical source: FacePresenceDetector.swift)

public enum FaceDetectorError: Error, LocalizedError {
    case cameraUnavailable
    case accessDenied
    case captureFailed
    case visionError(Error)
    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable:  return "Built-in FaceTime camera not found"
        case .accessDenied:       return "Camera access denied — check System Settings › Privacy › Camera"
        case .captureFailed:      return "No pixel buffer received from camera"
        case .visionError(let e): return "Vision analysis failed: \(e.localizedDescription)"
        }
    }
}

public final class FacePresenceDetector {
    public init() {}
    public func detectFace() async throws -> Bool {
        try await requestAccess()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw FaceDetectorError.cameraUnavailable
        }
        let pixelBuffer = try await SingleFrameCapturer.capture(from: device)
        return try runVision(on: pixelBuffer)
    }
    private func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw FaceDetectorError.accessDenied
            }
        case .denied, .restricted: throw FaceDetectorError.accessDenied
        @unknown default:          throw FaceDetectorError.accessDenied
        }
    }
    private func runVision(on pixelBuffer: CVPixelBuffer) throws -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { throw FaceDetectorError.visionError(error) }
        return (request.results ?? []).contains { $0.confidence >= 0.5 }
    }
}

private final class SingleFrameCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let continuation: CheckedContinuation<CVPixelBuffer, Error>
    private let session = AVCaptureSession()
    private var didCapture = false
    private var selfRetain: SingleFrameCapturer?
    private init(continuation: CheckedContinuation<CVPixelBuffer, Error>) {
        self.continuation = continuation
    }
    static func capture(from device: AVCaptureDevice) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { cont in
            let c = SingleFrameCapturer(continuation: cont)
            c.selfRetain = c
            c.start(device: device)
        }
    }
    private func start(device: AVCaptureDevice) {
        session.sessionPreset = .medium
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return finish(FaceDetectorError.cameraUnavailable) }
            session.addInput(input)
        } catch { return finish(FaceDetectorError.cameraUnavailable) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { return finish(FaceDetectorError.cameraUnavailable) }
        session.addOutput(output)
        let q = DispatchQueue(label: "com.facedetector.capture", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: q)
        session.startRunning()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !didCapture else { return }
        didCapture = true
        session.stopRunning()
        let retain = selfRetain; selfRetain = nil
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            continuation.resume(returning: pb)
        } else {
            continuation.resume(throwing: FaceDetectorError.captureFailed)
        }
        _ = retain
    }
    private func finish(_ error: Error) { selfRetain = nil; continuation.resume(throwing: error) }
}

// MARK: - State Machine
//
//  ┌──────────────────────────────────────────────────────────────────────┐
//  │                    Face Profile State Machine                         │
//  │                                                                        │
//  │         face detected ──────────────────────────────────────┐         │
//  │         built-in HID event ─────────────────────────────────┤         │
//  │                                                              ▼         │
//  │   ┌──────────────────┐                          ┌──────────────────┐  │
//  │   │   👻  ghostActive │◀─── noFaceStreak ≥ 120s ─┤  ⌨️  kbdActive  │  │
//  │   │  (profile: 👻)   │                          │  (profile: ⌨️)  │  │
//  │   └──────────────────┘                          └──────────────────┘  │
//  │                                                                        │
//  │  noFaceStreak: incremented by pollInterval (15 s) each no-face poll   │
//  │               reset to 0 on face detected OR built-in HID event       │
//  │  Profile switches are skipped when cachedProfile == target (no-op)    │
//  └──────────────────────────────────────────────────────────────────────┘

// MARK: - Constants

private let karabinerCLIPath =
    "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
private let profileKeyboard = "⌨️"
private let profileGhost    = "👻"
private let pollInterval: Double = 30    // seconds between face detection polls
private let noFaceTimeout: Double = 120  // seconds before switching to 👻

// MARK: - HID callback (top-level C-compatible function)
//
// Why IOHIDManager instead of CGEventTap:
// CGEvent provides no API to query the originating IOKit device ID or transport
// string. IOHIDManager with kIOHIDTransportKey == "SPI" natively scopes delivery
// to built-in keyboard and trackpad only — no USB/Bluetooth events slip through.

private func fpdHIDInputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<FaceProfileDaemon>.fromOpaque(context)
        .takeUnretainedValue()
        .onBuiltinHIDActivity(sender: sender)
}

// MARK: - Daemon

final class FaceProfileDaemon {
    private let detector = FacePresenceDetector()

    // State machine — pure logic extracted for testability.
    // Accessed from both the Swift concurrency poll task and the IOHIDManager
    // RunLoop callback. For a 30 s poll interval the window for a missed update
    // is harmless; production code should use an actor.
    private var stateMachine = ProfileStateMachine(
        profileKeyboard: profileKeyboard,
        profileGhost: profileGhost,
        pollInterval: pollInterval,
        noFaceTimeout: noFaceTimeout
    )

    // Populated once at startup; used to verify sender device in HID callback
    private var builtinLocationIDs: Set<Int> = []
    private var hidManager: IOHIDManager? = nil

    // MARK: - Entry

    func run() {
        builtinLocationIDs = enumerateBuiltinSPILocationIDs()
        stderr("[FPD] Built-in SPI HID location IDs: \(builtinLocationIDs)")

        installHIDMonitor()

        Task { await faceDetectionLoop() }

        stderr("[FPD] Daemon started — poll every \(Int(pollInterval))s, ghost after \(Int(noFaceTimeout))s no-face")
        RunLoop.main.run()
    }

    // MARK: - IOKit: enumerate built-in SPI device location IDs (once at startup)

    private func enumerateBuiltinSPILocationIDs() -> Set<Int> {
        var ids = Set<Int>()
        // Build matching dict manually to avoid CFMutableDictionary bridging quirks.
        // "IOProviderClass" is the key IOServiceMatching() sets internally.
        let matching = NSMutableDictionary()
        matching["IOProviderClass"] = "IOHIDDevice"
        matching[kIOHIDTransportKey as String] = "SPI"

        var iter = io_iterator_t(0)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iter) == KERN_SUCCESS else {
            return ids
        }
        defer { IOObjectRelease(iter) }

        var svc = IOIteratorNext(iter)
        while svc != IO_OBJECT_NULL {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(iter) }
            if let cf = IORegistryEntryCreateCFProperty(
                svc, kIOHIDLocationIDKey as CFString, kCFAllocatorDefault, 0) {
                let val = cf.takeRetainedValue()
                if let n = val as? NSNumber { ids.insert(n.intValue) }
            }
        }
        return ids
    }

    // MARK: - IOHIDManager: monitor built-in keyboard/trackpad events

    private func installHIDMonitor() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [kIOHIDTransportKey as String: "SPI"] as CFDictionary
        IOHIDManagerSetDeviceMatching(mgr, match)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, fpdHIDInputCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            stderr("[FPD] Warning: IOHIDManager open returned 0x\(String(kr, radix: 16))")
        }
        hidManager = mgr
    }

    // Called from IOHIDManager callback (main RunLoop thread)
    func onBuiltinHIDActivity(sender: UnsafeMutableRawPointer?) {
        // Belt-and-suspenders: verify sender device is in our pre-enumerated set
        if let sender {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            if let cf = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString),
               let n = cf as? NSNumber,
               !builtinLocationIDs.isEmpty,
               !builtinLocationIDs.contains(n.intValue) {
                return  // event from a non-built-in device; discard
            }
        }
        handleAction(stateMachine.onHIDEvent())
    }

    // MARK: - Face detection poll loop (Swift concurrency Task)

    private func faceDetectionLoop() async {
        while true {
            do {
                let detected = try await detector.detectFace()
                if detected {
                    let action = stateMachine.onFaceDetected()
                    handleAction(action)
                    stderr("[FPD] Face detected → \(profileKeyboard)")
                } else {
                    let action = stateMachine.onNoFace()
                    stderr("[FPD] No face. Streak: \(Int(stateMachine.noFaceStreak))s / \(Int(noFaceTimeout))s")
                    handleAction(action)
                }
            } catch {
                stderr("[FPD] Detection error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: - Profile switching

    private func handleAction(_ action: ProfileStateMachine.Action) {
        if case .switchProfile(let profile) = action {
            stderr("[FPD] Switching to '\(profile)'")
            executeProfileSwitch(profile)
        }
    }

    private func executeProfileSwitch(_ profile: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: karabinerCLIPath)
        proc.arguments = ["--select-profile", profile]
        proc.standardOutput = FileHandle.nullDevice

        let capturedProfile = profile
        proc.terminationHandler = { [weak self] p in
            if p.terminationStatus != 0 {
                self?.stderr("[FPD] karabiner_cli exit \(p.terminationStatus) for '\(capturedProfile)'")
                self?.stateMachine.onSwitchFailed()
            }
        }

        do {
            try proc.run()
        } catch {
            stderr("[FPD] Failed to launch karabiner_cli: \(error)")
            stateMachine.onSwitchFailed()
        }
    }

    private func stderr(_ msg: String) {
        fputs("\(msg)\n", Foundation.stderr)
    }
}

// MARK: - Entry point

let daemon = FaceProfileDaemon()
daemon.run()
