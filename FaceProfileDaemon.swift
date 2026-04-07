// FaceProfileDaemon.swift
// Compile binary:  make compile
//
// Requires FacePresenceDetector.swift and ProfileStateMachine.swift — the
// Makefile compiles all three files together.

import Foundation
import AVFoundation
import Vision
import IOKit
import IOKit.hid

// MARK: - FaceDetecting Protocol

public protocol FaceDetecting {
    func detectFace() async throws -> Bool
}

extension FacePresenceDetector: FaceDetecting {}

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
//  │  noFaceStreak: incremented by pollInterval each no-face poll                │
//  │               reset to 0 on face detected OR built-in HID event       │
//  │  Profile switches are skipped when cachedProfile == target (no-op)    │
//  └──────────────────────────────────────────────────────────────────────┘

// MARK: - Constants

private let karabinerCLIPath =
    "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
// Must match Karabiner-Elements profile names exactly (case-sensitive, emoji included).
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
    private let detector: FaceDetecting

    // State machine — pure logic extracted for testability.
    // Accessed from both the Swift concurrency poll task and the IOHIDManager
    // RunLoop callback. Synchronized via stateQueue.
    private var stateMachine = ProfileStateMachine(
        profileKeyboard: profileKeyboard,
        profileGhost: profileGhost,
        pollInterval: pollInterval,
        noFaceTimeout: noFaceTimeout
    )
    private let stateQueue = DispatchQueue(label: "com.facedetector.stateMachine")

    // Populated once at startup; used to verify sender device in HID callback
    private var builtinLocationIDs: Set<Int> = []
    private var hidManager: IOHIDManager? = nil
    
    init(detector: FaceDetecting = FacePresenceDetector()) {
        self.detector = detector
    }

    // MARK: - Entry

    func run() {
        if !FileManager.default.fileExists(atPath: karabinerCLIPath) {
            stderr("[FPD] Critical error: karabiner_cli not found at \(karabinerCLIPath)")
            exit(1)
        }

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
        let transports = ["SPI", "AppleHID", "Internal"]
        for transport in transports {
            let matching = NSMutableDictionary()
            matching["IOProviderClass"] = "IOHIDDevice"
            matching[kIOHIDTransportKey as String] = transport

            var iter = io_iterator_t(0)
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iter) == KERN_SUCCESS {
                var svc = IOIteratorNext(iter)
                while svc != IO_OBJECT_NULL {
                    if let cf = IORegistryEntryCreateCFProperty(svc, kIOHIDLocationIDKey as CFString, kCFAllocatorDefault, 0) {
                        let val = cf.takeRetainedValue()
                        if let n = val as? NSNumber { ids.insert(n.intValue) }
                    }
                    IOObjectRelease(svc)
                    svc = IOIteratorNext(iter)
                }
                IOObjectRelease(iter)
            }
        }
        return ids
    }

    // MARK: - IOHIDManager: monitor built-in keyboard/trackpad events

    private func installHIDMonitor() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let transports = ["SPI", "AppleHID", "Internal"]
        let matches = transports.map { ["IOProviderClass": "IOHIDDevice", kIOHIDTransportKey as String: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, fpdHIDInputCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            // HID monitoring is non-functional: noFaceStreak will not reset on
            // keyboard/trackpad activity; only face-detection polls drive state.
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
        stateQueue.async {
            let action = self.stateMachine.onHIDEvent()
            self.handleAction(action)
        }
    }

    // MARK: - Face detection poll loop (Swift concurrency Task)

    private func faceDetectionLoop() async {
        while true {
            do {
                let detected = try await detector.detectFace()
                if detected {
                    stateQueue.async {
                        let action = self.stateMachine.onFaceDetected()
                        self.handleAction(action)
                        self.stderr("[FPD] Face detected → \(profileKeyboard)")
                    }
                } else {
                    stateQueue.async {
                        let action = self.stateMachine.onNoFace()
                        self.stderr("[FPD] No face. Streak: \(Int(self.stateMachine.noFaceStreak))s / \(Int(noFaceTimeout))s")
                        self.handleAction(action)
                    }
                }
            } catch {
                stderr("[FPD] Detection error: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(pollInterval))
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
                self?.stateQueue.async {
                    self?.stderr("[FPD] karabiner_cli exit \(p.terminationStatus) for '\(capturedProfile)'")
                    self?.stateMachine.onSwitchFailed()
                }
            }
        }

        do {
            try proc.run()
        } catch {
            stateQueue.async {
                self.stderr("[FPD] Failed to launch karabiner_cli: \(error)")
                self.stateMachine.onSwitchFailed()
            }
        }
    }

    private func stderr(_ msg: String) {
        fputs("\(msg)\n", Foundation.stderr)
    }
}

// MARK: - Entry point

let daemon = FaceProfileDaemon()
daemon.run()
