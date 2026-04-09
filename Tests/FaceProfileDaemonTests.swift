import XCTest
@testable import FaceProfileLib

final class MockFaceDetector: FaceDetecting {
    private var results: [Result<Bool, Error>]
    private let lock = NSLock()

    init(results: [Result<Bool, Error>]) {
        self.results = results
    }

    func detectFace() async throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            return false
        }
        let next = results.removeFirst()
        switch next {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}

final class MockKarabiner: KarabinerCLIExecuting {
    let cliPath: String = "/usr/bin/true"
    private let lock = NSLock()
    private(set) var profiles: [String] = []
    var result: KarabinerExecutionResult = .success

    func runSelectProfile(_ profile: String) -> KarabinerExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        profiles.append(profile)
        return result
    }
}

final class CountingDetector: FaceDetecting {
    private let lock = NSLock()
    private let facePresent: Bool
    private(set) var callCount = 0

    init(facePresent: Bool) {
        self.facePresent = facePresent
    }

    func detectFace() async throws -> Bool {
        lock.lock()
        callCount += 1
        lock.unlock()
        return facePresent
    }

    func currentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

final class FaceProfileDaemonTests: XCTestCase {

    func testFaceDetectionLoop_faceDetected_invokesKarabinerForKeyboard() async throws {
        let detector = MockFaceDetector(results: Array(repeating: .success(true), count: 8))
        let karabiner = MockKarabiner()
        let daemon = FaceProfileDaemon(
            detector: detector,
            karabiner: karabiner,
            pollInterval: 0.05,
            noFaceTimeout: 120
        )

        let loop = Task { await daemon.faceDetectionLoop() }
        try await Task.sleep(for: .milliseconds(250))
        loop.cancel()
        _ = await loop.result

        XCTAssertTrue(karabiner.profiles.contains("⌨️"))
    }

    func testFaceDetectionLoop_noFaceEventuallyRequestsGhost() async throws {
        let detector = MockFaceDetector(results: Array(repeating: .success(false), count: 200))
        let karabiner = MockKarabiner()
        let daemon = FaceProfileDaemon(
            detector: detector,
            karabiner: karabiner,
            profileKeyboard: "K",
            profileGhost: "G",
            pollInterval: 0.05,
            noFaceTimeout: 0.15
        )

        let loop = Task { await daemon.faceDetectionLoop() }
        try await Task.sleep(for: .milliseconds(600))
        loop.cancel()
        _ = await loop.result

        XCTAssertTrue(karabiner.profiles.contains("G"))
    }

    func testKarabinerNonZeroExit_retriesAfterSwitchFailedClearsCache() async throws {
        let detector = MockFaceDetector(results: Array(repeating: .success(true), count: 8))
        let karabiner = MockKarabiner()
        karabiner.result = .nonZeroExit(1)

        let daemon = FaceProfileDaemon(
            detector: detector,
            karabiner: karabiner,
            pollInterval: 0.05,
            noFaceTimeout: 120
        )

        let loop = Task { await daemon.faceDetectionLoop() }
        try await Task.sleep(for: .milliseconds(300))
        loop.cancel()
        _ = await loop.result

        XCTAssertGreaterThanOrEqual(karabiner.profiles.filter { $0 == "⌨️" }.count, 2)
    }

    // MARK: - Adaptive polling interval tests

    func testFaceDetectionLoop_pollsMoreFrequentlyWhenNoFace() async throws {
        let detector = CountingDetector(facePresent: false)
        let karabiner = MockKarabiner()
        let daemon = FaceProfileDaemon(
            detector: detector,
            karabiner: karabiner,
            pollInterval: 0.20,        // face-present interval (longer)
            noFacePollInterval: 0.05,   // no-face interval (shorter)
            noFaceTimeout: 999
        )

        let loop = Task { await daemon.faceDetectionLoop() }
        try await Task.sleep(for: .milliseconds(400))
        loop.cancel()
        _ = await loop.result

        // With 0.05s interval over 400ms, expect at least 5 polls
        XCTAssertGreaterThanOrEqual(detector.currentCount(), 5,
            "Should poll frequently (every 0.05s) when no face detected")
    }

    func testFaceDetectionLoop_pollsLessFrequentlyWhenFaceDetected() async throws {
        let detector = CountingDetector(facePresent: true)
        let karabiner = MockKarabiner()
        let daemon = FaceProfileDaemon(
            detector: detector,
            karabiner: karabiner,
            pollInterval: 0.20,        // face-present interval (longer)
            noFacePollInterval: 0.05,   // no-face interval (shorter)
            noFaceTimeout: 999
        )

        let loop = Task { await daemon.faceDetectionLoop() }
        try await Task.sleep(for: .milliseconds(400))
        loop.cancel()
        _ = await loop.result

        // With 0.20s interval over 400ms, expect around 2-3 polls (not 5+)
        XCTAssertLessThanOrEqual(detector.currentCount(), 4,
            "Should poll less frequently (every 0.20s) when face is detected")
    }
}
