//
//  FirebaseLockService.swift
//  Testinging
//
//  Developer environment: both devices use the same Firestore "room" and listen
//  for lock commands. Friend A writes "lock B"; Friend B's app sees it and blocks
//  its own device (and vice versa).
//

import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

/// Role in the two-device pair. Each device picks one role and shares the same room ID.
enum DeviceRole: String, CaseIterable {
    case friendA = "Friend A"
    case friendB = "Friend B"
}

/// Firestore field names for the dev room document.
private enum RoomFields {
    static let lockDeviceA = "lockDeviceA"
    static let lockDeviceB = "lockDeviceB"
}

/// Manages lock/unlock commands in Firestore so one device can trigger blocking on the other.
@MainActor
final class FirebaseLockService: ObservableObject {
    private let db = Firestore.firestore()
    private let devRoomId = "dev-room"
    private var listener: ListenerRegistration?

    /// When the remote device sends "lock me", this becomes true so the UI can apply Family Controls.
    @Published private(set) var shouldBlockThisDevice = false

    /// Write a "lock" command for the other device. (Friend A locks B; Friend B locks A.)
    func sendLockToOther() {
        let field = role == .friendA ? RoomFields.lockDeviceB : RoomFields.lockDeviceA
        roomRef.setData([field: true], merge: true) { [weak self] error in
            if let error = error {
                print("Firebase sendLock error:", error)
            }
        }
    }
    
    func createUserDb(name: String) {
        Auth.auth().signInAnonymously { [weak self] result, error in
            if let error = error {
                print("Auth error:", error)
                return
            }
            guard let uid = result?.user.uid else { return }

            self?.db.collection("users").document(uid).setData([
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

    /// Clear the "lock" flag for this device so the other device can unblock us (or we unblock ourselves).
    func clearMyLock() {
        let field = role == .friendA ? RoomFields.lockDeviceA : RoomFields.lockDeviceB
        roomRef.setData([field: false], merge: true) { [weak self] error in
            if let error = error {
                print("Firebase clearLock error:", error)
            }
        }
    }

    /// Start listening for lock commands targeting this device. Call when role is set and app is active.
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

    func stopListening() {
        listener?.remove()
        listener = nil
        shouldBlockThisDevice = false
    }

    private var role: DeviceRole = .friendA
    private var name: String = ""
    private var roomRef: DocumentReference {
        db.collection("rooms").document(devRoomId)
    }
}
