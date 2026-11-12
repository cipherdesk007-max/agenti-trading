
import XCTest

@testable import QuantSwarmAlphaZero



/// Paracadute del motore: ripresa automatica solo in paper (bug B2), formule

/// dei circuit breaker estratte e testate (bug B5), prefilter della veloce sul

/// contante libero vero (bug B6).

final class EngineGuardsTests: XCTestCase {



    // MARK: - Bug B2: mai ripresa automatica su conto LIVE



    func testAutoResumeOnlyInPaper() {

        XCTAssertTrue(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: false, isPaper: true))

        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: false, isPaper: false),

                       "un conto con soldi veri non riparte mai da solo dopo un riavvio")

        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: false, isRunning: false, isPaper: true),

                       "l'impostazione spenta resta spenta")

        XCTAssertFalse(QuantSwarmEngine.shouldAutoResume(enabled: true, isRunning: true, isPaper: true),

                       "mai due sessioni sovrapposte")

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

        // Tetto 10.000: il pavimento è picco − 1.000, non picco − 10.000.

        let check = RiskRules.drawdownCheck(equity: 120_000, peak: 140_000,

                                            maxDrawdownFraction: 0.10, capitalCap: 10_000)

        XCTAssertEqual(check?.floor ?? 0, 139_000, accuracy: 1e-6)

        XCTAssertEqual(check?.shouldLock, false, "il conto può anche dimezzare: il tetto protegge il capitale bot")

    }



    // MARK: - Bug B6: il prefilter guarda il contante libero, non il capitale



    func testCanBuyOneShareUsesFreeCashNotCapital() {

        // Capitale bot 100.000 ma tutto già investito (contante libero 1.000):

        // SPY a 760 non è comprabile e Kimi non va chiamato.

        XCTAssertFalse(RiskRules.canBuyOneShare(price: 760, stopDistance: 5,

                                                capital: 100_000, freeCash: 1_000, riskFraction: 0.01))

        // Stesso conto con contante libero: passa.

        XCTAssertTrue(RiskRules.canBuyOneShare(price: 760, stopDistance: 5,

                                               capital: 100_000, freeCash: 100_000, riskFraction: 0.01))

    }

}
