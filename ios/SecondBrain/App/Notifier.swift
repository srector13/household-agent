import BackgroundTasks
import Foundation
import SecondBrainKit
import UserNotifications

/// Notifications without a push certificate: the app reads the brain's notification feed (the same
/// notifications web push sends) when it opens and on iOS background refresh, and posts them locally.
/// Focus timers are scheduled on the phone itself, so they always fire on time.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    static let refreshTask = "PolarReality.SecondBrain.refresh"
    private let lastKey = "notifications.lastId"
    /// Set by the app: what to do when a notification is tapped.
    var onOpen: (@MainActor (String) -> Void)?

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setUp() {
        center.delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            self.handle(task)
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func status() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func setBadge(_ n: Int) {
        center.setBadgeCount(n) { _ in }
    }

    // MARK: background refresh

    func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            await self.poll()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Fetches new notifications from the brain and shows them. The first run only remembers where the
    /// feed is, so installing the app doesn't replay old notifications.
    @discardableResult
    func poll() async -> Int {
        guard let cfg = Store.load() else { return 0 }
        let api = BrainAPI(config: cfg)
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastKey) as? Int
        guard let feed = try? await api.notifications(after: last ?? 0) else { return 0 }
        defaults.set(feed.lastId, forKey: lastKey)
        setBadge(feed.badge)
        guard last != nil else { return 0 }
        var shown = 0
        for n in feed.items where n.kind != "focus" && n.kind != "test" {  // focus timers fire locally
            let c = UNMutableNotificationContent()
            c.title = n.title ?? "Second Brain"
            c.body = n.body ?? ""
            c.sound = .default
            c.badge = NSNumber(value: feed.badge)
            c.userInfo = ["url": n.url ?? "/"]
            c.threadIdentifier = n.kind
            try? await center.add(UNNotificationRequest(identifier: "feed-\(n.id)", content: c, trigger: nil))
            shown += 1
        }
        return shown
    }

    // MARK: focus timer

    func scheduleFocus(itemId: String, title: String, minutes: Int, endsAt: Date) {
        cancelFocus()
        let c = UNMutableNotificationContent()
        c.title = "⏰ \(minutes) minutes — nice work"
        c.body = "“\(title)”. Done, or keep going?"
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["url": "/?focus=\(itemId)"]
        let secs = max(1, endsAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
        center.add(UNNotificationRequest(identifier: "focus", content: c, trigger: trigger))
    }

    func cancelFocus() {
        center.removePendingNotificationRequests(withIdentifiers: ["focus"])
    }

    func test() {
        let c = UNMutableNotificationContent()
        c.title = "Second Brain"
        c.body = "Notifications work. 🎉"
        c.sound = .default
        center.add(UNNotificationRequest(identifier: "test-\(UUID())", content: c,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
    }

    // MARK: delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = response.notification.request.content.userInfo["url"] as? String ?? "/"
        Task { @MainActor in self.onOpen?(url) }
        completionHandler()
    }
}
