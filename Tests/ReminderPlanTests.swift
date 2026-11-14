import XCTest
@testable import QuantSwarmAlphaZero

/// Promemoria: quali partono per modalità e a che ora nelle sedute corte.
final class ReminderPlanTests: XCTestCase {
    private func newYork(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/New_York")
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }

    /// PORTAFOGLIO è la modalità predefinita (giornaliera e notte migrano lì):
    /// deve ricevere i due promemoria della notte. Prima non ne partiva nessuno.
    func testPortfolioModeGetsTheNightReminders() {
        let kinds = ReminderPlan.kinds(mode: .portfolio, enabled: true)
        XCTAssertTrue(kinds.night)
        XCTAssertFalse(kinds.daily, "il promemoria d'acquisto copre già il controllo giornaliero")
    }

    func testSwitchOffOrAppOnlyModesGetNoReminder() {
        for mode in [TradingMode.portfolio, .daily, .night, .crypto, .intraday] {
            let off = ReminderPlan.kinds(mode: mode, enabled: false)
            XCTAssertFalse(off.daily || off.night, "interruttore spento: nessun promemoria in \(mode)")
        }
        for mode in [TradingMode.crypto, .intraday] {
            let kinds = ReminderPlan.kinds(mode: mode, enabled: true)
            XCTAssertFalse(kinds.daily || kinds.night, "\(mode) gira solo ad app aperta")
        }
    }

    func testNormalSessionKeepsTheUsualTimes() {
        let close = newYork(2026, 11, 16, 16, 0)
        let buy = ReminderPlan.time(close: close, leadMinutes: ReminderPlan.nightBuyLeadMinutes,
                                    fallbackHour: 15, fallbackMinute: 15)
        XCTAssertEqual(buy.hour, 15)
        XCTAssertEqual(buy.minute, 15)
        let daily = ReminderPlan.time(close: close, leadMinutes: ReminderPlan.dailyLeadMinutes,
                                      fallbackHour: 15, fallbackMinute: 30)
        XCTAssertEqual(daily.hour, 15)
        XCTAssertEqual(daily.minute, 30)
    }

    /// Seduta corta (venerdì dopo il Ringraziamento, chiusura alle 13:00):
    /// il promemoria delle 15:15 arriverebbe a mercato già chiuso.
    func testEarlyCloseMovesTheReminderBeforeTheRealClose() {
        let close = newYork(2026, 11, 27, 13, 0)
        let buy = ReminderPlan.time(close: close, leadMinutes: ReminderPlan.nightBuyLeadMinutes,
                                    fallbackHour: 15, fallbackMinute: 15)
        XCTAssertEqual(buy.hour, 12)
        XCTAssertEqual(buy.minute, 15)
    }

    func testWithoutCalendarTheFallbackTimeStays() {
        let time = ReminderPlan.time(close: nil, leadMinutes: 45, fallbackHour: 15, fallbackMinute: 15)
        XCTAssertEqual(time.hour, 15)
        XCTAssertEqual(time.minute, 15)
    }
}
