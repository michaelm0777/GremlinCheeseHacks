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
    @State private var showUnblockPushupGate = false
    @State private var copiedUidFeedback = false

    // MARK: - PAIRING (new)
    @State private var showMyQr = false
    @State private var showScanner = false
    @State private var pairingStatusText: String? = nil

    @StateObject private var lockService = FirebaseLockService()

    // MARK: - UI routing (new, keeps existing vars intact)
    @AppStorage("didOnboard_gremlin") private var didOnboard = false
    @State private var activeSheet: ActiveSheet? = nil

    // MARK: - Create challenge UI state (new)
    @State private var pendingSendChallenge: PendingSendChallenge? = nil
    @State private var selectedExerciseType: ChallengeExercise = .pushups
    @State private var selectedRepsPreset: Int? = 25
    @State private var customRepsText: String = "25"
    
    @State private var showReceiverDecision = false

    private var currentStreakDays: Int {
        lockService.currentStreakDays ?? -1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GremlinTheme.background.ignoresSafeArea()

                if !didOnboard {
                    OnboardingView {
                        didOnboard = true
                    }
                } else {
                    HomeView(
                        currentStreakDays: currentStreakDays,
                        userDisplayName: lockService.currentUserNameFallback,
                        dateString: HomeView.defaultDateStringFallback,
                        onTapNewChallenge: {
                            activeSheet = .createChallenge
                        },
                        onTapFriends: {
                            activeSheet = .friends
                        },
                        onTapAddFriend: {
                            activeSheet = .addFriend
                        },
                        recentItems: HomeView.placeholderRecent,
                        hasActiveChallenge: lockService.shouldBlockThisDevice,
                        onUnblockGate: {
                            activeSheet = nil
                            DispatchQueue.main.async {
                                showUnblockPushupGate = true
                            }
                        },
                        onTapHelp: {
                            activeSheet = .settings
                        }
                    )
                }
            }
            .navigationBarHidden(true)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .friends:
                FriendsView(
                    friends: FriendsView.placeholderFriends,
                    onClose: { activeSheet = nil },
                    onAdd: { activeSheet = .addFriend },
                    onChallengeFriend: { friendUid in
                        toUserUid = friendUid
                        activeSheet = .createChallenge
                    }
                )
            case .addFriend:
                AddFriendView(
                        uidText: lockService.currentUserUid ?? "loading_uid",
                        onClose: { activeSheet = nil },
                        onShareQr: {
                            activeSheet = nil
                            DispatchQueue.main.async {
                                showMyQr = true
                            }
                        },
                        onScanQr: {
                            activeSheet = nil
                            DispatchQueue.main.async {
                                showScanner = true
                            }
                        },
                        pairingStatusText: pairingStatusText
                    )
            case .createChallenge:
                CreateChallengeView(
                    selectedExerciseType: $selectedExerciseType,
                    selectedRepsPreset: $selectedRepsPreset,
                    customRepsText: $customRepsText,
                    onClose: { activeSheet = nil },
                    onSend: { exerciseType, reps in
                        selectedExerciseType = exerciseType
                        customRepsText = "\(reps)"
                        selectedRepsPreset = reps

                        activeSheet = nil
                        DispatchQueue.main.async {
                            pendingSendChallenge = PendingSendChallenge(
                                reps: reps,
                                exerciseType: exerciseType
                            )
                        }
                    }
                )
            case .settings:
                SettingsView(
                    isAuthorized: isAuthorized,
                    selectedAppsEmpty: selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty,
                    onClose: { activeSheet = nil },
                    onRequestAuthorization: {
                        requestAuthorization()
                    },
                    onPickApps: {
                        showPicker = true
                    },
                    onCreateUser: {
                        lockService.createUserDb(name: "name placeholder")
                    },
                    onUnblockGate: {
                        activeSheet = nil
                        DispatchQueue.main.async {
                            showUnblockPushupGate = true
                        }
                    },
                    hasActiveChallenge: lockService.shouldBlockThisDevice
                )
            }
        }
        // Show QR sheet (kept from your code)
        .sheet(isPresented: $showMyQr) {
            if let uid = lockService.currentUserUid {
                MyQrCodeView(payload: uid)
                    .presentationDetents([.medium, .large])
            } else {
                Text("No UID yet.")
                    .padding()
            }
        }
        // Scan QR sheet (kept from your code)
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
                        toUserUid = otherUid
                    case .failure(let error):
                        pairingStatusText = "Pair failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        // Sender gate: item-based so the challenge payload is passed in (no stale state on first send)
        .fullScreenCover(item: $pendingSendChallenge) { challenge in
            let exercise = challenge.exerciseType.rawValue
            let exerciseLabel = exercise == "jumping jacks" ? "jumping jacks" : "pushups"
            let title = "Do \(challenge.reps) \(exerciseLabel) to send challenge"

            if exercise == "jumping jacks" {
                JumpingJackGateView(
                    title: title,
                    requiredReps: challenge.reps,
                    onComplete: {
                        lockService.createChallenge(
                            exerciseType: exercise,
                            reps: challenge.reps,
                            blockDurationSec: 300
                        )
                        pendingSendChallenge = nil
                    },
                    onCancel: { pendingSendChallenge = nil }
                )
            } else {
                PushupGateView(
                    title: title,
                    requiredReps: challenge.reps,
                    onComplete: {
                        lockService.createChallenge(
                            exerciseType: exercise,
                            reps: challenge.reps,
                            blockDurationSec: 300
                        )
                        pendingSendChallenge = nil
                    },
                    onCancel: { pendingSendChallenge = nil }
                )
            }
        }
        
        .fullScreenCover(isPresented: $showReceiverDecision) {
            ReceiverChallengeFlowView(
                challenge: lockService.activeChallenge,
                onResolveOnly: {
                    lockService.resolveChallengesTargetingMe()
                    unblockAppsLocally()
                    showReceiverDecision = false
                },
                onResolveAndSendBack: { toUser, exerciseType, repsToSend, inChallenge in
                    lockService.resolveChallengesTargetingMe()
                    unblockAppsLocally()
                    lockService.createChallenge(
                        toUser: toUser,
                        exerciseType: exerciseType,
                        reps: repsToSend,
                        blockDurationSec: 300,
                        inChallenge: inChallenge
                    )
                    showReceiverDecision = false
                },
                onForfeitAwardPoint: { winnerUid in
                    lockService.incrementChallengeScore(for: winnerUid)
                }
            )
        }
        
        // Receiver unblock gate: do the same exercise/reps as the active challenge from Firebase
        .fullScreenCover(isPresented: $showUnblockPushupGate) {
            let challenge = lockService.activeChallenge
            let exercise = challenge?.exerciseType ?? "pushups"
            let reps = challenge?.reps ?? 3
            let exerciseLabel = exercise == "jumping jacks" ? "jumping jacks" : "pushups"
            let title = "Do \(reps) \(exerciseLabel) to unblock"

            if exercise == "jumping jacks" {
                JumpingJackGateView(
                    title: title,
                    requiredReps: reps,
                    onComplete: {
                        lockService.resolveChallengesTargetingMe()
                        unblockAppsLocally()
                        showUnblockPushupGate = false
                    },
                    onCancel: {}
                )
            } else {
                PushupGateView(
                    title: title,
                    requiredReps: reps,
                    onComplete: {
                        lockService.resolveChallengesTargetingMe()
                        unblockAppsLocally()
                        showUnblockPushupGate = false
                    },
                    onCancel: {}
                )
            }
        }
        
        .onAppear {
            lockService.startListeningForChallenges { shouldBlock in
                if shouldBlock {
                    blockSelectedApps()
                    DispatchQueue.main.async {
                        showReceiverDecision = true
                    }
                } else {
                    unblockAppsLocally()
                    DispatchQueue.main.async {
                        showReceiverDecision = false
                    }
                }

                lockService.startListeningForMyProfile()
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

    // MARK: - Sheets
    private enum ActiveSheet: Identifiable {
        case friends
        case addFriend
        case createChallenge
        case settings

        var id: String {
            switch self {
            case .friends: return "friends"
            case .addFriend: return "addFriend"
            case .createChallenge: return "createChallenge"
            case .settings: return "settings"
            }
        }
    }
}

// MARK: - Theme

private enum GremlinTheme {
    static let background = LinearGradient(
        gradient: Gradient(colors: [
            Color(red: 0.05, green: 0.07, blue: 0.16),
            Color(red: 0.04, green: 0.05, blue: 0.12)
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let textSecondary = Color.white.opacity(0.55)
    static let accentGreen = Color(red: 0.05, green: 0.78, blue: 0.40)
}

// MARK: - Onboarding

private struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(GremlinTheme.accentGreen)
                    .frame(width: 84, height: 84)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text("gremlin")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("lock your friends out of apps until\nthey finish their workout")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GremlinTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Spacer()

            Button(action: onContinue) {
                Text("let's go")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: GremlinTheme.accentGreen.opacity(0.25), radius: 16, x: 0, y: 10)
            }
            .padding(.horizontal, 28)

            Text("tap to continue")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GremlinTheme.textSecondary)
                .padding(.bottom, 10)

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Home

private struct HomeView: View {
    let currentStreakDays: Int
    let userDisplayName: String
    let dateString: String

    let onTapNewChallenge: () -> Void
    let onTapFriends: () -> Void
    let onTapAddFriend: () -> Void
    let recentItems: [RecentItem]

    let hasActiveChallenge: Bool
    let onUnblockGate: () -> Void
    let onTapHelp: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                streakCard
                quickActionsSection
                recentSection
                Spacer(minLength: 18)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: onTapHelp) {
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("hey \(userDisplayName) 👋")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)

                Text(dateString.lowercased())
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GremlinTheme.textSecondary)
            }

            Spacer()

            Button(action: {}) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: GremlinTheme.accentGreen.opacity(0.25), radius: 14, x: 0, y: 8)
            }
            .accessibilityLabel("Streak")
        }
    }

    private var streakCard: some View {
        GremlinCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("current streak")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GremlinTheme.textSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(currentStreakDays)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)

                        Text("days")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(GremlinTheme.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GremlinTheme.accentGreen)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasActiveChallenge {
                Text("active")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                    .padding(14)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QUICK ACTIONS")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GremlinTheme.textSecondary)
                .tracking(1.0)
                .padding(.top, 6)

            if hasActiveChallenge {
                Button(action: onUnblockGate) {
                    QuickActionRow(
                        icon: "lock.open.fill",
                        iconBackground: Color.red.opacity(0.25),
                        title: "Unblock My Apps",
                        subtitle: "complete challenge to unblock"
                    )
                }
                .buttonStyle(.plain)
            }

            Button(action: onTapNewChallenge) {
                QuickActionRow(
                    icon: "scope",
                    iconBackground: GremlinTheme.accentGreen.opacity(0.18),
                    title: "new challenge",
                    subtitle: "dare a friend"
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                Button(action: onTapFriends) {
                    QuickActionTile(
                        icon: "person.2.fill",
                        iconBackground: Color.blue.opacity(0.25),
                        title: "friends",
                        subtitle: "8 online"
                    )
                }
                .buttonStyle(.plain)

                Button(action: onTapAddFriend) {
                    QuickActionTile(
                        icon: "person.badge.plus.fill",
                        iconBackground: Color.purple.opacity(0.25),
                        title: "add",
                        subtitle: "via QR"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GremlinTheme.textSecondary)
                .tracking(1.0)
                .padding(.top, 10)

            ForEach(recentItems) { item in
                GremlinCard {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(item.avatarColor.opacity(0.95))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Text(item.avatarText)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)

                            Text(item.subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(GremlinTheme.textSecondary)
                        }

                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Placeholder data (kept local to this file)
    struct RecentItem: Identifiable {
        let id = UUID()
        let avatarText: String
        let avatarColor: Color
        let title: String
        let subtitle: String
    }

    static let placeholderRecent: [RecentItem] = [
        RecentItem(
            avatarText: "SC",
            avatarColor: Color.blue,
            title: "sam completed 50 pushups",
            subtitle: "2h ago"
        )
    ]

    static var defaultDateStringFallback: String {
        // Not tied to locale formatting from Figma; just a safe fallback.
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }
}

private struct GremlinCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(GremlinTheme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(GremlinTheme.cardStroke, lineWidth: 1)
            )
    }
}

private struct QuickActionRow: View {
    let icon: String
    let iconBackground: Color
    let title: String
    let subtitle: String

    var body: some View {
        GremlinCard {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(GremlinTheme.accentGreen)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GremlinTheme.textSecondary)
                }

                Spacer()
            }
        }
    }
}

private struct QuickActionTile: View {
    let icon: String
    let iconBackground: Color
    let title: String
    let subtitle: String

    var body: some View {
        GremlinCard {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    )

                Spacer(minLength: 6)

                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GremlinTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        }
    }
}

// MARK: - Friends

private struct FriendsView: View {
    struct Friend: Identifiable {
        let id = UUID()
        let initials: String
        let name: String
        let statusDot: Color
        let subtitle: String
        let streakDays: Int
        let avatarGradient: [Color]
        let uid: String
        let bigWins: Int
    }

    let friends: [Friend]
    let onClose: () -> Void
    let onAdd: () -> Void
    let onChallengeFriend: (String) -> Void

    var body: some View {
        ZStack {
            GremlinTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                header

                Text("3 online  •  \(friends.count) total")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GremlinTheme.textSecondary)
                    .padding(.horizontal, 18)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(friends) { f in
                            GremlinCard {
                                HStack(spacing: 14) {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: f.avatarGradient),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 54, height: 54)
                                        .overlay(
                                            Text(f.initials)
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white)
                                        )

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Text(f.name)
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(.white)

                                            Circle()
                                                .fill(f.statusDot)
                                                .frame(width: 8, height: 8)
                                        }

                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "trophy.fill")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Color.yellow.opacity(0.9))

                                                Text("\(f.bigWins) big wins")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(Color.yellow.opacity(0.9))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }

                                            HStack(spacing: 8) {
                                                Image(systemName: "bolt.fill")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(Color.orange.opacity(0.9))

                                                Text("\(f.streakDays) day streak")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(Color.orange.opacity(0.9))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                        }
                                        .padding(.top, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }

                                    Spacer()

                                    Button("challenge") {
                                        onChallengeFriend(f.uid)
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(GremlinTheme.accentGreen)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(GremlinTheme.accentGreen.opacity(0.12), in: Capsule())
                                    .overlay(Capsule().stroke(GremlinTheme.accentGreen.opacity(0.25), lineWidth: 1))
                                }
                            }
                            .padding(.horizontal, 18)
                        }

                        Button(action: onAdd) {
                            Text("invite more friends →")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(GremlinTheme.textSecondary)
                                .padding(.vertical, 18)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("friends")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }

                Spacer()

                Button("add") {
                    onAdd()
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(GremlinTheme.accentGreen)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    static let placeholderFriends: [Friend] = [
        Friend(
            initials: "SJ",
            name: "sarah",
            statusDot: .green,
            subtitle: "beat you at pushups 💪",
            streakDays: 12,
            avatarGradient: [Color.pink, Color.red],
            uid: "sarah_uid_placeholder",
            bigWins: 3,
        ),
        Friend(
            initials: "MC",
            name: "mike",
            statusDot: .gray.opacity(0.6),
            subtitle: "50 jumping jacks",
            streakDays: 8,
            avatarGradient: [Color.blue, Color.indigo],
            uid: "mike_uid_placeholder",
            bigWins: 3,
        ),
        Friend(
            initials: "ED",
            name: "emma",
            statusDot: .green,
            subtitle: "absolutely destroyed you",
            streakDays: 15,
            avatarGradient: [Color.purple, Color.pink],
            uid: "emma_uid_placeholder",
            bigWins: 3,
        ),
        Friend(
            initials: "JW",
            name: "james",
            statusDot: .gray.opacity(0.6),
            subtitle: "12 jumping jacks",
            streakDays: 5,
            avatarGradient: [Color.orange, Color.red],
            uid: "james_uid_placeholder",
            bigWins: 3,
        ),
        Friend(
            initials: "LA",
            name: "lisa",
            statusDot: .green,
            subtitle: "on fire this week 🔥",
            streakDays: 20,
            avatarGradient: [Color.teal, Color.cyan],
            uid: "lisa_uid_placeholder",
            bigWins: 3,
        )
    ]
}

// MARK: - Add Friend

private struct AddFriendView: View {
    let uidText: String
    let onClose: () -> Void
    let onShareQr: () -> Void
    let onScanQr: () -> Void
    let pairingStatusText: String?

    @State private var copiedUidFeedback = false

    var body: some View {
        ZStack {
            GremlinTheme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                header

                Text("share your code or scan theirs")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GremlinTheme.textSecondary)
                    .padding(.top, 4)

                GremlinCard {
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.95))
                                .frame(maxWidth: .infinity)
                                .frame(height: 190)

                            Image(uiImage: qrImage(from: uidText))
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(18)
                                .frame(height: 190)
                        }

                        VStack(spacing: 8) {
                            Text("your id")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(GremlinTheme.textSecondary)

                            HStack(spacing: 10) {
                                Text(uidText)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Button(action: {
                                    UIPasteboard.general.string = uidText
                                    copiedUidFeedback = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        copiedUidFeedback = false
                                    }
                                }) {
                                    Image(systemName: copiedUidFeedback ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .frame(width: 34, height: 34)
                                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                        )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)

                Button(action: onShareQr) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .bold))
                        Text("share QR code")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 18)

                Button(action: onScanQr) {
                    Text("scan friend's code")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 18)

                GremlinCard {
                    Text("when they scan your code, you'll both be able to send challenges and lock each other's apps")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.blue.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)

                if let pairingStatusText {
                    Text(pairingStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GremlinTheme.textSecondary)
                        .padding(.top, 6)
                        .padding(.horizontal, 18)
                }

                Spacer()
            }
            .padding(.top, 10)
        }
    }

    private var header: some View {
        ZStack {
            Text("add friend")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func qrImage(from payload: String) -> UIImage {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)

        guard let output = filter.outputImage else {
            return UIImage(systemName: "xmark.circle") ?? UIImage()
        }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        if let cg = context.createCGImage(scaled, from: scaled.extent) {
            return UIImage(cgImage: cg)
        }
        return UIImage(systemName: "xmark.circle") ?? UIImage()
    }
}

// MARK: - Create Challenge

/// Payload for the send-challenge gate. Item-based fullScreenCover uses this so the first send gets the correct reps/exercise.
private struct PendingSendChallenge: Identifiable {
    let id = UUID()
    let reps: Int
    let exerciseType: ChallengeExercise
}

private enum ChallengeExercise: String, CaseIterable, Identifiable {
    case pushups = "pushups"
    case jumpingJacks = "jumping jacks"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .pushups: return "figure.strengthtraining.traditional"
        case .jumpingJacks: return "figure.jumprope"
        }
    }

    var iconTint: Color {
        switch self {
        case .pushups: return .orange
        case .jumpingJacks: return .blue
        }
    }
}

private struct CreateChallengeView: View {
    @Binding var selectedExerciseType: ChallengeExercise
    @Binding var selectedRepsPreset: Int?
    @Binding var customRepsText: String

    let onClose: () -> Void
    let onSend: (_ exerciseType: ChallengeExercise, _ reps: Int) -> Void

    @FocusState private var repsFieldFocused: Bool

    private let presets = [10, 25, 50, 100]

    var body: some View {
        ZStack {
            GremlinTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("PICK EXERCISE")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GremlinTheme.textSecondary)
                            .tracking(1.0)
                            .padding(.top, 8)

                        VStack(spacing: 12) {
                            ForEach(ChallengeExercise.allCases) { exercise in
                                exerciseRow(exercise: exercise)
                            }
                        }

                        Text("HOW MANY?")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(GremlinTheme.textSecondary)
                            .tracking(1.0)
                            .padding(.top, 12)

                        HStack(spacing: 12) {
                            ForEach(presets, id: \.self) { n in
                                Button(action: {
                                    selectedRepsPreset = n
                                    customRepsText = "\(n)"
                                    repsFieldFocused = false
                                }) {
                                    Text("\(n)")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(selectedRepsPreset == n ? .white : GremlinTheme.textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(
                                            selectedRepsPreset == n ? GremlinTheme.accentGreen : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            Text("custom:")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(GremlinTheme.textSecondary)

                            TextField("25", text: $customRepsText)
                                .keyboardType(.numberPad)
                                .focused($repsFieldFocused)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("reps")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(GremlinTheme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )

                        GremlinCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(GremlinTheme.accentGreen)

                                    Text("CHALLENGE PREVIEW")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(GremlinTheme.textSecondary)
                                        .tracking(0.8)
                                }

                                HStack(spacing: 14) {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(selectedExerciseType.iconTint.opacity(0.18))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: selectedExerciseType.iconName)
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundStyle(selectedExerciseType.iconTint)
                                        )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(resolvedReps) \(selectedExerciseType.rawValue)")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(.white)
                                        Text("their tiktok locks until they finish")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(GremlinTheme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(GremlinTheme.accentGreen.opacity(0.25), lineWidth: 1)
                        )
                        .padding(.top, 8)

                        Button(action: {
                            onSend(selectedExerciseType, resolvedReps)
                        }) {
                            Text("send challenge 🔥")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                }
            }
            .padding(.top, 10)
        }
    }

    private var header: some View {
        ZStack {
            Text("create challenge")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func exerciseRow(exercise: ChallengeExercise) -> some View {
        let isSelected = selectedExerciseType == exercise

        return Button(action: {
            selectedExerciseType = exercise
        }) {
            GremlinCard {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(exercise.iconTint.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: exercise.iconName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(exercise.iconTint)
                        )

                    Text(exercise.rawValue)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 2)
                            .frame(width: 22, height: 22)

                        if isSelected {
                            Circle()
                                .fill(GremlinTheme.accentGreen)
                                .frame(width: 10, height: 10)
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? GremlinTheme.accentGreen.opacity(0.35) : Color.white.opacity(0.0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var resolvedReps: Int {
        let n = Int(customRepsText) ?? (selectedRepsPreset ?? 25)
        return max(1, n)
    }
}

// MARK: - Settings (contains your “Request Authorization / Pick Apps” so functionality stays)

private struct SettingsView: View {
    let isAuthorized: Bool
    let selectedAppsEmpty: Bool

    let onClose: () -> Void
    let onRequestAuthorization: () -> Void
    let onPickApps: () -> Void
    let onCreateUser: () -> Void

    let onUnblockGate: () -> Void
    let hasActiveChallenge: Bool

    var body: some View {
        ZStack {
            GremlinTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        GremlinCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Receiver setup (required to block apps)")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)

                                Text("You must authorize and pick apps to control so that incoming challenges can block them.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(GremlinTheme.textSecondary)

                                HStack(spacing: 12) {
                                    Button("Request Authorization") {
                                        onRequestAuthorization()
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    Button("Pick Apps") {
                                        onPickApps()
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                    )
                                    .disabled(!isAuthorized)
                                    .opacity(isAuthorized ? 1.0 : 0.6)
                                }

                                if isAuthorized && selectedAppsEmpty {
                                    Text("No apps selected yet. Pick apps so they can be blocked by a challenge.")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.orange.opacity(0.9))
                                        .padding(.top, 6)
                                }
                            }
                        }

                        if hasActiveChallenge {
                            GremlinCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Active challenge")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)

                                    Text("Complete the same challenge (same exercise & reps) to remove the shield.")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(GremlinTheme.textSecondary)

                                    Button(role: .destructive) {
                                        onUnblockGate()
                                    } label: {
                                        Text("Unblock My Apps")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                }
                            }
                        }

                        GremlinCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Debug")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)

                                Button("Create user") {
                                    onCreateUser()
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                            }
                        }

                        Spacer(minLength: 18)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 10)
        }
    }

    private var header: some View {
        ZStack {
            Text("settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

// MARK: - Convenience (non-breaking; used only for display)

private extension FirebaseLockService {
    var currentUserNameFallback: String {
        // If your service already has a name, return it; otherwise show a safe fallback.
        // TODO: connect to your real profile/name.
        return "alex"
    }
}

// MARK: - QR display (kept from your code; used by “Show My QR” sheet)

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

// MARK: - QR scanner (kept from your code)

private struct QrScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct ReceiverChallengeFlowView: View {
    let challenge: FirebaseLockService.ActiveChallenge?
    let onResolveOnly: () -> Void
    let onResolveAndSendBack: (_ toUser: String, _ exerciseType: String, _ repsToSend: Int, _ inChallenge: Bool) -> Void
    let onForfeitAwardPoint: (_ winnerUid: String) -> Void
    
    @State private var selectedAction: Action? = nil

    private enum Action {
        case complete
        case startBig
        case continueChain
        case forfeit
    }

    var body: some View {
        ZStack {
            GremlinTheme.background.ignoresSafeArea()

            if let ch = challenge {
                if selectedAction == nil {
                    decisionUI(for: ch)
                } else {
                    gateUI(for: ch, action: selectedAction!)
                }
            } else {
                VStack(spacing: 12) {
                    Text("No active challenge.")
                        .foregroundStyle(.white)
                    Button("Close") {
                        onResolveOnly()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private func decisionUI(for ch: FirebaseLockService.ActiveChallenge) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Challenge received")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text("\(ch.reps) \(ch.exerciseType)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GremlinTheme.textSecondary)

            Spacer()

            if ch.inChallenge {
                Button("continue challenge") {
                    selectedAction = .continueChain
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)

                Button(role: .destructive) {
                    selectedAction = .forfeit
                } label: {
                    Text("forfeit challenge (do \(max(1, ch.reps - 5)))")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                }
            } else {
                Button("complete") {
                    selectedAction = .complete
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(GremlinTheme.accentGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)

                Button("start big challenge (+5 reps)") {
                    selectedAction = .startBig
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
            }

            Spacer(minLength: 18)
        }
    }

    private func gateUI(for ch: FirebaseLockService.ActiveChallenge, action: Action) -> some View {
        let exercise = ch.exerciseType
        let incomingR = ch.reps

        // Required reps for ME (receiver)
        let myRequired: Int = {
            switch action {
            case .startBig:
                return incomingR + 5
            case .forfeit:
                return max(1, incomingR - 5)   // <-- key change
            case .complete, .continueChain:
                return incomingR
            }
        }()

        // Reps I send back (if I continue/escalate)
        let sendBackReps: Int? = {
            switch action {
            case .startBig:
                return (incomingR + 5) + 5   // R+10
            case .continueChain:
                return incomingR + 5         // R+5
            case .complete, .forfeit:
                return nil
            }
        }()

        let title = "Do \(myRequired) \(exercise == "jumping jacks" ? "jumping jacks" : "pushups")"

        return Group {
            if exercise == "jumping jacks" {
                JumpingJackGateView(
                    title: title,
                    requiredReps: myRequired,
                    onComplete: {
                        if action == .forfeit {
                            if !ch.fromUser.isEmpty {
                                onForfeitAwardPoint(ch.fromUser)
                            }
                            onResolveOnly()
                            return
                        }

                        if let back = sendBackReps, !ch.fromUser.isEmpty {
                            onResolveAndSendBack(ch.fromUser, exercise, back, true)
                        } else {
                            onResolveOnly()
                        }
                    },
                    onCancel: {}
                )
            } else {
                PushupGateView(
                    title: title,
                    requiredReps: myRequired,
                    onComplete: {
                        if action == .forfeit {
                            if !ch.fromUser.isEmpty {
                                onForfeitAwardPoint(ch.fromUser)
                            }
                            onResolveOnly()
                            return
                        }

                        if let back = sendBackReps, !ch.fromUser.isEmpty {
                            onResolveAndSendBack(ch.fromUser, exercise, back, true)
                        } else {
                            onResolveOnly()
                        }
                    },
                    onCancel: {}
                )
            }
        }
    }
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
/*
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

                    Button("Send Challenge (3 pushups to send → locks their apps)") {
                        showBlockPushupGate = true
                    }
                    .buttonStyle(.borderedProminent)

                    Text("The other phone must have opened this app, authorized, and picked apps to control first, or nothing will be blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // MARK: - Blocked state & unblock (existing)
                    if lockService.shouldBlockThisDevice {
                        Text("You have an active challenge. Complete the same challenge (same exercise & reps) to unblock your apps.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Button("Unblock My Apps", role: .destructive) {
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
                        exerciseType: "pushups",
                        reps: 3,
                        blockDurationSec: 300
                    )
                },
                onCancel: {}
            )
        }
        .fullScreenCover(isPresented: $showUnblockPushupGate) {
            Group {
                let challenge = lockService.activeChallenge
                let exercise = challenge?.exerciseType ?? "pushups"
                let reps = challenge?.reps ?? 3
                let title = "Do \(reps) \(exercise == "jumping jacks" ? "jumping jacks" : "pushups") to unblock"
                if exercise == "jumping jacks" {
                    JumpingJackGateView(title: title, requiredReps: reps, onComplete: {
                        lockService.resolveChallengesTargetingMe()
                        unblockAppsLocally()
                    }, onCancel: {})
                } else {
                    PushupGateView(title: title, requiredReps: reps, onComplete: {
                        lockService.resolveChallengesTargetingMe()
                        unblockAppsLocally()
                    }, onCancel: {})
                }
            }
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
*/
