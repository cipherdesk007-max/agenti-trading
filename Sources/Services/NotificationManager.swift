import Foundation
import UserNotifications

/// Notifiche locali per gli eventi chiave del motore: ordine inviato,
/// esito di un trade, HARD KILL, promemoria di background. Nessun server
/// push: tutto generato sul dispositivo.
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

    /// Notifica programmata: iOS la consegna anche se l'app è sospesa.
    /// Usata per avvisare che il motore potrebbe essere in pausa in background.
    func schedule(
        identifier: String,
        title: String,
        body: String,
        after seconds: TimeInterval
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, seconds),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        // Sostituisce un eventuale promemoria pendente con lo stesso id.
        center.add(request) { _ in }
    }

    /// Promemoria giornaliero della modalità giornaliera: lun–ven alle 15:30
    /// di New York (le 21:30 in Italia, l'ora si adatta da sola ai cambi di ora
    /// legale), mezz'ora prima della chiusura: segnali, ingressi e uscite
    /// si fanno a mercato aperto.
    func scheduleDailyReminder(enabled: Bool) {
        let ids = (2...6).map { "quantswarm.daily.reminder.\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        for weekday in 2...6 {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(identifier: "America/New_York")
            components.weekday = weekday
            components.hour = 15
            components.minute = 30
            let content = UNMutableNotificationContent()
            content.title = "QUANTSWARM · CONTROLLO GIORNALIERO"
            content.body = "Mercato USA aperto ancora 30 minuti: apri l'app per segnali, ingressi e uscite."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            center.add(UNNotificationRequest(identifier: "quantswarm.daily.reminder.\(weekday)",
                                             content: content, trigger: trigger)) { _ in }
        }
    }

    /// Promemoria della modalità notte, lun–ven (ora di New York, si adatta
    /// da sola all'ora legale): alle 8:45 per mettere la vendita all'apertura
    /// (14:45 in Italia) e alle 15:15 per l'acquisto in chiusura (21:15).
    func scheduleNightReminders(enabled: Bool) {
        let ids = (2...6).flatMap { ["quantswarm.night.sell.\($0)", "quantswarm.night.buy.\($0)"] }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        let slots: [(id: String, hour: Int, minute: Int, title: String, body: String)] = [
            ("sell", 8, 45, "QUANTSWARM · NOTTE: VENDITA",
             "Apri l'app prima delle 15:28: mette in vendita all'apertura le posizioni della notte."),
            ("buy", 15, 15, "QUANTSWARM · NOTTE: ACQUISTO",
             "Apri l'app prima delle 21:50: mette l'acquisto in chiusura per stanotte.")
        ]
        for weekday in 2...6 {
            for slot in slots {
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = TimeZone(identifier: "America/New_York")
                components.weekday = weekday
                components.hour = slot.hour
                components.minute = slot.minute
                let content = UNMutableNotificationContent()
                content.title = slot.title
                content.body = slot.body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                center.add(UNNotificationRequest(identifier: "quantswarm.night.\(slot.id).\(weekday)",
                                                 content: content, trigger: trigger)) { _ in }
            }
        }
    }

    func cancelPending(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Mostra banner e suono anche quando l'app è in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
