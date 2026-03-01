//
//  FamilyControlsTestView.swift
//  Testinging
//

import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

private let managedSettingsStore = ManagedSettingsStore()

struct FamilyControlsTestView: View {
    @State private var pickerSelection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var isAuthorized = false

    @State private var toUserUid: String = ""
    @State private var showBlockPushupGate = false
    @State private var showUnblockPushupGate = false
    @State private var copiedUidFeedback = false

    // Which app key we are currently mapping via the picker
    @State private var mappingAppKey: String? = nil

    // Sender chooses app keys to block
    @State private var selectedBlockKeys: Set<String> = []

    @StateObject private var lockService = FirebaseLockService()

    // Extendable predefined list (NOT hardcoded to only two)
    private struct BlockableApp: Identifiable, Hashable {
        let id: String
        let label: String
    }

    private let availableApps: [BlockableApp] = [
        .init(id: "discord", label: "Discord"),
        .init(id: "youtube", label: "YouTube"),
    ]
    
    

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

                    // MARK: - Setup section
                    Text("Setup (receiver must do once)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button("Request Authorization") { requestAuthorization() }

                    Button("Create user") {
                        lockService.createUserDb(name: "name placeholder")
                    }
                    .buttonStyle(.bordered)

                    Text("Map apps you allow others to block on this phone:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(availableApps, id: \.id) { app in
                        HStack {
                            Button("Map \(app.label)") {
                                mappingAppKey = app.id
                                pickerSelection = FamilyActivitySelection()
                                showPicker = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(!isAuthorized)

                            Spacer()

                            Text(isMapped(app.id) ? "Mapped" : "Not mapped")
                                .font(.caption)
                                .foregroundStyle(isMapped(app.id) ? .secondary : .orange)
                        }
                    }

                    Divider()

                    // MARK: - Sender section
                    Text("Send challenge to other phone")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Other phone's UID", text: $toUserUid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Text("Choose which apps to block on the other phone:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(availableApps) { app in
                        Toggle(app.label, isOn: Binding(
                            get: { selectedBlockKeys.contains(app.id) },
                            set: { on in
                                if on { selectedBlockKeys.insert(app.id) }
                                else { selectedBlockKeys.remove(app.id) }
                            }
                        ))
                    }

                    Button("Send Challenge (3 pushups → locks chosen apps)") {
                        showBlockPushupGate = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        toUserUid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        selectedBlockKeys.isEmpty
                    )

                    Text("Receiver must have mapped those app(s) locally; otherwise nothing happens for missing mappings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // MARK: - Receiver state
                    if lockService.shouldBlockThisDevice {
                        Text("Active challenge. Apps should be blocked now.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

                        Text("Requested block keys: \(lockService.pendingBlockAppKeys.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Unblock My Apps (3 pushups)", role: .destructive) {
                        showUnblockPushupGate = true
                    }

                    Spacer(minLength: 24)
                }
                .padding()
            }
            .navigationTitle("Challenge")
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $pickerSelection)
        .onChange(of: showPicker) { _, nowShowing in
            // Picker just closed: if we were mapping a key, save it
            if !nowShowing, let key = mappingAppKey {
                saveMapping(for: key, from: pickerSelection)
                mappingAppKey = nil
                pickerSelection = FamilyActivitySelection()
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
                        blockDurationSec: 300,
                        blockAppKeys: Array(selectedBlockKeys)
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
                    blockAppsFromPendingChallenge()
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

    // Apply block based on pending keys -> local mappings
    private func blockAppsFromPendingChallenge() {
        let keys = lockService.pendingBlockAppKeys
        let tokens = keys.compactMap { loadToken(for: $0) }

        guard !tokens.isEmpty else {
            // Nothing mapped on this device for requested keys.
            managedSettingsStore.shield.applications = nil
            managedSettingsStore.shield.applicationCategories = .none
            return
        }

        managedSettingsStore.shield.applications = Set(tokens)
        managedSettingsStore.shield.applicationCategories = .none
    }

    private func unblockAppsLocally() {
        managedSettingsStore.shield.applications = nil
        managedSettingsStore.shield.applicationCategories = .none
    }

    // MARK: - Local mapping storage (UserDefaults)

    // Store a SINGLE app token chosen in the picker for a given key.
    // Requirement: when mapping, user should select exactly one app.
    private func saveMapping(for key: String, from selection: FamilyActivitySelection) {
        guard let token = selection.applicationTokens.first else {
            print("Mapping failed: no app selected for key:", key)
            return
        }

        do {
            let data = try JSONEncoder().encode(token)
            var dict = loadTokenDict()
            dict[key] = data
            saveTokenDict(dict)
            print("Mapped key:", key)
        } catch {
            print("Token encode error:", error)
        }
    }

    private func loadToken(for key: String) -> ApplicationToken? {
        let dict = loadTokenDict()
        guard let data = dict[key] else { return nil }
        return try? JSONDecoder().decode(ApplicationToken.self, from: data)
    }

    private func isMapped(_ key: String) -> Bool {
        loadToken(for: key) != nil
    }

    private func loadTokenDict() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: "appTokenMap") else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private func saveTokenDict(_ dict: [String: Data]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: "appTokenMap")
    }
}
