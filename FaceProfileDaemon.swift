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
import os

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
    private let logger = Logger(subsystem: "com.user.face-profile-daemon", category: "main")

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
    private let karabinerProcessQueue = DispatchQueue(label: "com.facedetector.karabinerCli", qos: .userInitiated)

    // Populated once at startup; used to verify sender device in HID callback
    private var builtinLocationIDs: Set<Int> = []
    private var hidManager: IOHIDManager? = nil
    private var hidThread: Thread?
    private var lastHIDEventTime: CFAbsoluteTime = 0
    private var detectionTask: Task<Void, Never>?
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    
    init(detector: FaceDetecting = FacePresenceDetector()) {
        self.detector = detector
    }

    // MARK: - Entry

    func run() {
        if !FileManager.default.fileExists(atPath: karabinerCLIPath) {
            logger.critical("karabiner_cli not found at \(karabinerCLIPath, privacy: .public)")
            exit(1)
        }

        builtinLocationIDs = enumerateBuiltinSPILocationIDs()
        logger.info("Built-in SPI HID location IDs: \(self.builtinLocationIDs.description, privacy: .public)")

        installHIDMonitor()

        detectionTask = Task { await faceDetectionLoop() }

        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            self?.logger.info("Received SIGTERM, shutting down...")
            self?.detectionTask?.cancel()
            self?.karabinerProcessQueue.sync {}
            CFRunLoopStop(CFRunLoopGetMain())
        }
        sigterm.resume()
        self.sigtermSource = sigterm

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            self?.logger.info("Received SIGINT, shutting down...")
            self?.detectionTask?.cancel()
            self?.karabinerProcessQueue.sync {}
            CFRunLoopStop(CFRunLoopGetMain())
        }
        sigint.resume()
        self.sigintSource = sigint

        logger.info("Daemon started — poll every \(Int(pollInterval))s, ghost after \(Int(noFaceTimeout))s no-face")
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

        hidManager = mgr

        hidThread = Thread { [weak self] in
            IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            if kr != kIOReturnSuccess {
                // HID monitoring is non-functional: noFaceStreak will not reset on
                // keyboard/trackpad activity; only face-detection polls drive state.
                self?.logger.warning("IOHIDManager open returned 0x\(String(kr, radix: 16), privacy: .public)")
            }
            CFRunLoopRun()
        }
        hidThread?.name = "com.user.face-profile-daemon.hid"
        hidThread?.start()
    }

    deinit {
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidThread?.cancel()
    }

    // Called from IOHIDManager callback (main RunLoop thread)
    func onBuiltinHIDActivity(sender: UnsafeMutableRawPointer?) {
        let now = CFAbsoluteTimeGetCurrent()

        if builtinLocationIDs.isEmpty {
            logger.warning("builtinLocationIDs is empty; ignoring HID activity to prevent failing open.")
            return
        }

        guard let sender else {
            return
        }

        let cfSender = Unmanaged<CFTypeRef>.fromOpaque(sender).takeUnretainedValue()
        guard CFGetTypeID(cfSender) == IOHIDDeviceGetTypeID() else {
            return
        }

        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        guard let cf = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString),
              let n = cf as? NSNumber,
              builtinLocationIDs.contains(n.intValue) else {
            return  // event from a non-built-in device (or missing location ID); discard
        }
        stateQueue.async {
            if now - self.lastHIDEventTime < 2.0 {
                return
            }
            self.lastHIDEventTime = now

            let action = self.stateMachine.onHIDEvent()
            self.handleAction(action)
        }
    }

    // MARK: - Face detection poll loop (Swift concurrency Task)

    private func faceDetectionLoop() async {
        var consecutiveFailures = 0
        while true {
            do {
                let detected = try await detector.detectFace()
                consecutiveFailures = 0
                if detected {
                    stateQueue.async {
                        let action = self.stateMachine.onFaceDetected()
                        self.handleAction(action)
                        self.logger.info("Face detected → \(profileKeyboard, privacy: .public)")
                    }
                } else {
                    stateQueue.async {
                        let action = self.stateMachine.onNoFace()
                        self.logger.info("No face. Streak: \(Int(self.stateMachine.noFaceStreak))s / \(Int(noFaceTimeout))s")
                        self.handleAction(action)
                    }
                }
            } catch {
                consecutiveFailures += 1
                let nsError = error as NSError
                logger.error("Detection error: \(error.localizedDescription, privacy: .public) (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))")
                if consecutiveFailures >= 5 {
                    stateQueue.async {
                        let action = self.stateMachine.onNoFace()
                        self.handleAction(action)
                    }
                }
            }
            
            let sleepTime: Double
            if consecutiveFailures >= 5 {
                let backoffMultiplier = pow(2.0, Double(min(consecutiveFailures - 5, 8)))
                sleepTime = min(300.0, pollInterval * backoffMultiplier)
            } else {
                sleepTime = pollInterval
            }
            
            do {
                try await Task.sleep(for: .seconds(sleepTime))
            } catch {
                logger.debug("Face detection loop cancelled: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    // MARK: - Profile switching

    private func handleAction(_ action: ProfileStateMachine.Action) {
        if case .switchProfile(let profile) = action {
            logger.info("Switching to '\(profile, privacy: .public)'")
            executeProfileSwitch(profile)
        }
    }

    private func executeProfileSwitch(_ profile: String) {
        let capturedProfile = profile
        karabinerProcessQueue.async { [weak self] in
            guard let self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: karabinerCLIPath)
            proc.arguments = ["--select-profile", capturedProfile]
            proc.standardOutput = FileHandle.nullDevice

            let semaphore = DispatchSemaphore(value: 0)
            proc.terminationHandler = { _ in semaphore.signal() }

            do {
                try proc.run()
                let result = semaphore.wait(timeout: .now() + 5.0)
                if result == .timedOut {
                    proc.terminate()
                    self.stateQueue.async {
                        self.logger.error("[FPD] karabiner_cli timed out for '\(capturedProfile, privacy: .public)'")
                        self.stateMachine.onSwitchFailed()
                    }
                } else if proc.terminationStatus != 0 {
                    self.stateQueue.async {
                        self.logger.error("[FPD] karabiner_cli failed (exit \(proc.terminationStatus)) for '\(capturedProfile, privacy: .public)'")
                        self.stateMachine.onSwitchFailed()
                    }
                } else {
                    self.logger.debug("[FPD] karabiner_cli succeeded for '\(capturedProfile, privacy: .public)'")
                }
            } catch {
                self.stateQueue.async {
                    self.logger.error("Failed to launch karabiner_cli: \(error.localizedDescription, privacy: .public)")
                    self.stateMachine.onSwitchFailed()
                }
            }
        }
    }
}

// MARK: - Entry point

let daemon = FaceProfileDaemon()
daemon.run()
