# Gremlin (Testinging)

An iOS app that lets you challenge friends: send them a lock that blocks selected apps on their device until they complete a short exercise (pushups or jumping jacks), counted in real time using the camera and on-device pose detection.

## What it does

- **Onboarding** — Enter your name; a Firebase user is created and your profile is stored in Firestore.
- **Home** — See your streak, today’s date, and shortcuts to create challenges, manage friends, and unblock (if you’re currently locked).
- **Friends** — Add friends via QR code or by sharing your UID; view their streaks and “big wins.”
- **Challenges** — Create a challenge (pushups or jumping jacks, with a rep count). The recipient’s device is “locked” (selected apps blocked via Family Controls) until they complete the exercise in front of the camera.
- **Unblock gate** — When locked, the user opens the app and is shown a full-screen gate: they must complete the required reps (counted by the camera) to unblock.

## How it works (high level)

1. **Firebase** — Firestore holds users, friendships (pairs), and challenges. When you send a challenge, a document is written that the other device is listening to. When they complete the exercise, the app clears the lock and updates Firestore.
2. **Family Controls** — The app uses the Family Controls / Managed Settings APIs to block selected apps on the same device. “Lock” means the app turns on that shield until the user completes the gate.
3. **Camera + Vision** — `CameraPushupManager` uses the camera and Vision’s body pose model to detect pushup “down”/“up” and jumping jack phases and counts reps. `PushupGateView` shows the camera feed with a pose overlay and runs this flow for “do N reps to unblock.”

## Requirements

- **Xcode** (current version; project uses SwiftPM for Firebase).
- **iOS device** — Family Controls and camera require a real device (not Simulator).
- **Apple Developer account** — The app uses the [Family Controls](https://developer.apple.com/documentation/familycontrols) capability; you need an account that can enable this entitlement.
- **Firebase project** — Firestore (and optionally Auth) must be set up and `GoogleService-Info.plist` added to the app. See [FIREBASE_SETUP.md](FIREBASE_SETUP.md).

## How to run

1. **Clone and open in Xcode**
   ```bash
   git clone <your-repo-url>
   cd Testinging
   open Testinging.xcodeproj
   ```

2. **Add Firebase config**
   - In the [Firebase Console](https://console.firebase.google.com/), create or use a project and add an iOS app with your app’s bundle ID (e.g. `MeunstersInc.Testinging`).
   - Download **GoogleService-Info.plist** and add it to the **Testinging** target (drag into the Testinging group in Xcode and check “Copy items if needed”).
   - See [FIREBASE_SETUP.md](FIREBASE_SETUP.md) for Firestore and two-device flow details.

3. **Signing and capabilities**
   - In Xcode, select the **Testinging** target → **Signing & Capabilities**.
   - Choose your Team and ensure the app signs correctly.
   - The **Family Controls** capability must be enabled (it’s in `Testinging.entitlements`).

4. **Run on a device**
   - Pick a physical iPhone as the run destination (Family Controls and camera don’t work in Simulator).
   - Build and run (⌘R). On first launch, grant **Screen Time / Family Controls** and **Camera** when prompted.

5. **Two-device flow (optional)**
   - Install the same build (same Firebase project) on two devices. Complete onboarding on each, then add each other as friends and send a challenge from one device to the other to test the lock/unblock flow. Details: [FIREBASE_SETUP.md](FIREBASE_SETUP.md).

## Project structure (main pieces)

| Path | Purpose |
|------|--------|
| `TestingingApp.swift` | App entry; configures Firebase and SwiftData `ModelContainer`; root view is `FamilyControlsTestView`. |
| `FamilyControlsTestView.swift` | Main UI: onboarding, home, friends, create challenge, sheets, and the pushup/unblock gate. |
| `FirebaseLockService.swift` | Firebase (Auth, Firestore, Storage): user creation, challenges, lock state, friends list, streaks. |
| `CameraPushupManager.swift` | Camera capture + Vision body pose; counts pushups and jumping jacks. |
| `PushupGateView.swift` | Full-screen “do N reps to continue” gate using `CameraPushupManager` and overlay. |
| `CameraPreviewView.swift` | Renders the camera preview layer. |
| `PoseOverlayView.swift` | Overlays pose/keypoints and phase (e.g. “Up”/“Down”) on the camera feed. |
| `Testinging.entitlements` | Enables Family Controls. |

## Dependencies

- **Firebase iOS SDK** (Swift Package Manager): Auth, Firestore, Storage. Resolved in `Package.resolved`.

## See also

- [FIREBASE_SETUP.md](FIREBASE_SETUP.md) — Firebase project, Firestore, and two-device lock flow.
- [GITHUB_SETUP.md](GITHUB_SETUP.md) — Adding the repo to GitHub and optional steps to avoid committing `GoogleService-Info.plist`.
