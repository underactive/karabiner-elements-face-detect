import Foundation
import AVFoundation
import Vision

// MARK: - Errors

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

// MARK: - FacePresenceDetector

/// Opens a one-shot AVCaptureSession, grabs a single frame, runs
/// VNDetectFaceRectanglesRequest on the in-memory pixel buffer, then
/// closes the session. No data is ever written to disk.
public final class FacePresenceDetector {
    public init() {}

    /// Returns `true` if ≥1 face with confidence ≥ 0.5 is detected in the
    /// current camera frame. Throws `FaceDetectorError` on any camera or
    /// Vision failure — never silently returns `false`.
    public func detectFace() async throws -> Bool {
        try await requestAccess()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw FaceDetectorError.cameraUnavailable
        }
        let pixelBuffer = try await SingleFrameCapturer.capture(from: device)
        return try runVision(on: pixelBuffer)
        // pixelBuffer is released here when it exits scope
    }

    // MARK: - Private helpers

    private func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw FaceDetectorError.accessDenied
            }
        case .denied, .restricted:
            throw FaceDetectorError.accessDenied
        @unknown default:
            throw FaceDetectorError.accessDenied
        }
    }

    private func runVision(on pixelBuffer: CVPixelBuffer) throws -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceDetectorError.visionError(error)
        }
        return (request.results ?? []).contains { $0.confidence >= 0.5 }
    }
}

// MARK: - SingleFrameCapturer

/// Bridges AVCaptureVideoDataOutputSampleBufferDelegate to async/await.
///
/// AVCaptureVideoDataOutput keeps only a *weak* reference to its delegate, so
/// this object uses a deliberate self-retain cycle (selfRetain = self) that is
/// broken exactly once when the first frame arrives, allowing normal ARC cleanup.
private final class SingleFrameCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let continuation: CheckedContinuation<CVPixelBuffer, Error>
    private let session = AVCaptureSession()
    private var didCapture = false
    private var selfRetain: SingleFrameCapturer? // broken after first frame

    private init(continuation: CheckedContinuation<CVPixelBuffer, Error>) {
        self.continuation = continuation
    }

    static func capture(from device: AVCaptureDevice) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { continuation in
            let c = SingleFrameCapturer(continuation: continuation)
            c.selfRetain = c        // prevent ARC from dropping delegate before callback fires
            c.start(device: device)
        }
    }

    private func start(device: AVCaptureDevice) {
        session.sessionPreset = .medium
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return finish(FaceDetectorError.cameraUnavailable) }
            session.addInput(input)
        } catch {
            return finish(FaceDetectorError.cameraUnavailable)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { return finish(FaceDetectorError.cameraUnavailable) }
        session.addOutput(output)

        let queue = DispatchQueue(label: "com.facedetector.capture", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: queue)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !didCapture else { return }
        didCapture = true
        session.stopRunning()
        // Keep self alive past continuation.resume() by holding retain on stack
        let retain = selfRetain
        selfRetain = nil
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            continuation.resume(returning: pb)
        } else {
            continuation.resume(throwing: FaceDetectorError.captureFailed)
        }
        _ = retain
    }

    private func finish(_ error: Error) {
        // self is kept alive by implicit method receiver ref until this returns
        selfRetain = nil
        continuation.resume(throwing: error)
    }
}

// MARK: - Usage
//
// let detector = FacePresenceDetector()
// let facePresent = try await detector.detectFace()
// print(facePresent ? "Face detected" : "No face detected")
