import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import ManagedSettings
import FamilyControls

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let store = ManagedSettingsStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        application.registerForRemoteNotifications()
        return true
    }

    // Called for background (“silent”) pushes and for pushes with fetch semantics.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // (Optional) filter: only react to your challenge push type
        // guard userInfo["type"] as? String == "challenge" else { completionHandler(.noData); return }

        // Need a user id; if not signed in, nothing to do.
        guard let uid = Auth.auth().currentUser?.uid else {
            completionHandler(.noData)
            return
        }

        // Fetch whether I have pending challenges.
        Firestore.firestore().collection("challenges")
            .whereField("toUser", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .limit(to: 1)
            .getDocuments { [weak self] snap, err in
                guard let self else { completionHandler(.failed); return }
                if err != nil { completionHandler(.failed); return }

                let hasPending = (snap?.documents.isEmpty == false)
                let selection = SelectionStore.load()

                if hasPending {
                    self.store.shield.applications = selection.applicationTokens
                    self.store.shield.applicationCategories = .specific(selection.categoryTokens)
                    completionHandler(.newData)
                } else {
                    self.store.shield.applications = []
                    self.store.shield.applicationCategories = .none
                    completionHandler(.noData)
                }
            }
    }
}
