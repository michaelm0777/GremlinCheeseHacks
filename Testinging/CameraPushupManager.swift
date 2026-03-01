//
//  CameraPushupManager.swift
//  Testinging
//

import AVFoundation
import Vision
import Combine

private let downAngleThreshold: Double = 100   // elbow angle below this = "down"
private let upAngleThreshold: Double = 150     // elbow angle above this = "up"
private let minConfidence: Float = 0.4

/// Manages camera capture and runs body pose detection to count pushups.
/// A rep is counted when the user goes from "down" (arms bent) to "up" (arms extended).
@MainActor
final class CameraPushupManager: NSObject, ObservableObject {
    @Published private(set) var pushupCount: Int = 0
    @Published private(set) var isSessionRunning: Bool = false
    @Published private(set) var errorMessage: String?
    /// Current pose phase for UI; updated every frame when pose is detected.
    @Published private(set) var currentPhase: PushupPhase = .unknown
    /// Normalized (0–1) joint positions for skeleton overlay; keys match Vision joint names.
    @Published private(set) var posePoints: [String: CGPoint]?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "pushup.vision")
    /// Used only from processingQueue after init; safe for nonisolated access.
    private nonisolated(unsafe) var bodyPoseRequest: VNDetectHumanBodyPoseRequest!

    /// Rep detection state: we count when transitioning from down -> up
    private var lastPhase: PushupPhase = .unknown

    enum PushupPhase: String {
        case unknown = "—"
        case up = "Up"
        case down = "Down"
    }

    override init() {
        super.init()
        bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    }

    func startSession() {
        captureSession.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            errorMessage = "Could not access camera."
            return
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
        captureSession.startRunning()
        isSessionRunning = true
        errorMessage = nil
    }

    func stopSession() {
        captureSession.stopRunning()
        isSessionRunning = false
    }

    func resetCount() {
        pushupCount = 0
        lastPhase = .unknown
    }

    private lazy var _previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    var previewLayer: AVCaptureVideoPreviewLayer { _previewLayer }

}

extension CameraPushupManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([bodyPoseRequest])
            if let results = bodyPoseRequest.results as? [VNHumanBodyPoseObservation], let observation = results.first {
                processObservation(observation)
            }
        } catch {
            // Ignore per-frame errors
        }
    }

    private nonisolated func processObservation(_ observation: VNHumanBodyPoseObservation) {
        let angle = Self.elbowAngle(from: observation)
        let phase: PushupPhase = angle.map { a in
            a >= upAngleThreshold ? .up : (a <= downAngleThreshold ? .down : .unknown)
        } ?? .unknown
        let points = Self.extractPosePoints(from: observation)
        Task { @MainActor in
            currentPhase = phase
            posePoints = points
            if phase == .up || phase == .down {
                if lastPhase == .down && phase == .up {
                    pushupCount += 1
                }
                lastPhase = phase
            }
        }
    }

    private nonisolated static func extractPosePoints(from observation: VNHumanBodyPoseObservation) -> [String: CGPoint]? {
        let jointNames: [(VNHumanBodyPoseObservation.JointName, String)] = [
            (.nose, "nose"),
            (.leftEye, "leftEye"), (.rightEye, "rightEye"),
            (.leftEar, "leftEar"), (.rightEar, "rightEar"),
            (.neck, "neck"),
            (.leftShoulder, "leftShoulder"), (.rightShoulder, "rightShoulder"),
            (.leftElbow, "leftElbow"), (.rightElbow, "rightElbow"),
            (.leftWrist, "leftWrist"), (.rightWrist, "rightWrist"),
        ]
        var result = [String: CGPoint]()
        for (name, key) in jointNames {
            guard let point = try? observation.recognizedPoint(name), point.confidence >= minConfidence else { continue }
            result[key] = point.location
        }
        return result.isEmpty ? nil : result
    }

    /// Returns elbow angle in degrees (shoulder–elbow–wrist). Uses best visible arm; 180 = straight.
    private nonisolated static func elbowAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
        func getPoint(_ name: VNHumanBodyPoseObservation.JointName) -> (x: Double, y: Double)? {
            guard let point = try? observation.recognizedPoint(name), point.confidence >= minConfidence else { return nil }
            return (Double(point.location.x), Double(point.location.y))
        }

        var leftAngle: Double?
        if let s = getPoint(.leftShoulder), let e = getPoint(.leftElbow), let w = getPoint(.leftWrist) {
            leftAngle = angleBetween(p1: (s.x, s.y), vertex: (e.x, e.y), p2: (w.x, w.y))
        }
        var rightAngle: Double?
        if let s = getPoint(.rightShoulder), let e = getPoint(.rightElbow), let w = getPoint(.rightWrist) {
            rightAngle = angleBetween(p1: (s.x, s.y), vertex: (e.x, e.y), p2: (w.x, w.y))
        }

        switch (leftAngle, rightAngle) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    private nonisolated static func angleBetween(p1: (Double, Double), vertex: (Double, Double), p2: (Double, Double)) -> Double {
        let v1 = (p1.0 - vertex.0, p1.1 - vertex.1)
        let v2 = (p2.0 - vertex.0, p2.1 - vertex.1)
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let mag1 = sqrt(v1.0 * v1.0 + v1.1 * v1.1)
        let mag2 = sqrt(v2.0 * v2.0 + v2.1 * v2.1)
        guard mag1 > 0, mag2 > 0 else { return 0 }
        let cosAngle = max(-1, min(1, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180 / .pi
    }
}
