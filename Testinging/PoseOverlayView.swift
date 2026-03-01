//
//  PoseOverlayView.swift
//  Testinging
//

import SwiftUI

/// Upper body + torso (no legs) for pushup mode.
private let pushupSkeletonSegments: [(String, String)] = [
    ("leftEye", "nose"), ("rightEye", "nose"), ("leftEye", "rightEye"),
    ("leftEar", "leftEye"), ("rightEar", "rightEye"),
    ("neck", "leftShoulder"), ("neck", "rightShoulder"),
    ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
    ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
    ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"), ("leftHip", "rightHip"),
]

/// Full body including legs for jumping jack mode.
private let jumpingJackSkeletonSegments: [(String, String)] = [
    ("leftEye", "nose"), ("rightEye", "nose"), ("leftEye", "rightEye"),
    ("leftEar", "leftEye"), ("rightEar", "rightEye"),
    ("neck", "leftShoulder"), ("neck", "rightShoulder"),
    ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
    ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
    ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"), ("leftHip", "rightHip"),
    ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
    ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
]

struct PoseOverlayView: View {
    let mode: CameraPushupManager.ExerciseMode
    let pushupPhase: CameraPushupManager.PushupPhase
    let jumpingJackPhase: CameraPushupManager.JumpingJackPhase
    let posePoints: [String: CGPoint]?

    private var segments: [(String, String)] {
        switch mode {
        case .pushup: return pushupSkeletonSegments
        case .jumpingJack: return jumpingJackSkeletonSegments
        }
    }

    private var phaseLabel: String {
        switch mode {
        case .pushup:
            return (pushupPhase == .unknown && posePoints != nil) ? "In between" : pushupPhase.rawValue
        case .jumpingJack:
            return (jumpingJackPhase == .unknown && posePoints != nil) ? "In between" : jumpingJackPhase.rawValue
        }
    }

    private var skeletonColor: Color {
        switch mode {
        case .pushup: return .green
        case .jumpingJack: return .cyan
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                if let points = posePoints, !points.isEmpty {
                    Canvas { context, canvasSize in
                        let w = canvasSize.width, h = canvasSize.height
                        func viewPoint(_ p: CGPoint) -> CGPoint {
                            CGPoint(x: p.y * w, y: p.x * h)
                        }
                        for (startKey, endKey) in segments {
                            guard let start = points[startKey], let end = points[endKey] else { continue }
                            var path = Path()
                            path.move(to: viewPoint(start))
                            path.addLine(to: viewPoint(end))
                            context.stroke(path, with: .color(skeletonColor), lineWidth: 3)
                        }
                        for (_, p) in points {
                            let pt = viewPoint(p)
                            context.fill(
                                Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                                with: .color(skeletonColor)
                            )
                        }
                    }
                }

                Text(phaseLabel)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.top, 12)
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }
}
