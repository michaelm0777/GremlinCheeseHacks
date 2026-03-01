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
        exerciseType: String,
        reps: Int,
        blockDurationSec: Int
    ) {
        ensureSignedIn { [weak self] myUid in
            guard let self else { return }

            let challengeData: [String: Any] = [
                "fromUser": myUid,
                "toUser": "Y4rd9Hm6w6hU7ndmpYyAUtxYycx2",
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
                    print("Challenge created for:", "Y4rd9Hm6w6hU7ndmpYyAUtxYycx2")
                }
            }
        }
    }

    // MARK: - Listen for challenges targeting this user

    func startListeningForChallenges(onShouldBlock: @escaping (Bool) -> Void) {
        listener?.remove()

        ensureSignedIn { [weak self] uid in
            guard let self else { return }

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
