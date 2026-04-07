import XCTest
@testable import FaceProfileLib

final class ProfileStateMachineTests: XCTestCase {

    // MARK: - Streak crosses threshold → ghost profile selected

    func testNoFaceStreakCrossesThreshold_switchesToGhostProfile() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        // 3 polls = 90s — below threshold, no switch
        for _ in 0..<3 {
            XCTAssertEqual(sm.onNoFace(), .none)
        }
        XCTAssertEqual(sm.noFaceStreak, 90)

        // 4th poll = 120s — exactly at threshold, should switch to ghost
        XCTAssertEqual(sm.onNoFace(), .switchProfile("👻"))
        XCTAssertEqual(sm.noFaceStreak, 120)
    }

    func testNoFaceStreakBeyondThreshold_remainsGhostNoOp() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        // Cross threshold
        for _ in 0..<4 { _ = sm.onNoFace() }
        XCTAssertEqual(sm.cachedProfile, "👻")

        // Further no-face polls should be no-ops (already on ghost)
        XCTAssertEqual(sm.onNoFace(), .none)
        XCTAssertEqual(sm.noFaceStreak, 150)
    }

    // MARK: - HID event resets streak → keyboard profile re-selected

    func testHIDEventResetsStreak_switchesToKeyboard() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        // Build up streak
        _ = sm.onNoFace() // 30s
        _ = sm.onNoFace() // 60s
        XCTAssertEqual(sm.noFaceStreak, 60)

        // HID event resets streak and selects keyboard
        XCTAssertEqual(sm.onHIDEvent(), .switchProfile("⌨️"))
        XCTAssertEqual(sm.noFaceStreak, 0)

        // Streak must rebuild from 0 to cross threshold again
        XCTAssertEqual(sm.onNoFace(), .none)
        XCTAssertEqual(sm.noFaceStreak, 30)
    }

    func testHIDEventAfterGhostProfile_switchesBackToKeyboard() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        // Cross threshold to activate ghost
        for _ in 0..<4 { _ = sm.onNoFace() }
        XCTAssertEqual(sm.cachedProfile, "👻")

        // HID event should switch back to keyboard
        XCTAssertEqual(sm.onHIDEvent(), .switchProfile("⌨️"))
        XCTAssertEqual(sm.noFaceStreak, 0)
        XCTAssertEqual(sm.cachedProfile, "⌨️")
    }

    // MARK: - switchProfile is a no-op when cachedProfile already matches target

    func testFaceDetectedIsNoOpWhenAlreadyOnKeyboard() {
        var sm = ProfileStateMachine()

        // First detection switches to keyboard
        XCTAssertEqual(sm.onFaceDetected(), .switchProfile("⌨️"))

        // Subsequent detections are no-ops
        XCTAssertEqual(sm.onFaceDetected(), .none)
        XCTAssertEqual(sm.onFaceDetected(), .none)
    }

    func testHIDEventIsNoOpWhenAlreadyOnKeyboard() {
        var sm = ProfileStateMachine()

        // First HID event switches
        XCTAssertEqual(sm.onHIDEvent(), .switchProfile("⌨️"))

        // Already on keyboard — no-op
        XCTAssertEqual(sm.onHIDEvent(), .none)
    }

    func testRepeatedNoFaceOnlyTriggersGhostOnce() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        var switchCount = 0
        for _ in 0..<10 {
            if case .switchProfile = sm.onNoFace() { switchCount += 1 }
        }
        XCTAssertEqual(switchCount, 1, "Ghost profile should be selected exactly once")
    }

    // MARK: - Switch failure allows retry

    func testSwitchFailedClearsCacheAllowingRetry() {
        var sm = ProfileStateMachine()

        XCTAssertEqual(sm.onFaceDetected(), .switchProfile("⌨️"))

        // Simulate CLI failure
        sm.onSwitchFailed(forProfile: "⌨️")
        XCTAssertNil(sm.cachedProfile)

        // Retry should produce a switch action again
        XCTAssertEqual(sm.onFaceDetected(), .switchProfile("⌨️"))
    }

    // MARK: - Face detection resets streak like HID

    func testFaceDetectedResetsStreak() {
        var sm = ProfileStateMachine(pollInterval: 30, noFaceTimeout: 120)

        _ = sm.onNoFace() // 30s
        _ = sm.onNoFace() // 60s
        _ = sm.onNoFace() // 90s

        // Face detected — resets streak
        _ = sm.onFaceDetected()
        XCTAssertEqual(sm.noFaceStreak, 0)

        // Needs full 120s again to reach ghost
        for _ in 0..<3 {
            XCTAssertEqual(sm.onNoFace(), .none)
        }
        XCTAssertEqual(sm.noFaceStreak, 90)
    }
}
