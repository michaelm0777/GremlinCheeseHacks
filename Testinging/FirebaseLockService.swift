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
    private var listener: ListenerRegistration?

    @Published private(set) var shouldBlockThisDevice = false
    @Published private(set) var currentUserUid: String?

    // New: what the pending challenge wants blocked
    @Published private(set) var pendingChallengeId: String?
    @Published private(set) var pendingBlockAppKeys: [String] = []

    func createUserDb(name: String) {
        ensureSignedIn { [weak self] uid in
            guard let self else { return }
            self.currentUserUid = uid

            self.db.collection("users").document(uid).setData([
                "createdAt": FieldValue.serverTimestamp(),
                "username": name,
                "autoLockEnabled": true
            ], merge: true) { error in
                if let error = error {
                    print("Firestore createUser error:", error)
                }
            }
        }
    }

    // Updated: send app keys to block
    func createChallenge(
        toUser: String,
        exerciseType: String,
        reps: Int,
        blockDurationSec: Int,
        blockAppKeys: [String]
    ) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }
            self.currentUserUid = myUid

            let challengeData: [String: Any] = [
                "fromUser": myUid,
                "toUser": toUser,
                "status": "pending",
                "createdAt": FieldValue.serverTimestamp(),
                "blockDuration": blockDurationSec,
                "exercise": [
                    "type": exerciseType,
                    "reps": reps
                ],
                "block": [
                    "appKeys": blockAppKeys
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
                }
            }
        }
    }

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

    // Updated: store pending challenge info (id + appKeys)
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

                    if let doc = snapshot?.documents.first {
                        let data = doc.data()
                        let block = data["block"] as? [String: Any]
                        let appKeys = block?["appKeys"] as? [String] ?? []

                        Task { @MainActor in
                            self.pendingChallengeId = doc.documentID
                            self.pendingBlockAppKeys = appKeys
                            self.shouldBlockThisDevice = true
                            onShouldBlock(true)
                        }
                    } else {
                        Task { @MainActor in
                            self.pendingChallengeId = nil
                            self.pendingBlockAppKeys = []
                            self.shouldBlockThisDevice = false
                            onShouldBlock(false)
                        }
                    }
                }
        }
    }

    func uploadProofVideo(challengeId: String, fileUrl: URL) {
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
                    ], merge: true)
                }
            }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        shouldBlockThisDevice = false
        pendingChallengeId = nil
        pendingBlockAppKeys = []
    }

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
