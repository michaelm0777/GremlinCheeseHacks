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

    // For testing: who to send a challenge to
    @State private var toUserUid: String = ""

    @StateObject private var lockService = FirebaseLockService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Button("Request Authorization") {
                    requestAuthorization()
                }

                Button("Create user") {
                    lockService.createUserDb(name: "name placeholder")
                }
                .buttonStyle(.borderedProminent)

                TextField("Send challenge to UID", text: $toUserUid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button("Pick Apps to Control") {
                    showPicker = true
                }
                .disabled(!isAuthorized)

                Button("Send Challenge (locks receiver)") {
                    lockService.createChallenge(
                        exerciseType: "jumping_jacks",
                        reps: 20,
                        blockDurationSec: 300
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(toUserUid.isEmpty)

                Button("Unblock All Apps", role: .destructive) {
                    unblockAppsLocally()
                }

                Spacer()
            }
            .padding()
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
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
