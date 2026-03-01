//
//  FamilyControlsTestView.swift
//  Testinging
//

import SwiftUI
import FamilyControls
import ManagedSettings
import CoreImage.CIFilterBuiltins
import AVFoundation

private let managedSettingsStore = ManagedSettingsStore()

struct FamilyControlsTestView: View {
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var isAuthorized = false

    @State private var toUserUid: String = ""
    @State private var showBlockPushupGate = false
    @State private var showUnblockPushupGate = false
    @State private var copiedUidFeedback = false

    // MARK: - PAIRING (new)
    @State private var showMyQr = false
    @State private var showScanner = false
    @State private var pairingStatusText: String? = nil

    @StateObject private var lockService = FirebaseLockService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: - Your UID (share with other phone)
                    Group {
                        Text("Your UID (share with the other phone)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        if let uid = lockService.currentUserUid {
                            HStack {
                                Text(uid)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))

                                Button(copiedUidFeedback ? "Copied" : "Copy") {
                                    UIPasteboard.general.string = uid
                                    copiedUidFeedback = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        copiedUidFeedback = false
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text("Loading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // MARK: - PAIRING UI (new)
                    Divider()

                    Text("Pairing (QR)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Show My QR") {
                            showMyQr = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(lockService.currentUserUid == nil)

                        Button("Scan QR to Pair") {
                            showScanner = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(lockService.currentUserUid == nil)
                    }

                    if let pairingStatusText {
                        Text(pairingStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // MARK: - Send challenge to other phone (existing)
                    Text("Send challenge to other phone")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Other phone's UID", text: $toUserUid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button("Send Challenge (3 pushups to send → locks their apps)") {
                        showBlockPushupGate = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(toUserUid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text("The other phone must have opened this app, authorized, and picked apps to control first, or nothing will be blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // MARK: - Blocked state & unblock (existing)
                    if lockService.shouldBlockThisDevice {
                        Text("You have an active challenge. Complete the same challenge (3 pushups) to unblock your apps.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Button("Unblock My Apps (3 pushups to unblock)", role: .destructive) {
                        showUnblockPushupGate = true
                    }

                    Divider()

                    // MARK: - Receiver setup (existing)
                    Text("To receive challenges (get your apps blocked by others):")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button("Request Authorization") {
                        requestAuthorization()
                    }

                    Button("Pick Apps to Control (required for blocking)") {
                        showPicker = true
                    }
                    .disabled(!isAuthorized)

                    if isAuthorized && selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty {
                        Text("You have not selected any apps. Pick apps above so that when someone sends you a challenge, those apps will be blocked.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Create user") {
                        lockService.createUserDb(name: "name placeholder")
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 24)
                }
                .padding()
            }
            .navigationTitle("Challenge")
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)

        // Show QR sheet
        .sheet(isPresented: $showMyQr) {
            if let uid = lockService.currentUserUid {
                MyQrCodeView(payload: uid)
            } else {
                Text("No UID yet.")
                    .padding()
            }
        }

        // Scan QR sheet
        .sheet(isPresented: $showScanner) {
            QrScannerView { scannedValue in
                showScanner = false
                let otherUid = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !otherUid.isEmpty else { return }

                pairingStatusText = "Pairing with: \(otherUid)…"
                lockService.createPair(withOtherUid: otherUid) { result in
                    switch result {
                    case .success(let pairId):
                        pairingStatusText = "Paired. pairId: \(pairId)"
                        // Optional: also fill the text field so you can test challenges immediately.
                        toUserUid = otherUid
                    case .failure(let error):
                        pairingStatusText = "Pair failed: \(error.localizedDescription)"
                    }
                }
            }
        }

        .fullScreenCover(isPresented: $showBlockPushupGate) {
            PushupGateView(
                title: "Do 3 pushups to send block",
                requiredReps: 3,
                onComplete: {
                    lockService.createChallenge(
                        toUser: toUserUid,
                        exerciseType: "pushups",
                        reps: 3,
                        blockDurationSec: 300
                    )
                },
                onCancel: {}
            )
        }
        .fullScreenCover(isPresented: $showUnblockPushupGate) {
            PushupGateView(
                title: "Do 3 pushups to unblock",
                requiredReps: 3,
                onComplete: {
                    lockService.resolveChallengesTargetingMe()
                    unblockAppsLocally()
                },
                onCancel: {}
            )
        }
        .onAppear {
            lockService.startListeningForChallenges { shouldBlock in
                if shouldBlock {
                    blockSelectedApps()
                } else {
                    unblockAppsLocally()
                }
            }
        }
        .onDisappear {
            lockService.stopListening()
        }
    }

    private func requestAuthorization() {
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                await MainActor.run { isAuthorized = true }
            } catch {
                print("Authorization failed:", error)
            }
        }
    }

    private func blockSelectedApps() {
        managedSettingsStore.shield.applications = selection.applicationTokens
        managedSettingsStore.shield.applicationCategories = .specific(selection.categoryTokens)
    }

    private func unblockAppsLocally() {
        managedSettingsStore.shield.applications = []
        managedSettingsStore.shield.applicationCategories = .none
    }
}

// MARK: - QR display (minimal)

private struct MyQrCodeView: View {
    let payload: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan to pair")
                .font(.headline)

            Image(uiImage: makeQrImage(from: payload))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 260, height: 260)
                .padding()

            Text(payload)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    private func makeQrImage(from string: String) -> UIImage {
        filter.message = Data(string.utf8)

        guard let outputImage = filter.outputImage else {
            return UIImage(systemName: "xmark.circle") ?? UIImage()
        }

        // scale up so it’s sharp
        let transform = CGAffineTransform(scaleX: 12, y: 12)
        let scaledImage = outputImage.transformed(by: transform)

        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(systemName: "xmark.circle") ?? UIImage()
    }
}

// MARK: - QR scanner (minimal)

private struct QrScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return
        }

        session.addInput(input)

        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)

        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        session.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue
        else { return }

        session.stopRunning()
        onScanned?(value)
        dismiss(animated: true)
    }
}
