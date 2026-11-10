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
}
