import BackgroundTasks
import UIKit
import UserNotifications

/// Hosts the pieces that need to exist at launch: the background inbox
/// refresh task and notification handling.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.personal.instanoreels.inboxcheck"

    /// Where a tapped notification asks the web view to go.
    let deepLinks = DeepLinkRouter()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleInboxRefresh(refresh)
        }

        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        return true
    }

    /// Ask iOS for the next background check. iOS treats the interval as
    /// "no sooner than", and decides the actual time based on usage.
    static func scheduleInboxRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AppConfig.inboxBackgroundInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleInboxRefresh(_ task: BGAppRefreshTask) {
        Self.scheduleInboxRefresh()

        let work = Task {
            await InboxChecker.shared.check(accountID: AccountStore.persistedCurrentID)
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// A tapped DM notification opens that thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let threadID = response.notification.request.content.userInfo["threadID"] as? String,
              let url = URL(string: "https://www.instagram.com/direct/t/\(threadID)/")
        else { return }
        await MainActor.run {
            deepLinks.pendingURL = url
        }
    }
}
