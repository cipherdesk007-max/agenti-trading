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

    /// yyyy-MM-dd in fuso America/New_York (stesso formato del calendario Alpaca).
    private static func dayStampET(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Rimuove i promemoria di un tipo: sia i vecchi id settimanali (lun–ven)
    /// sia quelli per data (oggi ± 60 giorni).
    private func cancelScheduledReminders(prefix: String) {
        var ids = (2...6).map { "\(prefix).\($0)" }
        let cal = Calendar(identifier: .gregorian)
        for offset in -60...60 {
            guard let d = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            ids.append("\(prefix).\(Self.dayStampET(d))")
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Promemoria su date di borsa esatte (dal calendario Alpaca): non ripetitivi,
    /// uno per giorno di borsa. Così niente promemoria nei festivi.
    private func scheduleDatedReminders(prefix: String, days: [String],
                                        hour: Int, minute: Int, title: String, body: String) {
        for day in days {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(identifier: "America/New_York")
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
            components.hour = hour
            components.minute = minute
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(prefix).\(day)",
                                             content: content, trigger: trigger)) { _ in }
        }
    }

    /// Promemoria giornaliero della modalità giornaliera: alle 15:30 di New York
    /// (le 21:30 in Italia) nei giorni di borsa, mezz'ora prima della chiusura.
    /// `tradingDays` = date yyyy-MM-dd dal calendario Alpaca; se nil (calendario
    /// non disponibile) ripiega sulla ripetizione settimanale lun–ven come prima.
    func scheduleDailyReminder(enabled: Bool, tradingDays: [String]? = nil) {
        let prefix = "quantswarm.daily.reminder"
        cancelScheduledReminders(prefix: prefix)
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        if let days = tradingDays, !days.isEmpty {
            scheduleDatedReminders(prefix: prefix, days: days, hour: 15, minute: 30,
                                   title: "QUANTSWARM · CONTROLLO GIORNALIERO",
                                   body: "Mercato USA aperto ancora 30 minuti: apri l'app per segnali, ingressi e uscite.")
            return
        }
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
            center.add(UNNotificationRequest(identifier: "\(prefix).\(weekday)",
                                             content: content, trigger: trigger)) { _ in }
        }
    }

    /// Promemoria della modalità notte nei giorni di borsa (ora di New York):
    /// alle 8:45 per la vendita all'apertura (14:45 in Italia) e alle 15:15 per
    /// l'acquisto in chiusura (21:15). `tradingDays` come sopra; nil = ripiego
    /// settimanale lun–ven come prima.
    func scheduleNightReminders(enabled: Bool, tradingDays: [String]? = nil) {
        let prefixes = ["quantswarm.night.sell", "quantswarm.night.buy"]
        for prefix in prefixes { cancelScheduledReminders(prefix: prefix) }
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        let slots: [(prefix: String, hour: Int, minute: Int, title: String, body: String)] = [
            ("quantswarm.night.sell", 8, 45, "QUANTSWARM · NOTTE: VENDITA",
             "Apri l'app prima delle 15:28: mette in vendita all'apertura le posizioni della notte."),
            ("quantswarm.night.buy", 15, 15, "QUANTSWARM · NOTTE: ACQUISTO",
             "Apri l'app prima delle 21:50: mette l'acquisto in chiusura per stanotte.")
        ]
        if let days = tradingDays, !days.isEmpty {
            for slot in slots {
                scheduleDatedReminders(prefix: slot.prefix, days: days, hour: slot.hour, minute: slot.minute,
                                       title: slot.title, body: slot.body)
            }
            return
        }
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
                center.add(UNNotificationRequest(identifier: "\(slot.prefix).\(weekday)",
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
