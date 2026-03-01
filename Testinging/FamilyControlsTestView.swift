import SwiftUI
import FamilyControls
import ManagedSettings

private let managedSettingsStore = ManagedSettingsStore()

struct FamilyControlsTestView: View {
    @State private var selection = FamilyActivitySelection()          // local allowlist
    @State private var showPicker = false
    @State private var isAuthorized = false

    @State private var toUserUid: String = ""

    @State private var showBlockPushupGate = false
    @State private var showUnblockPushupGate = false

    // Sender chooses per-challenge subset (for now Discord + YouTube)
    @State private var blockDiscord = true
    @State private var blockYouTube = true

    @StateObject private var lockService = FirebaseLockService()

    private let selectionStorageKey = "saved_family_activity_selection"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Button("Request Authorization") { requestAuthorization() }

                Button("Create user") {
                    lockService.createUserDb(name: "name placeholder")
                }
                .buttonStyle(.borderedProminent)

                TextField("Send challenge to UID", text: $toUserUid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button("Pick Apps to Control (allowlist, saved)") {
                    showPicker = true
                }
                .disabled(!isAuthorized)

                // Per-challenge choices (sender-side)
                Toggle("Block Discord", isOn: $blockDiscord)
                Toggle("Block YouTube", isOn: $blockYouTube)

                Button("Send Challenge (locks receiver)") {
                    showBlockPushupGate = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(toUserUid.isEmpty || (!blockDiscord && !blockYouTube))

                Button("Unblock All Apps", role: .destructive) {
                    showUnblockPushupGate = true
                }

                Spacer()
            }
            .padding()
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: showPicker) { _, isShowing in
            if isShowing == false {
                saveSelectionLocally(selection) // receiver allowlist saved locally
            }
        }
        .fullScreenCover(isPresented: $showBlockPushupGate) {
            PushupGateView(
                title: "Do 3 pushups to send block",
                requiredReps: 3,
                onComplete: {
                    let blocked = computeBlockedBundleIdsForChallenge()

                    lockService.createChallenge(
                        toUser: toUserUid,
                        exerciseType: "pushups",
                        reps: 3,
                        blockDurationSec: 300,
                        blockedBundleIds: blocked
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
            // load allowlist selection (tokens) for this device
            selection = loadSelectionLocally()

            lockService.startListeningForChallenges { shouldBlock in
                if shouldBlock {
                    blockFromPendingChallenge()
                } else {
                    unblockAppsLocally()
                }
            }
        }
        .onDisappear { lockService.stopListening() }
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

    // Sender-side: map toggles -> bundleIds (for now). Scales by adding more bundleIds later.
    private func computeBlockedBundleIdsForChallenge() -> [String] {
        var ids: [String] = []
        if blockDiscord { ids.append("com.hammerandchisel.discord") }
        if blockYouTube { ids.append("com.google.ios.youtube") }
        return ids
    }

    // Receiver-side: block pending challenge bundleIds, but only if they exist in my saved allowlist selection.
    private func blockFromPendingChallenge() {
        let allowlist = loadSelectionLocally()
        let requested = Set(lockService.pendingBlockedBundleIds)

        let tokensToBlock = allowlist.applicationTokens.filter { token in
            guard let bid = token.bundleIdentifier else { return false }
            return requested.contains(bid)
        }

        managedSettingsStore.shield.applications = Set(tokensToBlock)
        managedSettingsStore.shield.applicationCategories = .none
    }

    private func unblockAppsLocally() {
        managedSettingsStore.shield.applications = []
        managedSettingsStore.shield.applicationCategories = .none
    }

    // MARK: - Local persistence

    private func saveSelectionLocally(_ selection: FamilyActivitySelection) {
        do {
            let data = try JSONEncoder().encode(selection)
            UserDefaults.standard.set(data, forKey: selectionStorageKey)
        } catch {
            print("Failed to save selection locally:", error)
        }
    }

    private func loadSelectionLocally() -> FamilyActivitySelection {
        guard let data = UserDefaults.standard.data(forKey: selectionStorageKey) else {
            return FamilyActivitySelection()
        }
        do {
            return try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("Failed to load selection locally:", error)
            return FamilyActivitySelection()
        }
    }
}
