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
    /// uno per giorno di borsa. Così niente promemoria nei festivi. Con
    /// `leadMinutes` l'orario si calcola dalla chiusura di QUEL giorno
    /// (`closes`): nelle sedute corte (chiusura alle 13:00 di New York) il
    /// promemoria arriva prima della chiusura vera, non due ore dopo.
    private func scheduleDatedReminders(prefix: String, days: [String],
                                        hour: Int, minute: Int, title: String, body: String,
                                        closes: [String: Date] = [:], leadMinutes: Int? = nil) {
        for day in days {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var time = (hour: hour, minute: minute)
            if let leadMinutes {
                time = ReminderPlan.time(close: closes[day], leadMinutes: leadMinutes,
                                         fallbackHour: hour, fallbackMinute: minute)
            }
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(identifier: "America/New_York")
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
            components.hour = time.hour
            components.minute = time.minute
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
    func scheduleDailyReminder(enabled: Bool, tradingDays: [String]? = nil, closes: [String: Date] = [:]) {
        let prefix = "quantswarm.daily.reminder"
        cancelScheduledReminders(prefix: prefix)
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        if let days = tradingDays, !days.isEmpty {
            scheduleDatedReminders(prefix: prefix, days: days, hour: 15, minute: 30,
                                   title: "QUANTSWARM · CONTROLLO GIORNALIERO",
                                   body: "Mercato USA aperto ancora 30 minuti: apri l'app per segnali, ingressi e uscite.",
                                   closes: closes, leadMinutes: ReminderPlan.dailyLeadMinutes)
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
    func scheduleNightReminders(enabled: Bool, tradingDays: [String]? = nil, closes: [String: Date] = [:]) {
        let prefixes = ["quantswarm.night.sell", "quantswarm.night.buy"]
        for prefix in prefixes { cancelScheduledReminders(prefix: prefix) }
        guard enabled else { return }
        requestAuthorizationIfNeeded()
        let slots: [(prefix: String, hour: Int, minute: Int, title: String, body: String)] = [
            ("quantswarm.night.sell", 8, 45, "QUANTSWARM · NOTTE: VENDITA",
             "Apri l'app entro 40 minuti (prima delle 9:28 di New York): mette in vendita all'apertura le posizioni della notte."),
            ("quantswarm.night.buy", 15, 15, "QUANTSWARM · NOTTE: ACQUISTO",
             "Apri l'app entro 30 minuti: mette l'acquisto in chiusura per stanotte e fa il controllo giornaliero.")
        ]
        if let days = tradingDays, !days.isEmpty {
            for slot in slots {
                // Solo l'acquisto dipende dalla chiusura (sedute corte); la
                // vendita è legata all'apertura, sempre alle 9:30.
                let lead: Int? = slot.prefix == "quantswarm.night.buy" ? ReminderPlan.nightBuyLeadMinutes : nil
                scheduleDatedReminders(prefix: slot.prefix, days: days, hour: slot.hour, minute: slot.minute,
                                       title: slot.title, body: slot.body,
                                       closes: closes, leadMinutes: lead)
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

/// Quali promemoria servono e a che ora (logica pura, sotto test).
enum ReminderPlan {
    /// Il controllo giornaliero si ricorda 30 minuti prima della chiusura.
    static let dailyLeadMinutes = 30
    /// L'acquisto della notte 45 minuti prima: la finestra d'ordine si chiude
    /// 10 minuti prima della chiusura del mercato.
    static let nightBuyLeadMinutes = 45

    /// Promemoria attivi per modalità. PORTAFOGLIO (giornaliera + notte sullo
    /// stesso conto) usa i due della notte: vendita prima dell'apertura e
    /// acquisto prima della chiusura, e il secondo copre anche il controllo
    /// giornaliero. Crypto e veloce girano solo ad app aperta: nessuno.
    static func kinds(mode: TradingMode, enabled: Bool) -> (daily: Bool, night: Bool) {
        guard enabled else { return (false, false) }
        switch mode {
        case .daily: return (true, false)
        case .night, .portfolio: return (false, true)
        case .intraday, .crypto: return (false, false)
        }
    }

    /// Ora di New York del promemoria: `leadMinutes` prima della chiusura di
    /// quel giorno. Senza la chiusura (calendario non disponibile) resta
    /// l'orario normale.
    static func time(close: Date?, leadMinutes: Int,
                     fallbackHour: Int, fallbackMinute: Int) -> (hour: Int, minute: Int) {
        guard let close, let zone = TimeZone(identifier: "America/New_York") else {
            return (fallbackHour, fallbackMinute)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let moment = close.addingTimeInterval(-Double(leadMinutes) * 60)
        let parts = calendar.dateComponents([.hour, .minute], from: moment)
        guard let hour = parts.hour, let minute = parts.minute else {
            return (fallbackHour, fallbackMinute)
        }
        return (hour, minute)
    }
}
