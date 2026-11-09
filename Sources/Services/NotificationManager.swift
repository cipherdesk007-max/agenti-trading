import Foundation
import UserNotifications

/// Notifiche locali per gli eventi chiave del motore: ordine inviato,
/// esito di un trade, HARD KILL. Nessun server push: tutto generato
/// sul dispositivo, così l'utente può lasciare l'app in background.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    /// Mostra banner e suono anche quando l'app è in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
