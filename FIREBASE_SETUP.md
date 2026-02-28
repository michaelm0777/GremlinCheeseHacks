# Firebase setup (developer / two-device flow)

Both phones run this app and use the **same Firebase project** so one device can send "lock" and the other receives it and blocks its own apps via Family Controls.

## 1. Firebase project

1. Go to [Firebase Console](https://console.firebase.google.com/) and create a project (or use an existing one).
2. Add an **iOS app** with bundle ID: `MeunstersInc.Testinging` (or whatever your app’s bundle ID is).
3. Download **GoogleService-Info.plist** and add it to the **Testinging** target in Xcode (drag into the Testinging group and check “Copy items if needed”).
4. In the Firebase project, enable **Firestore Database** (Create database → Start in test mode for dev).

## 2. Run on two devices

- **Device A (Friend A):** Install the app, grant Family Controls, pick “Friend A”, pick apps to control.
- **Device B (Friend B):** Same app, same Firebase project, pick “Friend B”, pick apps to control.

Both use the same Firestore “room” (`rooms/dev-room`). No extra setup is required; the document is created on first write.

## 3. Flow

- Friend A taps **“Lock Friend B”** → Firestore `lockDeviceB = true` → Friend B’s app (listening) blocks its own device with the selected apps.
- Friend B taps **“Lock Friend A”** → Firestore `lockDeviceA = true` → Friend A’s app blocks its own device.
- **Unblock All Apps** on a device clears the shield on that device and sets its lock flag to `false` in Firestore so the state stays in sync.

Listening is active while the app is in the foreground. For background behavior you’d add something like push notifications + background fetch later.
