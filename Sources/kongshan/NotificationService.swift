import Foundation
import UserNotifications

protocol NotificationSending: Sendable {
    func send(title: String, body: String) async throws
}

enum NotificationServiceError: Error, LocalizedError {
    case permissionDenied
    case unavailableHost

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "本地通知权限未开启"
        case .unavailableHost: "当前运行环境无法发送本地通知"
        }
    }
}

final class NotificationService: NotificationSending, @unchecked Sendable {
    private let providedCenter: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        providedCenter = center
    }

    func send(title: String, body: String) async throws {
        guard providedCenter != nil || Bundle.main.bundleURL.pathExtension == "app" else {
            throw NotificationServiceError.unavailableHost
        }
        let center = providedCenter ?? .current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw NotificationServiceError.permissionDenied }
        case .denied:
            throw NotificationServiceError.permissionDenied
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "kongshan-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}
