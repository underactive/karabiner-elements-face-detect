import XCTest
@testable import FaceProfileLib

final class FacePresenceDetectorTests: XCTestCase {

    func testFaceDetectorErrorDescriptions() {
        XCTAssertEqual(
            FaceDetectorError.cameraUnavailable.errorDescription,
            "Built-in FaceTime camera not found"
        )
        XCTAssertEqual(
            FaceDetectorError.accessDenied.errorDescription,
            "Camera access denied — check System Settings › Privacy › Camera"
        )
        XCTAssertEqual(
            FaceDetectorError.captureFailed.errorDescription,
            "No pixel buffer received from camera"
        )
        let inner = NSError(domain: "t", code: 0, userInfo: [NSLocalizedDescriptionKey: "inner-msg"])
        let ve = FaceDetectorError.visionError(inner)
        XCTAssertTrue(ve.errorDescription?.contains("inner-msg") ?? false)
    }
}
