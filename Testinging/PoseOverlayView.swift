//
//  PoseOverlayView.swift
//  Testinging
//

import SwiftUI

/// Skeleton segments: (startKey, endKey) for drawing lines.
private let skeletonSegments: [(String, String)] = [
    ("leftEye", "nose"), ("rightEye", "nose"), ("leftEye", "rightEye"),
    ("leftEar", "leftEye"), ("rightEar", "rightEye"),
    ("neck", "leftShoulder"), ("neck", "rightShoulder"),
    ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
    ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
]

struct PoseOverlayView: View {
    let phase: CameraPushupManager.PushupPhase
    let posePoints: [String: CGPoint]?
    let phaseLabel: String

    init(phase: CameraPushupManager.PushupPhase, posePoints: [String: CGPoint]?) {
        self.phase = phase
        self.posePoints = posePoints
        self.phaseLabel = (phase == .unknown && posePoints != nil) ? "In between" : phase.rawValue
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                if let points = posePoints, !points.isEmpty {
                    Canvas { context, canvasSize in
                        let w = canvasSize.width, h = canvasSize.height
                        // Vision normalized coords (buffer space). Preview is rotated 90° and mirrored for front camera.
                        func viewPoint(_ p: CGPoint) -> CGPoint {
                            CGPoint(x: p.y * w, y: p.x * h)
                        }
                        for (startKey, endKey) in skeletonSegments {
                            guard let start = points[startKey], let end = points[endKey] else { continue }
                            var path = Path()
                            path.move(to: viewPoint(start))
                            path.addLine(to: viewPoint(end))
                            context.stroke(path, with: .color(.green), lineWidth: 3)
                        }
                        for (_, p) in points {
                            let pt = viewPoint(p)
                            context.fill(
                                Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                                with: .color(.green)
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
