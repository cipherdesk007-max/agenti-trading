import XCTest

@testable import QuantSwarmAlphaZero

/// Paracadute del motore: ripresa automatica solo in paper (bug B2), formule
/// dei circuit breaker estratte e testate (bug B5), prefilter della veloce sul
/// contante libero vero (bug B6).
final class EngineGuardsTests: XCTestCase {

    // MARK: - Bug B2: mai ripresa automatica su conto LIVE

    @MainActor
    func testAutoResumeOnlyInPaper() {
        XCTAssertTrue(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: false, isPaper: true))
        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: false, isPaper: false),
                       "un conto con soldi veri non riparte mai da solo dopo un riavvio")
        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: false, isRunning: false, isPaper: true),
                       "l'impostazione spenta resta spenta")
        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: true, isPaper: true),
                       "mai due sessioni sovrapposte")
    }

    // MARK: - Doppio avvio parato (report 13/11 16:03: ripresa automatica + AVVIA)

    @MainActor
    func testStartRefusedWhileStartingOrRunning() {
        XCTAssertTrue(QuantSwarmEngine.startAllowed(isRunning: false, startingSession: false),
                     "col motore fermo il via è libero")
        XCTAssertFalse(QuantSwarmEngine.startAllowed(isRunning: true, startingSession: false),
                       "sessione attiva: mai due cicli")
        XCTAssertFalse(QuantSwarmEngine.startAllowed(isRunning: false, startingSession: true),
                       "avvio in corso (isRunning non ancora salito): il via va negato lo stesso")
    }

    // MARK: - Conto Alpaca con trading sospeso (40310000)

    func testAccountFrozenDetection() {
        let frozen = QuantSwarmError.httpStatus(
            403, "{\"code\":40310000,\"message\":\"new orders are rejected by user request\"}"
        )
        XCTAssertTrue(QuantSwarmError.isAccountFrozen(frozen),
                      "il 40310000 è il flag del conto, non un errore qualsiasi")
        struct Other403: LocalizedError {
            var errorDescription: String? { "Errore HTTP 403: qualcos'altro" }
        }
        XCTAssertFalse(QuantSwarmError.isAccountFrozen(Other403()))
        XCTAssertFalse(QuantSwarmError.isAccountFrozen(URLError(.timedOut)))
    }

    // MARK: - Rientro in foreground al lancio: mai un secondo ciclo (Face ID)

    @MainActor
    func testForegroundRecheckSkippedDuringFirstMinuteOfSession() {
        XCTAssertFalse(QuantSwarmEngine.shouldRecheckOnForeground(sessionAge: 25),
                       "all'avvio la scena fa inactive → active (sblocco Face ID): quel rientro non deve far ripartire il ciclo appena concluso (doppio ciclo, report 13/11 ore 19:44)")
        XCTAssertFalse(QuantSwarmEngine.shouldRecheckOnForeground(sessionAge: 0),
                       "sessione appena partita: il primo ciclo è già in corsa")
        XCTAssertFalse(QuantSwarmEngine.shouldRecheckOnForeground(sessionAge: nil),
                       "senza sessione in corso niente controllo")
        XCTAssertTrue(QuantSwarmEngine.shouldRecheckOnForeground(sessionAge: 61),
                     "riaprire l'app a sessione avviata deve far ripartire subito il controllo")
    }

    // MARK: - Bug B5: circuit breaker, formule pure

    func testDailyStopTriggersOnLoss() {
        let check = RiskRules.dailyStopCheck(equity: 97_900, lastEquity: 100_000,
                                             stopFraction: 0.02, capitalCap: .infinity)
        XCTAssertEqual(check?.dayPnL ?? 0, -2_100, accuracy: 1e-6)
        XCTAssertEqual(check?.limit ?? 0, 2_000, accuracy: 1e-6)
        XCTAssertEqual(check?.shouldStop, true)
    }

    func testDailyStopMeasuredOnBotCapital() {
        // Conto 100.000, capitale bot 10.000, stop 2%: il limite è 200 USD, non 2.000.
        let check = RiskRules.dailyStopCheck(equity: 99_700, lastEquity: 100_000,
                                             stopFraction: 0.02, capitalCap: 10_000)
        XCTAssertEqual(check?.limit ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(check?.shouldStop, true, "−300 USD oltre il limite di 200")
        let ok = RiskRules.dailyStopCheck(equity: 99_900, lastEquity: 100_000,
                                          stopFraction: 0.02, capitalCap: 10_000)
        XCTAssertEqual(ok?.shouldStop, false)
    }

    func testDailyStopCountsWithdrawalAsLoss() {
        // Documenta il limite noto (bug B5): un prelievo di 5.000 USD appare
        // come P&L −5.000 e fa scattare lo stop anche senza perdite di trading.
        // Con le API disponibili non è distinguibile: chi preleva deve sapere
        // che il bot può fermarsi per un giorno.
        let check = RiskRules.dailyStopCheck(equity: 95_000, lastEquity: 100_000,
                                             stopFraction: 0.02, capitalCap: .infinity)
        XCTAssertEqual(check?.shouldStop, true)
    }

    func testDrawdownLocksBelowFloor() {
        let check = RiskRules.drawdownCheck(equity: 89_000, peak: 100_000,
                                            maxDrawdownFraction: 0.10, capitalCap: .infinity)
        XCTAssertEqual(check?.floor ?? 0, 90_000, accuracy: 1e-6)
        XCTAssertEqual(check?.shouldLock, true)
        let ok = RiskRules.drawdownCheck(equity: 90_500, peak: 100_000,
                                         maxDrawdownFraction: 0.10, capitalCap: .infinity)
        XCTAssertEqual(ok?.shouldLock, false)
    }

    func testDrawdownFloorMeasuredOnBotCapital() {
        // Tetto 10.000: tolleranza = 10% del capitale bot = 1.000, quindi il
        // pavimento è 139.000 (picco − 1.000), non picco − 10.000.
        let check = RiskRules.drawdownCheck(equity: 139_500, peak: 140_000,
                                            maxDrawdownFraction: 0.10, capitalCap: 10_000)
        XCTAssertEqual(check?.floor ?? 0, 139_000, accuracy: 1e-6)
        XCTAssertEqual(check?.shouldLock, false, "sopra il pavimento di 139.000 il bot continua")
        let locked = RiskRules.drawdownCheck(equity: 138_500, peak: 140_000,
                                             maxDrawdownFraction: 0.10, capitalCap: 10_000)
        XCTAssertEqual(locked?.shouldLock, true, "sotto il pavimento il bot si blocca")
    }

    // MARK: - Bug B6: il prefilter guarda il contante libero, non il capitale

    func testCanBuyOneShareUsesFreeCashNotCapital() {
        // Capitale bot 100.000 ma quasi tutto già investito (contante libero 500):
        // SPY a 760 (limite 760,38) non è comprabile e Kimi non va chiamato,
        // anche se il capitale sarebbe più che sufficiente.
        XCTAssertFalse(RiskRules.canBuyOneShare(price: 760, stopDistance: 5,
                                                capital: 100_000, freeCash: 500, riskFraction: 0.01))
        // Stesso conto con contante libero: passa.
        XCTAssertTrue(RiskRules.canBuyOneShare(price: 760, stopDistance: 5,
                                               capital: 100_000, freeCash: 100_000, riskFraction: 0.01))
    }
}
