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
    @Published private(set) var activeChallenge: (exerciseType: String, reps: Int)?
    /// Current user's UID (set when signed in). Share this with the other phone so they can send you a challenge.
    @Published private(set) var currentUserUid: String?

    // NEW: exposed for UI
    @Published var currentStreakDays: Int? = nil

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
        toUser: String,              // kept to avoid changing call sites (ignored)
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

                    var challenge: (exerciseType: String, reps: Int)?
                    if let first = docs.first, let data = first.data()["exercise"] as? [String: Any] {
                        let type = data["type"] as? String ?? "pushups"
                        let reps = data["reps"] as? Int ?? 3
                        challenge = (type, reps)
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

                    Task { @MainActor in
                        self.currentStreakDays = streak
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
