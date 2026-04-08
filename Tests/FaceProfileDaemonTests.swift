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
}
