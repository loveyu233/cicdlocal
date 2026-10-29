import AppKit
import ApplicationKit
import Models
import Observation
import UserNotifications

/// 系统通知：只在等待确认和失败时发。点击通知打开对应的运行。
@Observable
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    func install() { UNUserNotificationCenter.current().delegate = self }

    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    func deliver(_ notice: RunNotice) async {
        if authorization == .notDetermined { await requestAuthorization() }
        let content = UNMutableNotificationContent()
        content.title = notice.kind == .waiting ? "等待确认替换" : "运行失败"
        content.subtitle = "\(notice.projectName) · \(notice.branch)"
        content.body = notice.message
        content.sound = .default
        content.threadIdentifier = "run-\(notice.runID.rawValue)"
        content.userInfo = ["run": notice.runID.rawValue]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["run"] as? Int64, id > 0 else { return }
        await MainActor.run { AppModel.shared.show(run: RunID(rawValue: id)) }
    }
}
