//
//  FirebaseLockService.swift
//  Testinging
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

enum DeviceRole: String, CaseIterable {
    case friendA = "Friend A"
    case friendB = "Friend B"
}

private enum RoomFields {
    static let lockDeviceA = "lockDeviceA"
    static let lockDeviceB = "lockDeviceB"
}

@MainActor
final class FirebaseLockService: ObservableObject {
    private let db = Firestore.firestore()
    private let devRoomId = "dev-room"
    private var listener: ListenerRegistration?

    @Published private(set) var shouldBlockThisDevice = false

    // MARK: - Existing dev-room testing flow

    func sendLockToOther() {
        let field = role == .friendA ? RoomFields.lockDeviceB : RoomFields.lockDeviceA
        roomRef.setData([field: true], merge: true) { error in
            if let error = error {
                print("Firebase sendLock error:", error)
            }
        }
    }

    func clearMyLock() {
        let field = role == .friendA ? RoomFields.lockDeviceA : RoomFields.lockDeviceB
        roomRef.setData([field: false], merge: true) { error in
            if let error = error {
                print("Firebase clearLock error:", error)
            }
        }
    }

    func startListening(role: DeviceRole, onShouldBlock: @escaping (Bool) -> Void) {
        self.role = role
        listener?.remove()

        let field = role == .friendA ? RoomFields.lockDeviceA : RoomFields.lockDeviceB
        listener = roomRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error = error {
                print("Firebase listen error:", error)
                return
            }

            let value = snapshot?.data()?[field] as? Bool ?? false
            Task { @MainActor in
                self.shouldBlockThisDevice = value
                onShouldBlock(value)
            }
        }
    }

    // MARK: - User creation (Auth UID doc id)

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
                }
            }
        }
    }

    // MARK: - New: listen for challenges targeting this user

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

    // MARK: - Stop

    func stopListening() {
        listener?.remove()
        listener = nil
        shouldBlockThisDevice = false
    }

    // MARK: - Private helpers

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

    private var role: DeviceRole = .friendA
    private var roomRef: DocumentReference {
        db.collection("rooms").document(devRoomId)
    }
}
