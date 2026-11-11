import XCTest
@testable import QuantSwarmAlphaZero

/// Test delle regole di rischio: girano a ogni build su GitHub Actions.
/// Se uno fallisce, l'IPA non viene pubblicata.
final class RiskRulesTests: XCTestCase {
    private let atr = 1.0
    private let stock = InstrumentConstraints.alpacaStock
    private let account = RiskRules.Account(equity: 100_000, cash: 100_000, buyingPower: 400_000)

    private func buy(entry: Double = 100, stop: Double = 98, target: Double = 104) -> RiskRules.Proposal {
        RiskRules.Proposal(action: .buy, entry: entry, stopLoss: stop, takeProfit: target)
    }

    private func sizing(
        _ p: RiskRules.Proposal,
        price: Double = 100,
        account: RiskRules.Account? = nil,
        risk: Double = 0.01
    ) -> Result<RiskRules.Sizing, RiskRejection> {
        RiskRules.size(
            p,
            currentPrice: price,
            atr: atr,
            account: account ?? self.account,
            riskFraction: risk,
            constraints: stock
        )
    }

    // MARK: - Precheck

    func testValidBuyPasses() {
        XCTAssertNil(RiskRules.precheck(buy(), lastPrice: 100, atr: atr))
    }

    func testShortSellingIsRejected() {
        let short = RiskRules.Proposal(action: .sell, entry: 100, stopLoss: 102, takeProfit: 96)
        XCTAssertNotNil(RiskRules.precheck(short, lastPrice: 100, atr: atr))
        if case .success = sizing(short) { XCTFail("Uno short non deve mai essere dimensionato") }
    }

    func testHoldIsNeverExecuted() {
        let hold = RiskRules.Proposal(action: .hold, entry: 100, stopLoss: 98, takeProfit: 104)
        XCTAssertNotNil(RiskRules.precheck(hold, lastPrice: 100, atr: atr))
    }

    func testStopAboveEntryIsRejected() {
        XCTAssertNotNil(RiskRules.precheck(buy(stop: 101), lastPrice: 100, atr: atr))
    }

    func testTargetBelowEntryIsRejected() {
        XCTAssertNotNil(RiskRules.precheck(buy(target: 99), lastPrice: 100, atr: atr))
    }

    func testStopTooTightIsRejected() {
        // 0,2 ATR: sotto il minimo di 0,5 ATR
        XCTAssertNotNil(RiskRules.precheck(buy(stop: 99.8, target: 101), lastPrice: 100, atr: atr))
    }

    func testStopTooWideIsRejected() {
        // 6 ATR: oltre il massimo di 5 ATR
        XCTAssertNotNil(RiskRules.precheck(buy(stop: 94, target: 120), lastPrice: 100, atr: atr))
    }

    func testLowRiskRewardIsRejected() {
        // R/R 1,0
        XCTAssertNotNil(RiskRules.precheck(buy(stop: 98, target: 102), lastPrice: 100, atr: atr))
    }

    func testEntryFarFromSeenPriceIsRejected() {
        // ingresso a 3 ATR dal prezzo visto
        XCTAssertNotNil(RiskRules.precheck(buy(), lastPrice: 103, atr: atr))
    }

    func testInvalidNumbersAreRejected() {
        XCTAssertNotNil(RiskRules.precheck(buy(entry: .nan), lastPrice: 100, atr: atr))
        XCTAssertNotNil(RiskRules.precheck(buy(), lastPrice: 100, atr: 0))
    }

    // MARK: - Sizing

    func testRiskNeverExceedsBudgetAtRealEntryPrice() throws {
        let result = try sizing(buy()).get()
        // rischio calcolato sul limite reale (prezzo + 0,05%), non sull'entry di Kimi
        XCTAssertEqual(result.riskPerUnit, result.limitPrice - result.stopPrice, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(result.riskAmount, 1_000 + 1e-6)
        XCTAssertGreaterThan(result.limitPrice, 100)
    }

    func testQuantityIsWholeSharesRoundedDown() throws {
        let result = try sizing(buy()).get()
        XCTAssertEqual(result.quantity, result.quantity.rounded(.down))
        XCTAssertGreaterThanOrEqual(result.quantity, 1)
    }

    func testPositionCappedAt25PercentOfEquity() throws {
        // stop 0,5 ATR: per rischio servirebbero ~1.900 azioni (190k USD)
        let result = try sizing(buy(stop: 99.5, target: 101)).get()
        XCTAssertLessThanOrEqual(result.quantity * result.limitPrice, 25_000 + 1e-6)
    }

    func testQuantityLimitedByCash() throws {
        let poor = RiskRules.Account(equity: 100_000, cash: 1_000, buyingPower: 1_000)
        let result = try sizing(buy(), account: poor).get()
        XCTAssertLessThanOrEqual(result.quantity * result.limitPrice, 1_000 + 1e-6)
    }

    func testTooSmallAccountIsRejected() {
        let tiny = RiskRules.Account(equity: 50, cash: 50, buyingPower: 50)
        if case .success = sizing(buy(), account: tiny) { XCTFail("Meno di un'azione: va rifiutato") }
    }

    func testPriceMovedAfterKimiIsRejected() {
        // prezzo riletto a 0,8 ATR dall'ingresso (limite 0,5 ATR)
        if case .success = sizing(buy(), price: 100.8) { XCTFail("Prezzo spostato: va rifiutato") }
    }

    func testPriceFallenNearStopIsRejected() {
        // ingresso 100, stop 99.4: il prezzo riletto a 99.55 (entro 0,5 ATR)
        // porta lo stop reale a 0,2 ATR dal limite: troppo vicino
        if case .success = sizing(buy(stop: 99.4, target: 101), price: 99.55) {
            XCTFail("Stop reale troppo vicino: va rifiutato")
        }
    }

    func testLowEffectiveRiskRewardIsRejected() {
        // ingresso 100, stop 98, target 103 (R/R 1,5 sull'entry di Kimi);
        // prezzo riletto 100.4: limite 100.46 → R/R reale (103-100.46)/2.46 ≈ 1,03
        if case .success = sizing(buy(stop: 98, target: 103), price: 100.4) {
            XCTFail("R/R effettivo sotto 1,5: va rifiutato")
        }
    }

    func testPricesRoundedToTick() throws {
        let result = try sizing(buy(entry: 100, stop: 98.0049, target: 104.0099), price: 100.003).get()
        for price in [result.limitPrice, result.stopPrice, result.takeProfitPrice] {
            XCTAssertEqual((price * 100).rounded(), price * 100, accuracy: 1e-6, "\(price) non è al centesimo")
        }
        XCTAssertLessThanOrEqual(result.stopPrice, 98.0049)
        XCTAssertLessThanOrEqual(result.takeProfitPrice, 104.0099)
    }

    func testRiskFractionIsClampedToFivePercent() throws {
        let result = try sizing(buy(), risk: 0.5).get()
        XCTAssertLessThanOrEqual(result.riskAmount, 5_000 + 1e-6)
    }

    func testRoundingHelpers() {
        XCTAssertEqual(RiskRules.roundUp(100.001, tick: 0.01), 100.01, accuracy: 1e-9)
        XCTAssertEqual(RiskRules.roundUp(100.00, tick: 0.01), 100.00, accuracy: 1e-9)
        XCTAssertEqual(RiskRules.roundDown(99.999, tick: 0.01), 99.99, accuracy: 1e-9)
        XCTAssertEqual(RiskRules.roundDown(99.99, tick: 0.01), 99.99, accuracy: 1e-9)
    }

    // MARK: - Capitale del bot

    func testCappedUsesBotCapitalAndFreePart() {
        let account = RiskRules.Account(equity: 100_000, cash: 80_000, buyingPower: 200_000)
        let capped = RiskRules.capped(account, capital: 10_000, exposure: 4_000)
        XCTAssertEqual(capped.equity, 10_000)
        XCTAssertEqual(capped.cash, 6_000)
        XCTAssertEqual(capped.buyingPower, 6_000)
    }

    func testCappedNeverExceedsRealEquityOrCash() {
        let account = RiskRules.Account(equity: 3_000, cash: 1_000, buyingPower: 1_000)
        let capped = RiskRules.capped(account, capital: 10_000, exposure: 0)
        XCTAssertEqual(capped.equity, 3_000)
        XCTAssertEqual(capped.cash, 1_000)
    }

    func testCappedFailsClosedOnBadExposure() {
        let account = RiskRules.Account(equity: 100_000, cash: 100_000, buyingPower: 100_000)
        XCTAssertEqual(RiskRules.capped(account, capital: 10_000, exposure: .nan).cash, 0)
        XCTAssertEqual(RiskRules.capped(account, capital: 10_000, exposure: 50_000).cash, 0)
        // Tetto non valido = nessun tetto (si usa il conto), mai un crash.
        XCTAssertEqual(RiskRules.capped(account, capital: .infinity, exposure: 0).equity, 100_000)
    }

    func testStopOnlySizingWithCappedAccountRespectsCap() throws {
        let account = RiskRules.capped(RiskRules.Account(equity: 100_000, cash: 100_000, buyingPower: 400_000),
                                       capital: 10_000, exposure: 0)
        let sizing = try RiskRules.sizeStopOnly(currentPrice: 100, stopDistance: 5, account: account,
                                                riskFraction: 0.01, constraints: .alpacaStock).get()
        XCTAssertLessThanOrEqual(sizing.riskAmount, 100 + 1e-6)
        XCTAssertLessThanOrEqual(sizing.quantity * sizing.limitPrice, 2_500 + 1e-6)
    }

    func testConfigClampsBotCapital() {
        XCTAssertEqual(StrategyConfig(botCapitalUSD: 10).sanitized.botCapitalUSD, 500)
        XCTAssertEqual(StrategyConfig(botCapitalUSD: 1_000).sanitized.botCapitalUSD, 1_000)
        XCTAssertEqual(StrategyConfig(botCapitalUSD: 1e9).sanitized.botCapitalUSD, 1_000_000)
        XCTAssertEqual(StrategyConfig(botCapitalUSD: .nan).sanitized.botCapitalUSD, 10_000)
        // Config salvate prima di questa versione: tutto il conto, nessun tetto.
        let old = try? JSONDecoder().decode(StrategyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old?.capitalLimitEnabled, false)
        XCTAssertEqual(old?.capitalCap, Double.infinity)
        XCTAssertEqual(StrategyConfig(capitalLimitEnabled: true, botCapitalUSD: 1_000).capitalCap, 1_000)
    }

    func testCanBuyOneShareMatchesSizing() {
        // 1.000 USD, rischio 1%: XLF a 52 con stop a 2 USD sì; SPY a 655 no (oltre il 25%).
        XCTAssertTrue(RiskRules.canBuyOneShare(price: 52, stopDistance: 2, capital: 1_000, freeCash: 1_000, riskFraction: 0.01))
        XCTAssertFalse(RiskRules.canBuyOneShare(price: 655, stopDistance: 18, capital: 1_000, freeCash: 1_000, riskFraction: 0.01))
        // Stop troppo largo per il rischio (11 USD > 10 USD di rischio).
        XCTAssertFalse(RiskRules.canBuyOneShare(price: 100, stopDistance: 11, capital: 1_000, freeCash: 1_000, riskFraction: 0.01))
        // Contante libero finito: no.
        XCTAssertFalse(RiskRules.canBuyOneShare(price: 52, stopDistance: 2, capital: 1_000, freeCash: 40, riskFraction: 0.01))
        XCTAssertFalse(RiskRules.canBuyOneShare(price: .nan, stopDistance: 2, capital: 1_000, freeCash: 1_000, riskFraction: 0.01))
        // Coerenza: quando dice sì, il dimensionamento vero trova almeno 1 azione.
        let account = RiskRules.Account(equity: 1_000, cash: 1_000, buyingPower: 1_000)
        let sizing = RiskRules.sizeStopOnly(currentPrice: 52, stopDistance: 2, account: account,
                                            riskFraction: 0.01, constraints: .alpacaStock)
        XCTAssertGreaterThanOrEqual((try? sizing.get())?.quantity ?? 0, 1)
    }

    // MARK: - Cambio di conto

    func testNewPaperAccountResetsPeakAndLocks() {
        var old = RiskGuardState(dailyStopDayUTC: "2026-11-10", peakEquity: 100_000, drawdownLocked: true)
        old.accountNumber = "PA111"
        let (state, changed) = old.adopting(account: "PA222", equity: 10_000)
        XCTAssertTrue(changed)
        XCTAssertEqual(state.peakEquity, 10_000, "Il nuovo conto da 10.000 non va confrontato col picco di 100.000")
        XCTAssertFalse(state.drawdownLocked)
        XCTAssertNil(state.dailyStopDayUTC)
        XCTAssertEqual(state.accountNumber, "PA222")
    }

    func testSameAccountKeepsState() {
        var old = RiskGuardState(dailyStopDayUTC: nil, peakEquity: 100_000, drawdownLocked: true)
        old.accountNumber = "PA111"
        let (state, changed) = old.adopting(account: "PA111", equity: 85_000)
        XCTAssertFalse(changed)
        XCTAssertEqual(state.peakEquity, 100_000)
        XCTAssertTrue(state.drawdownLocked)
        // Numero mancante nella risposta: nulla cambia.
        XCTAssertEqual(old.adopting(account: nil, equity: 1).state.peakEquity, 100_000)
    }

    func testFirstRunAfterUpdateRegistersAccountButKeepsLock() {
        let old = RiskGuardState(dailyStopDayUTC: nil, peakEquity: 100_000, drawdownLocked: true)
        let (state, changed) = old.adopting(account: "PA222", equity: 10_000)
        XCTAssertFalse(changed)
        XCTAssertEqual(state.accountNumber, "PA222")
        XCTAssertEqual(state.peakEquity, 10_000)
        XCTAssertTrue(state.drawdownLocked, "Un blocco già attivo si toglie solo a mano")
    }

    func testAccountNumberIsDecoded() throws {
        let json = #"{"account_number":"PA333","cash":"10000","equity":"10000","buying_power":"20000","trading_blocked":false,"trade_suspended_by_email":false}"#
        let snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.accountNumber, "PA333")
    }
}
