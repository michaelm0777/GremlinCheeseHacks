//
//  FamilyControlsTestView.swift
//  Testinging
//
//  Two-device developer flow: each phone runs this app and listens to Firebase.
//  Friend A sends "lock Friend B" → Friend B’s app blocks its own device (and vice versa).
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
    @State private var hasChosenRole = false
    @StateObject private var lockService = FirebaseLockService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // 1. Request Family Controls authorization
                Button("Request Authorization") {
                    requestAuthorization()
                }

                if isAuthorized {
                    // 2. Choose role (Friend A or Friend B)
                    if !hasChosenRole {
                        rolePickerSection
                    } else {
                        // 3. Pick apps to control (same selection used when we get "lock" from other device)
                        Button("Pick Apps to Control") {
                            showPicker = true
                        }

                        // 4. Send lock to the other device (like "Friend A completed push-ups → lock Friend B")
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

    private func startFirebaseListener() {
        lockService.startListening(role: role) { shouldBlock in
            if shouldBlock {
                blockSelectedApps()
            } else {
                unblockAppsLocally()
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

    /// Clears shield on this device only. Use when responding to Firebase "unlock" or when user taps Unblock (then also call clearMyLock()).
    private func unblockAppsLocally() {
        managedSettingsStore.shield.applications = []
        managedSettingsStore.shield.applicationCategories = .none
    }
}
