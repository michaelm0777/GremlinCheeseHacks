//
//  FamilyControlsTestView.swift
//  Testinging
//

import SwiftUI
import FamilyControls
import ManagedSettings

private let managedSettingsStore = ManagedSettingsStore()

struct FamilyControlsTestView: View {
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var isAuthorized = false

    @State private var toUserUid: String = ""
    @State private var showBlockPushupGate = false
    @State private var showUnblockPushupGate = false
    @State private var copiedUidFeedback = false

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

                    Divider()

                    // MARK: - Send challenge to other phone
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

                    // MARK: - Blocked state & unblock
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
