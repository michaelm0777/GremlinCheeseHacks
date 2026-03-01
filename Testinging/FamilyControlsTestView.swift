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
    @State private var role: DeviceRole = .friendA
    @State private var name: String = ""
    @State private var hasChosenRole = false

    // New: choose what we listen to
    @State private var listenToChallenges = false

    @StateObject private var lockService = FirebaseLockService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Button("Request Authorization") {
                    requestAuthorization()
                }

                if isAuthorized {
                    Toggle("Listen to challenges (instead of dev-room flags)", isOn: $listenToChallenges)

                    createUserSection

                    if !hasChosenRole {
                        rolePickerSection
                    } else {
                        Button("Pick Apps to Control") {
                            showPicker = true
                        }

                        sendLockSection

                        Button("Unblock All Apps", role: .destructive) {
                            unblockAppsLocally()
                            lockService.clearMyLock()
                        }
                    }
                }
            }
            .padding()
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onAppear {
            if isAuthorized && hasChosenRole {
                startFirebaseListener()
            }
        }
        .onDisappear {
            lockService.stopListening()
        }
        .onChange(of: hasChosenRole) { _, now in
            if now {
                startFirebaseListener()
            }
        }
        .onChange(of: listenToChallenges) { _, _ in
            if isAuthorized && hasChosenRole {
                startFirebaseListener()
            }
        }
    }

    private var rolePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("I am")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(DeviceRole.allCases, id: \.self) { r in
                    Button {
                        role = r
                        hasChosenRole = true
                    } label: {
                        Text(r.rawValue)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(role == r ? Color.accentColor : Color.gray.opacity(0.2))
                            .foregroundColor(role == r ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var sendLockSection: some View {
        VStack(spacing: 8) {
            Text("Send lock to the other device (they will block on their phone)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                lockService.sendLockToOther()
            } label: {
                Label(
                    role == .friendA ? "Lock Friend B" : "Lock Friend A",
                    systemImage: "lock.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty)
        }
    }

    private var createUserSection: some View {
        VStack(spacing: 8) {
            Text("Create your user in the database")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Create user") {
                lockService.createUserDb(name: "name placeholder")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func startFirebaseListener() {
        if listenToChallenges {
            lockService.startListeningForChallenges { shouldBlock in
                if shouldBlock {
                    blockSelectedApps()
                } else {
                    unblockAppsLocally()
                }
            }
        } else {
            lockService.startListening(role: role) { shouldBlock in
                if shouldBlock {
                    blockSelectedApps()
                } else {
                    unblockAppsLocally()
                }
            }
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
