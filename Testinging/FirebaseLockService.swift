//
//  FirebaseLockService.swift
//  Testinging
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth
import FirebaseStorage

@MainActor
final class FirebaseLockService: ObservableObject {
    private let db = Firestore.firestore()

    // Challenges listener
    private var listener: ListenerRegistration?

    // User profile listener (streak)
    private var profileListener: ListenerRegistration?

    @Published private(set) var shouldBlockThisDevice = false
    /// When there is a pending challenge targeting this user, holds the exercise type and reps required to unblock.
    struct ActiveChallenge {
        let id: String
        let fromUser: String
        let exerciseType: String
        let reps: Int
        let inChallenge: Bool
    }

    @Published private(set) var activeChallenge: ActiveChallenge?
    /// Current user's UID (set when signed in). Share this with the other phone so they can send you a challenge.
    @Published private(set) var currentUserUid: String?

    // NEW: exposed for UI
    @Published var currentStreakDays: Int? = nil
    @Published private(set) var currentUsername: String? = nil
    
    struct FriendSummary: Identifiable {
        var id: String { uid }
        let uid: String
        var username: String
        var streakDays: Int
        var bigWins: Int
    }

    @Published private(set) var friends: [FriendSummary] = []

    private var pairsListener: ListenerRegistration?
    private var friendProfileListeners: [String: ListenerRegistration] = [:] // key = friend uid

    // MARK: - Create user (users/{uid})

    func createUserDb(name: String) {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }
            self.db.collection("users").document(uid).setData([
                "createdAt": FieldValue.serverTimestamp(),
                "username": name,
                "autoLockEnabled": true,
                // NEW defaults for streak tracking
                "streakDays": 0,
                "lastChallengeDate": NSNull()
            ], merge: true) { error in
                if let error = error {
                    print("Firestore createUser error:", error)
                } else {
                    print("User doc upserted:", uid)
                }
            }
        }
    }

    // MARK: - Create challenge (paired user)

    func createChallenge(
        exerciseType: String,
        reps: Int,
        blockDurationSec: Int
    ) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            // Find my pair (assumes exactly one pair per user)
            self.db.collection("pairs")
                .whereField("members", arrayContains: myUid)
                .limit(to: 1)
                .getDocuments { [weak self] snapshot, error in
                    guard let self else { return }

                    if let error = error {
                        print("Fetch pair error:", error)
                        return
                    }

                    guard
                        let pairDoc = snapshot?.documents.first,
                        let members = pairDoc.data()["members"] as? [String],
                        let otherUid = members.first(where: { $0 != myUid })
                    else {
                        print("No valid pair found for uid:", myUid)
                        return
                    }

                    let challengeData: [String: Any] = [
                        "fromUser": myUid,
                        "toUser": otherUid,
                        "status": "pending",
                        "createdAt": FieldValue.serverTimestamp(),
                        "blockDuration": blockDurationSec,
                        "inChallenge": false,
                        "exercise": [
                            "type": exerciseType,
                            "reps": reps
                        ],
                        "proof": [
                            "uploaded": false,
                            "videoUrl": NSNull(),
                            "uploadedAt": NSNull()
                        ]
                    ]

                    self.db.collection("challenges").addDocument(data: challengeData) { error in
                        if let error = error {
                            print("Create challenge error:", error)
                        } else {
                            print("Challenge created for:", otherUid)
                        }
                    }
                }
            
        }
    }
    
    func createChallenge(
        toUser otherUid: String,
        exerciseType: String,
        reps: Int,
        blockDurationSec: Int,
        inChallenge: Bool
    ) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            let challengeData: [String: Any] = [
                "fromUser": myUid,
                "toUser": otherUid,
                "status": "pending",
                "createdAt": FieldValue.serverTimestamp(),
                "blockDuration": blockDurationSec,
                "inChallenge": inChallenge,
                "exercise": [
                    "type": exerciseType,
                    "reps": reps
                ],
                "proof": [
                    "uploaded": false,
                    "videoUrl": NSNull(),
                    "uploadedAt": NSNull()
                ]
            ]

            self.db.collection("challenges").addDocument(data: challengeData) { error in
                if let error = error {
                    print("Create challenge (direct) error:", error)
                } else {
                    print("Challenge created for:", otherUid)
                }
            }
        }
    }

    func createPair(withOtherUid otherUid: String, completion: @escaping (Result<String, Error>) -> Void) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            if otherUid == myUid {
                completion(.failure(NSError(domain: "Pairing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot pair with yourself."])))
                return
            }

            let membersSorted = [myUid, otherUid].sorted()
            let pairId = membersSorted.joined(separator: "_") // stable id

            let data: [String: Any] = [
                "members": membersSorted,
                "createdAt": FieldValue.serverTimestamp()
            ]

            self.db.collection("pairs").document(pairId).setData(data, merge: true) { error in
                if let error = error {
                    completion(.failure(error))
                } else {
                    completion(.success(pairId))
                }
            }
        }
    }

    /// Marks all pending challenges targeting the current user as completed, and updates streakDays/lastChallengeDate.
    func resolveChallengesTargetingMe(completion: (() -> Void)? = nil) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            let userRef = self.db.collection("users").document(myUid)

            self.db.collection("challenges")
                .whereField("toUser", isEqualTo: myUid)
                .whereField("status", isEqualTo: "pending")
                .getDocuments { [weak self] snapshot, error in
                    guard let self else { return }
                    if let error = error {
                        print("Resolve challenges error:", error)
                        completion?()
                        return
                    }

                    userRef.getDocument { [weak self] userSnap, userErr in
                        guard let self else { return }
                        if let userErr = userErr {
                            print("User fetch error:", userErr)
                            completion?()
                            return
                        }

                        let data = userSnap?.data() ?? [:]
                        let currentStreak = data["streakDays"] as? Int ?? 0
                        let lastTS = data["lastChallengeDate"] as? Timestamp
                        let lastDate = lastTS?.dateValue()

                        let cal = Calendar.current
                        let now = Date()
                        let yesterday = cal.date(byAdding: .day, value: -1, to: now)

                        let shouldIncrement: Bool = {
                            guard let lastDate, let yesterday else { return false }
                            return cal.isDate(lastDate, inSameDayAs: yesterday)
                        }()

                        let newStreak = shouldIncrement ? (currentStreak + 1) : 1

                        let batch = self.db.batch()

                        snapshot?.documents.forEach { doc in
                            batch.updateData(["status": "completed"], forDocument: doc.reference)
                        }

                        batch.setData([
                            "lastChallengeDate": FieldValue.serverTimestamp(),
                            "streakDays": newStreak
                        ], forDocument: userRef, merge: true)

                        batch.commit { err in
                            if let err = err { print("Batch commit error:", err) }
                            completion?()
                        }
                    }
                }
        }
    }
    
    /// Increments a hidden score field on a user's doc.
    /// If the field doesn't exist yet, Firestore treats it as 0 and sets it to 1.
    func incrementChallengeScore(for userUid: String) {
        guard !userUid.isEmpty else { return }

        let userRef = db.collection("users").document(userUid)

        userRef.setData([
            "challengeScore": FieldValue.increment(Int64(1))
        ], merge: true) { error in
            if let error = error {
                print("Increment challengeScore error:", error)
            } else {
                print("challengeScore incremented for:", userUid)
            }
        }
    }

    // MARK: - Listen for challenges targeting this user

    func startListeningForChallenges(onShouldBlock: @escaping (Bool) -> Void) {
        listener?.remove()

        ensureSignedIn { [weak self] uid in
            guard let self else { return }
            self.currentUserUid = uid

            self.listener = self.db.collection("challenges")
                .whereField("toUser", isEqualTo: uid)
                .whereField("status", isEqualTo: "pending")
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let self else { return }
                    if let error = error {
                        print("Challenge listen error:", error)
                        return
                    }

                    let docs = snapshot?.documents ?? []
                    let shouldBlock = !docs.isEmpty

                    var challenge: ActiveChallenge?
                    if let first = docs.first {
                        let docData = first.data()
                        let fromUser = docData["fromUser"] as? String ?? ""
                        let inChallenge = docData["inChallenge"] as? Bool ?? false

                        if let ex = docData["exercise"] as? [String: Any] {
                            let type = ex["type"] as? String ?? "pushups"
                            let reps = ex["reps"] as? Int ?? 3

                            challenge = ActiveChallenge(
                                id: first.documentID,
                                fromUser: fromUser,
                                exerciseType: type,
                                reps: reps,
                                inChallenge: inChallenge
                            )
                        }
                    }

                    Task { @MainActor in
                        self.shouldBlockThisDevice = shouldBlock
                        self.activeChallenge = challenge
                        onShouldBlock(shouldBlock)
                    }
                }
        }
    }

    // MARK: - Listen for my profile (streakDays)

    func startListeningForMyProfile() {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }
            self.currentUserUid = uid

            self.profileListener?.remove()
            self.profileListener = self.db.collection("users").document(uid)
                .addSnapshotListener { [weak self] snap, error in
                    guard let self else { return }
                    if let error = error {
                        print("Profile listen error:", error)
                        return
                    }

                    let data = snap?.data() ?? [:]
                    let streak = data["streakDays"] as? Int ?? 0
                    let username = data["username"] as? String

                    Task { @MainActor in
                        self.currentStreakDays = streak
                        self.currentUsername = username
                    }
                }
        }
    }
    
    func startListeningForFriends() {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            self.pairsListener?.remove()
            self.pairsListener = self.db.collection("pairs")
                .whereField("members", arrayContains: myUid)
                .addSnapshotListener { [weak self] snap, error in
                    guard let self else { return }
                    if let error = error {
                        print("Pairs listen error:", error)
                        return
                    }

                    let pairDocs = snap?.documents ?? []
                    let otherUids: [String] = pairDocs.compactMap { doc in
                        let members = doc.data()["members"] as? [String] ?? []
                        return members.first(where: { $0 != myUid })
                    }

                    // Remove listeners for users no longer paired
                    let currentSet = Set(self.friendProfileListeners.keys)
                    let nextSet = Set(otherUids)
                    let removed = currentSet.subtracting(nextSet)
                    for uid in removed {
                        self.friendProfileListeners[uid]?.remove()
                        self.friendProfileListeners.removeValue(forKey: uid)
                    }

                    // Start listeners for new friends
                    let added = nextSet.subtracting(currentSet)
                    for uid in added {
                        let listener = self.db.collection("users").document(uid)
                            .addSnapshotListener { [weak self] userSnap, userErr in
                                guard let self else { return }
                                if let userErr = userErr {
                                    print("Friend profile listen error:", userErr)
                                    return
                                }

                                let data = userSnap?.data() ?? [:]
                                let username = (data["username"] as? String) ?? "unknown"
                                let streak = (data["streakDays"] as? Int) ?? 0
                                let bigWins = (data["challengeScore"] as? Int) ?? 0

                                Task { @MainActor in
                                    // Upsert friend summary in array
                                    if let idx = self.friends.firstIndex(where: { $0.uid == uid }) {
                                        self.friends[idx].username = username
                                        self.friends[idx].streakDays = streak
                                        self.friends[idx].bigWins = bigWins
                                    } else {
                                        self.friends.append(FriendSummary(
                                            uid: uid,
                                            username: username,
                                            streakDays: streak,
                                            bigWins: bigWins
                                        ))
                                    }

                                    // Keep stable ordering
                                    self.friends.sort { $0.username.lowercased() < $1.username.lowercased() }
                                }
                            }

                        self.friendProfileListeners[uid] = listener
                    }

                    // Ensure placeholders exist quickly even before user docs arrive
                    Task { @MainActor in
                        for uid in otherUids {
                            if self.friends.contains(where: { $0.uid == uid }) == false {
                                self.friends.append(FriendSummary(uid: uid, username: "loading…", streakDays: 0, bigWins: 0))
                            }
                        }
                        self.friends = self.friends.filter { nextSet.contains($0.uid) }
                        self.friends.sort { $0.username.lowercased() < $1.username.lowercased() }
                    }
                }
        }
    }

    func uploadProofVideo(
        challengeId: String,
        fileUrl: URL
    ) {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }

            let path = "proof/\(challengeId)/\(uid).mp4"
            let storageRef = Storage.storage().reference(withPath: path)

            storageRef.putFile(from: fileUrl, metadata: nil) { _, error in
                if let error = error {
                    print("Storage upload error:", error)
                    return
                }

                storageRef.downloadURL { url, error in
                    if let error = error {
                        print("Download URL error:", error)
                        return
                    }
                    guard let url = url else { return }

                    self.db.collection("challenges").document(challengeId).setData([
                        "proof": [
                            "uploaded": true,
                            "videoPath": path,
                            "videoUrl": url.absoluteString,
                            "uploadedAt": FieldValue.serverTimestamp()
                        ]
                    ], merge: true) { error in
                        if let error = error {
                            print("Firestore proof update error:", error)
                        } else {
                            print("Proof video saved for challenge:", challengeId)
                        }
                    }
                }
            }
        }
    }

    // Optional: keep if you still use it elsewhere
    func getOrCreateStreak(completion: @escaping (Int) -> Void) {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }

            let userRef = self.db.collection("users").document(uid)

            userRef.getDocument { [weak self] snap, error in
                guard let self else { return }
                if let error = error {
                    print("Get streak error:", error)
                    completion(0)
                    return
                }

                if snap?.exists == false {
                    userRef.setData([
                        "createdAt": FieldValue.serverTimestamp(),
                        "streakDays": 0,
                        "lastChallengeDate": NSNull()
                    ], merge: true) { err in
                        if let err = err { print("Create user streak error:", err) }
                        completion(0)
                    }
                    return
                }

                let streak = snap?.data()?["streakDays"] as? Int ?? 0

                if snap?.data()?["streakDays"] == nil {
                    userRef.setData(["streakDays": 0], merge: true) { err in
                        if let err = err { print("Set missing streakDays error:", err) }
                        completion(0)
                    }
                } else {
                    completion(streak)
                }
            }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil

        profileListener?.remove()
        profileListener = nil

        shouldBlockThisDevice = false
        activeChallenge = nil
        
        pairsListener?.remove()
        pairsListener = nil

        friendProfileListeners.values.forEach { $0.remove() }
        friendProfileListeners.removeAll()

        friends = []
    }

    // MARK: - Auth helper

    private func ensureSignedIn(_ done: @escaping (String) -> Void) {
        if let uid = Auth.auth().currentUser?.uid {
            done(uid)
            return
        }

        Auth.auth().signInAnonymously { result, error in
            if let error = error {
                print("Auth error:", error)
                return
            }
            guard let uid = result?.user.uid else { return }
            done(uid)
        }
    }
}
