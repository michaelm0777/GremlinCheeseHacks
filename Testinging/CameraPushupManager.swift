//
//  CameraPushupManager.swift
//  Testinging
//

import AVFoundation
import Vision
import Combine

private let downAngleThreshold: Double = 115   // elbow angle below this = "down" (looser: don't need to go as low)
private let upAngleThreshold: Double = 140     // elbow angle above this = "up" (looser: don't need full extension)
private let minConfidence: Float = 0.35

/// Manages camera capture and runs body pose detection to count pushups and jumping jacks.
@MainActor
final class CameraPushupManager: NSObject, ObservableObject {
    enum ExerciseMode: String, CaseIterable {
        case pushup = "Pushups"
        case jumpingJack = "Jumping Jacks"
    }

    @Published var exerciseMode: ExerciseMode = .pushup
    @Published private(set) var pushupCount: Int = 0
    @Published private(set) var jumpingJackCount: Int = 0
    @Published private(set) var isSessionRunning: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPushupPhase: PushupPhase = .unknown
    @Published private(set) var currentJumpingJackPhase: JumpingJackPhase = .unknown
    @Published private(set) var posePoints: [String: CGPoint]?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var recordingCompletion: ((URL?) -> Void)?
    private let sessionQueue = DispatchQueue(label: "pushup.capture.session", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "pushup.vision")
    private nonisolated(unsafe) var bodyPoseRequest: VNDetectHumanBodyPoseRequest!

    private var lastPushupPhase: PushupPhase = .unknown
    private var lastJumpingJackPhase: JumpingJackPhase = .unknown

    enum PushupPhase: String {
        case unknown = "—"
        case up = "Up"
        case down = "Down"
    }

    override init() {
        super.init()
        bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    }

    /// Start capture session. Requests camera permission on main first, then configures on a background queue so main never blocks.
    func startSession() {
        Task { @MainActor in
            let granted: Bool = await withCheckedContinuation { cont in
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    cont.resume(returning: true)
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
                default:
                    cont.resume(returning: false)
                }
            }
            guard granted else {
                errorMessage = "Camera access denied. Enable in Settings."
                return
            }
            self.startSessionOnQueue()
        }
    }

    private nonisolated func startSessionOnQueue() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var message: String?
            defer {
                Task { @MainActor in
                    self.isSessionRunning = (message == nil)
                    self.errorMessage = message
                }
            }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .medium
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                message = "No front camera."
                self.captureSession.commitConfiguration()
                return
            }
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                message = "Could not create camera input."
                self.captureSession.commitConfiguration()
                return
            }
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            self.videoOutput.setSampleBufferDelegate(self, queue: self.processingQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            if self.captureSession.canAddOutput(self.movieOutput) {
                self.captureSession.addOutput(self.movieOutput)
            }
            if let connection = self.videoOutput.connection(with: .video) {
                connection.videoRotationAngle = 90
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.stopRunning()
            Task { @MainActor in
                self.isSessionRunning = false
            }
        }
    }

    func resetCount() {
        pushupCount = 0
        jumpingJackCount = 0
        lastPushupPhase = .unknown
        lastJumpingJackPhase = .unknown
    }

    /// Current rep count for the active exercise mode.
    var currentCount: Int {
        switch exerciseMode {
        case .pushup: return pushupCount
        case .jumpingJack: return jumpingJackCount
        }
    }

    private lazy var _previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    var previewLayer: AVCaptureVideoPreviewLayer { _previewLayer }
    
    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording else { return }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("proof_\(UUID().uuidString).mov")

            try? FileManager.default.removeItem(at: url)

            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.movieOutput.isRecording {
                self.recordingCompletion = completion
                self.movieOutput.stopRecording()
            } else {
                completion(nil)
            }
        }
    }

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

    enum JumpingJackPhase: String {
        case unknown = "-"
        case open = "Open"
        case closed = "Closed"
    }

    private nonisolated func processObservation(_ observation: VNHumanBodyPoseObservation) {
        let points = Self.extractPosePoints(from: observation)

        let pushupPhase: PushupPhase = {
            guard let angle = Self.elbowAngle(from: observation) else { return .unknown }
            if angle >= upAngleThreshold { return .up }
            if angle <= downAngleThreshold { return .down }
            return .unknown
        }()

        let jumpingJackPhase: JumpingJackPhase = Self.jumpingJackPhase(from: observation)

        Task { @MainActor in
            currentPushupPhase = pushupPhase
            currentJumpingJackPhase = jumpingJackPhase
            posePoints = points

            if pushupPhase == .up || pushupPhase == .down {
                if exerciseMode == .pushup && lastPushupPhase == .down && pushupPhase == .up {
                    pushupCount += 1
                }
                lastPushupPhase = pushupPhase
            }

            if jumpingJackPhase == .open || jumpingJackPhase == .closed {
                if exerciseMode == .jumpingJack && lastJumpingJackPhase == .open && jumpingJackPhase == .closed {
                    jumpingJackCount += 1
                }
                lastJumpingJackPhase = jumpingJackPhase
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
            (.leftHip, "leftHip"), (.rightHip, "rightHip"),
            (.leftKnee, "leftKnee"), (.rightKnee, "rightKnee"),
            (.leftAnkle, "leftAnkle"), (.rightAnkle, "rightAnkle"),
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

    /// Angle in degrees between two vectors (no vertex).
    private nonisolated static func angleBetweenVectors(_ v1: (Double, Double), _ v2: (Double, Double)) -> Double {
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let mag1 = sqrt(v1.0 * v1.0 + v1.1 * v1.1)
        let mag2 = sqrt(v2.0 * v2.0 + v2.1 * v2.1)
        guard mag1 > 0, mag2 > 0 else { return 0 }
        let cosAngle = max(-1, min(1, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180 / .pi
    }

    /// Angle in degrees between the two arms (shoulder→wrist). ~180° when arms out to sides, small when at sides.
    private nonisolated static func armSpreadAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
        func getPoint(_ name: VNHumanBodyPoseObservation.JointName) -> (x: Double, y: Double)? {
            guard let point = try? observation.recognizedPoint(name), point.confidence >= minConfidence else { return nil }
            return (Double(point.location.x), Double(point.location.y))
        }
        guard let ls = getPoint(.leftShoulder), let lw = getPoint(.leftWrist),
              let rs = getPoint(.rightShoulder), let rw = getPoint(.rightWrist) else { return nil }
        let leftArm = (lw.0 - ls.0, lw.1 - ls.1)
        let rightArm = (rw.0 - rs.0, rw.1 - rs.1)
        return angleBetweenVectors(leftArm, rightArm)
    }

    /// Angle in degrees between the two legs (hip→knee). Large when legs spread, small when together.
    private nonisolated static func torsoLegAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
        func getPoint(_ name: VNHumanBodyPoseObservation.JointName) -> (x: Double, y: Double)? {
            guard let point = try? observation.recognizedPoint(name), point.confidence >= minConfidence else { return nil }
            return (Double(point.location.x), Double(point.location.y))
        }
        guard let lh = getPoint(.leftHip), let lk = getPoint(.leftKnee),
              let rh = getPoint(.rightHip), let rk = getPoint(.rightKnee) else { return nil }
        let leftLeg = (lk.0 - lh.0, lk.1 - lh.1)
        let rightLeg = (rk.0 - rh.0, rk.1 - rh.1)
        return angleBetweenVectors(leftLeg, rightLeg)
    }

    private static let armOpenThreshold: Double = 120   // arm spread angle above this = "open"
    private static let armClosedThreshold: Double = 80 // arm spread angle below this = "closed"
    private static let legOpenThreshold: Double = 35   // leg angle above this = "open"
    private static let legClosedThreshold: Double = 25 // leg angle below this = "closed"

    private nonisolated static func jumpingJackPhase(from observation: VNHumanBodyPoseObservation) -> JumpingJackPhase {
        guard let armAngle = armSpreadAngle(from: observation),
              let legAngle = torsoLegAngle(from: observation) else { return .unknown }
        if armAngle >= armOpenThreshold && legAngle >= legOpenThreshold { return .open }
        if armAngle <= armClosedThreshold && legAngle <= legClosedThreshold { return .closed }
        return .unknown
    }
}

extension CameraPushupManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let url: URL? = (error == nil) ? outputFileURL : nil

        Task { @MainActor in
            let cb = self.recordingCompletion
            self.recordingCompletion = nil
            cb?(url)
        }
    }
}
