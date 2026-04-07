// Canonical implementation; built into the daemon binary by `make compile` alongside FaceProfileDaemon.swift and ProfileStateMachine.swift (see Makefile).
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
public final class FacePresenceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.facedetector.capture", qos: .userInitiated)
    private var isConfigured = false
    private var activeContinuation: CheckedContinuation<CVPixelBuffer, Error>?

    public override init() {
        super.init()
    }

    /// Returns `true` if ≥1 face with confidence ≥ 0.5 is detected in the
    /// current camera frame. Throws `FaceDetectorError` on any camera or
    /// Vision failure — never silently returns `false`.
    public func detectFace() async throws -> Bool {
        try await requestAccess()
        let pixelBuffer = try await captureSingleFrame()
        return try runVision(on: pixelBuffer)
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

    private func configureSessionIfNeeded() throws {
        try captureQueue.sync {
            guard !isConfigured else { return }

            guard let device = AVCaptureDevice.default(for: .video) else {
                throw FaceDetectorError.cameraUnavailable
            }

            session.sessionPreset = .medium

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw FaceDetectorError.cameraUnavailable }
                session.addInput(input)
            } catch {
                throw FaceDetectorError.cameraUnavailable
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            guard session.canAddOutput(output) else { throw FaceDetectorError.cameraUnavailable }
            session.addOutput(output)

            output.setSampleBufferDelegate(self, queue: captureQueue)

            isConfigured = true
        }
    }

    private func captureSingleFrame() async throws -> CVPixelBuffer {
        try configureSessionIfNeeded()
        
        return try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                if let existing = self.activeContinuation {
                    existing.resume(throwing: FaceDetectorError.captureFailed)
                }
                self.activeContinuation = continuation
                self.session.startRunning()
                
                // Timeout fallback
                self.captureQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self = self, self.activeContinuation != nil else { return }
                    let cont = self.activeContinuation
                    self.activeContinuation = nil
                    self.session.stopRunning()
                    cont?.resume(throwing: FaceDetectorError.captureFailed)
                }
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        
        session.stopRunning()
        
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            continuation.resume(returning: pb)
        } else {
            continuation.resume(throwing: FaceDetectorError.captureFailed)
        }
    }

    private func runVision(on pixelBuffer: CVPixelBuffer) throws -> Bool {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            throw FaceDetectorError.visionError(error)
        }
        return (faceRequest.results ?? []).contains { $0.confidence >= 0.5 }
    }
}

// MARK: - Usage
//
// let detector = FacePresenceDetector()
// let facePresent = try await detector.detectFace()
// print(facePresent ? "Face detected" : "No face detected")
