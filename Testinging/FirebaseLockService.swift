//
//  FirebaseLockService.swift
//  Testinging
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class FirebaseLockService: ObservableObject {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    @Published private(set) var shouldBlockThisDevice = false
    /// Current user's UID (set when signed in). Share this with the other phone so they can send you a challenge.
    @Published private(set) var currentUserUid: String?

    // MARK: - Create user (users/{uid})

    func createUserDb(name: String) {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }
            self.db.collection("users").document(uid).setData([
                "createdAt": FieldValue.serverTimestamp(),
                "username": name,
                "autoLockEnabled": true
            ], merge: true) { error in
                if let error = error {
                    print("Firestore createUser error:", error)
                } else {
                    print("User doc upserted:", uid)
                }
            }
        }
    }

    // MARK: - Create challenge (manual toUser uid)

    func createChallenge(
        toUser: String,              // kept to avoid changing call sites (will be ignored)
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

    /// Marks all pending challenges targeting the current user as completed so the listener sees no pending and unblock is effective.
    func resolveChallengesTargetingMe(completion: (() -> Void)? = nil) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }
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
                    let batch = self.db.batch()
                    snapshot?.documents.forEach { doc in
                        batch.updateData(["status": "completed"], forDocument: doc.reference)
                    }
                    batch.commit { err in
                        if let err = err { print("Batch commit error:", err) }
                        completion?()
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

                    let shouldBlock = (snapshot?.documents.isEmpty == false)

                    Task { @MainActor in
                        self.shouldBlockThisDevice = shouldBlock
                        onShouldBlock(shouldBlock)
                    }
                }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        shouldBlockThisDevice = false
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
