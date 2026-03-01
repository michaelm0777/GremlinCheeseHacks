//
//  PushupGateView.swift
//  Testinging
//

import SwiftUI

/// Full-screen pushup gate: user must complete `requiredReps` pushups before `onComplete` is called.
/// Same camera + pose overlay UI as PushupDetector. Use for "do 3 pushups to block" or "do 3 pushups to unblock".
struct PushupGateView: View {
    let title: String
    let requiredReps: Int
    let onComplete: () -> Void
    let onCancel: () -> Void

    @StateObject private var cameraManager = CameraPushupManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Only show camera preview after session is running to avoid accessing session/layer during config (prevents freeze/crash).
            if cameraManager.isSessionRunning {
                CameraPreviewView(previewLayer: cameraManager.previewLayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                PoseOverlayView(phase: cameraManager.currentPhase, posePoints: cameraManager.posePoints)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
                if cameraManager.errorMessage == nil {
                    Text("Starting camera…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 60)
                }
            }

            VStack(spacing: 16) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 56)

                Spacer()

                Text("\(cameraManager.pushupCount) / \(requiredReps)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                Text("pushups")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()
                    .frame(height: 48)

                HStack(spacing: 24) {
                    Button("Cancel") {
                        cameraManager.stopSession()
                        onCancel()
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 40)
            }

            if let message = cameraManager.errorMessage {
                VStack {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.6))
            }
        }
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onChange(of: cameraManager.pushupCount) { _, newCount in
            if newCount >= requiredReps {
                cameraManager.stopSession()
                onComplete()
                dismiss()
            }
        }
    }
}
