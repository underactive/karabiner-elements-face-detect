// FaceProfileDaemon.swift
// Compile binary:  make compile
//
// Requires FacePresenceDetector.swift, ProfileStateMachine.swift, and
// FaceProfileEntry.swift — the Makefile compiles all four sources together.

import Foundation
import AVFoundation
import Vision
import IOKit
import IOKit.hid
import Security
import os

private let karabinerCLIPath =
    "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

private func verifyCodeSignature(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else {
        return false
    }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          let req = requirement else {
        return false
    }
    return SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(), req, nil) == errSecSuccess
}

// MARK: - FaceDetecting Protocol

public protocol FaceDetecting {
    func detectFace() async throws -> Bool
}

extension FacePresenceDetector: FaceDetecting {}

// MARK: - Karabiner CLI seam

enum KarabinerExecutionResult: Equatable {
    case success
    case timedOut
    case nonZeroExit(Int32)
    case launchFailed(String)
}

protocol KarabinerCLIExecuting: AnyObject {
    func runSelectProfile(_ profile: String) -> KarabinerExecutionResult
}

final class DefaultKarabinerCLIExecutor: KarabinerCLIExecuting {
    private let cliPath: String

    init(cliPath: String = karabinerCLIPath) {
        self.cliPath = cliPath
    }

    func runSelectProfile(_ profile: String) -> KarabinerExecutionResult {
        guard verifyCodeSignature(atPath: cliPath) else {
            return .launchFailed("Code signature verification failed for \(cliPath)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["--select-profile", profile]
        proc.standardOutput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in semaphore.signal() }

        do {
            try proc.run()
            let result = semaphore.wait(timeout: .now() + 5.0)
            if result == .timedOut {
                proc.terminate()
                return .timedOut
            }
            if proc.terminationStatus != 0 {
                return .nonZeroExit(proc.terminationStatus)
            }
            return .success
        } catch {
            return .launchFailed(error.localizedDescription)
        }
    }
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
//  │  noFaceStreak: incremented by pollInterval each no-face poll                │
//  │               reset to 0 on face detected OR built-in HID event       │
//  │  Profile switches are skipped when cachedProfile == target (no-op)    │
//  └──────────────────────────────────────────────────────────────────────┘

// MARK: - HID callback (top-level C-compatible function)
//
// Why IOHIDManager instead of CGEventTap:
// CGEvent provides no API to query the originating IOKit device ID or transport
// string. IOHIDManager with kIOHIDTransportKey == "SPI" natively scopes delivery
// to built-in keyboard and trackpad only — no USB/Bluetooth events slip through.

private class HIDContext {
    weak var daemon: FaceProfileDaemon?
    init(_ daemon: FaceProfileDaemon) { self.daemon = daemon }
}

private func fpdHIDInputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<HIDContext>.fromOpaque(context)
        .takeUnretainedValue()
        .daemon?.onBuiltinHIDActivity(sender: sender)
}

// MARK: - Daemon

final class FaceProfileDaemon {
    private let profileKeyboard: String
    private let profileGhost: String
    private let pollInterval: Double
    private let noFaceTimeout: Double
    private let detector: FaceDetecting
    private let karabiner: KarabinerCLIExecuting
    private let logger = Logger(subsystem: "com.user.face-profile-daemon", category: "main")

    // State machine — pure logic extracted for testability.
    // Accessed from both the Swift concurrency poll task and the IOHIDManager
    // RunLoop callback. Synchronized via stateQueue.
    private var stateMachine: ProfileStateMachine
    private let stateQueue = DispatchQueue(label: "com.facedetector.stateMachine")
    private let karabinerProcessQueue = DispatchQueue(label: "com.facedetector.karabinerCli", qos: .userInitiated)

    // Populated once at startup; used to verify sender device in HID callback
    private var builtinLocationIDs: Set<Int> = []
    private var hidManager: IOHIDManager? = nil
    private var hidThread: Thread?
    private var hidContextPtr: UnsafeMutableRawPointer?
    private var lastHIDEventTime: CFAbsoluteTime = 0
    private var detectionTask: Task<Void, Never>?
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    
    init(
        detector: FaceDetecting = FacePresenceDetector(),
        karabiner: KarabinerCLIExecuting = DefaultKarabinerCLIExecutor(),
        profileKeyboard: String = "⌨️",
        profileGhost: String = "👻",
        pollInterval: Double = 30,
        noFaceTimeout: Double = 120
    ) {
        self.detector = detector
        self.karabiner = karabiner
        self.profileKeyboard = profileKeyboard
        self.profileGhost = profileGhost
        self.pollInterval = pollInterval
        self.noFaceTimeout = noFaceTimeout
        self.stateMachine = ProfileStateMachine(
            profileKeyboard: profileKeyboard,
            profileGhost: profileGhost,
            pollInterval: pollInterval,
            noFaceTimeout: noFaceTimeout
        )
    }

    // MARK: - Entry

    func run() {
        if !FileManager.default.fileExists(atPath: karabinerCLIPath) {
            logger.critical("karabiner_cli not found at \(karabinerCLIPath, privacy: .public)")
            exit(1)
        }
        if !verifyCodeSignature(atPath: karabinerCLIPath) {
            logger.critical("karabiner_cli at \(karabinerCLIPath, privacy: .public) failed code signature verification")
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
            self?.shutdown()
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
            self?.shutdown()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        sigint.resume()
        self.sigintSource = sigint

        logger.info("Daemon started — poll every \(Int(pollInterval))s, ghost after \(Int(noFaceTimeout))s no-face")
        CFRunLoopRun()
    }

    func shutdown() {
        if let mgr = hidManager {
            IOHIDManagerRegisterInputValueCallback(mgr, nil, nil)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        if let ctx = hidContextPtr {
            Unmanaged<HIDContext>.fromOpaque(ctx).release()
            hidContextPtr = nil
        }
        hidThread?.cancel()
        hidThread = nil
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
                defer { IOObjectRelease(iter) }
                var svc = IOIteratorNext(iter)
                while svc != IO_OBJECT_NULL {
                    let current = svc
                    svc = IOIteratorNext(iter)
                    defer { IOObjectRelease(current) }
                    if let cf = IORegistryEntryCreateCFProperty(current, kIOHIDLocationIDKey as CFString, kCFAllocatorDefault, 0) {
                        let val = cf.takeRetainedValue()
                        if let n = val as? NSNumber { ids.insert(n.intValue) }
                    }
                }
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

        let contextObj = HIDContext(self)
        let ctx = Unmanaged.passRetained(contextObj).toOpaque()
        self.hidContextPtr = ctx
        IOHIDManagerRegisterInputValueCallback(mgr, fpdHIDInputCallback, ctx)

        hidManager = mgr

        hidThread = Thread { [weak self] in
            guard let self = self else { return }
            let runLoop = CFRunLoopGetCurrent()
            IOHIDManagerScheduleWithRunLoop(mgr, runLoop, CFRunLoopMode.defaultMode.rawValue)
            let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            if kr != kIOReturnSuccess {
                // HID monitoring is non-functional: noFaceStreak will not reset on
                // keyboard/trackpad activity; only face-detection polls drive state.
                self.logger.warning("IOHIDManager open returned 0x\(String(kr, radix: 16), privacy: .public)")
            }
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.5, false)
            }
            IOHIDManagerUnscheduleFromRunLoop(mgr, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        hidThread?.name = "com.user.face-profile-daemon.hid"
        hidThread?.start()
    }

    deinit {
        shutdown()
    }

    // Called on the dedicated HID RunLoop thread (com.user.face-profile-daemon.hid) — must dispatch to stateQueue before touching stateMachine.
    func onBuiltinHIDActivity(sender: UnsafeMutableRawPointer?) {
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
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastHIDEventTime < 2.0 {
                return
            }
            self.lastHIDEventTime = now

            let action = self.stateMachine.onHIDEvent()
            self.handleAction(action)
        }
    }

    // MARK: - Face detection poll loop (Swift concurrency Task)

    internal func faceDetectionLoop() async {
        var consecutiveFailures = 0
        var lastSleepTime = pollInterval
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
                        let action = self.stateMachine.onNoFace(elapsed: lastSleepTime)
                        self.handleAction(action)
                        self.logger.info("No face. Streak: \(Int(self.stateMachine.noFaceStreak))s / \(Int(noFaceTimeout))s")
                    }
                }
            } catch {
                consecutiveFailures += 1
                let nsError = error as NSError
                logger.error("Detection error: \(error.localizedDescription, privacy: .public) (domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public))")
                if consecutiveFailures >= 5 {
                    stateQueue.async {
                        let action = self.stateMachine.onNoFace(elapsed: lastSleepTime)
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
            lastSleepTime = sleepTime
            
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
        let allowed: Set<String> = [profileKeyboard, profileGhost]
        guard allowed.contains(profile) else {
            logger.error("Rejected unexpected profile name: '\(profile, privacy: .public)'")
            return
        }
        let capturedProfile = profile
        karabinerProcessQueue.async { [weak self] in
            guard let self else { return }
            let result = self.karabiner.runSelectProfile(capturedProfile)
            self.stateQueue.async {
                switch result {
                case .success:
                    self.logger.debug("[FPD] karabiner_cli succeeded for '\(capturedProfile, privacy: .public)'")
                case .timedOut:
                    self.logger.error("[FPD] karabiner_cli timed out for '\(capturedProfile, privacy: .public)'")
                    self.stateMachine.onSwitchFailed(forProfile: capturedProfile)
                case .nonZeroExit(let code):
                    self.logger.error("[FPD] karabiner_cli failed (exit \(code)) for '\(capturedProfile, privacy: .public)'")
                    self.stateMachine.onSwitchFailed(forProfile: capturedProfile)
                case .launchFailed(let message):
                    self.logger.error("Failed to launch karabiner_cli: \(message, privacy: .public)")
                    self.stateMachine.onSwitchFailed(forProfile: capturedProfile)
                }
            }
        }
    }
}
