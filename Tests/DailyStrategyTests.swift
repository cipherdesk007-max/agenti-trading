import XCTest
@testable import QuantSwarmAlphaZero

/// Test della modalità giornaliera (Trend + Pullback) e del dimensionamento
/// con solo stop. Girano a ogni build: se falliscono, niente IPA.
final class DailyStrategyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01 12:00 UTC

    private func bars(_ closes: [Double]) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(
                timestamp: start.addingTimeInterval(Double(index) * 86_400),
                open: close, high: close * 1.005, low: close * 0.995, close: close, volume: 1_000
            )
        }
    }

    /// Trend rialzista lungo, poi 3 giorni di ribasso: pullback in trend.
    private var pullbackInUptrend: [Double] {
        (0..<247).map { 100 + 0.2 * Double($0) } + [146.0, 144.0, 142.0]
    }

    func testEntryOnPullbackInUptrend() throws {
        let candidate = try XCTUnwrap(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(pullbackInUptrend)))
        XCTAssertGreaterThan(candidate.snapshot.close, candidate.snapshot.sma200)
        XCTAssertLessThan(candidate.snapshot.rsi2, DailyStrategy.rsiEntryThreshold)
        XCTAssertEqual(candidate.stopDistance, DailyStrategy.stopATR * candidate.snapshot.atr14, accuracy: 1e-9)
    }

    func testNoEntryBelowSMA200() {
        let falling = (0..<250).map { 200 - 0.3 * Double($0) }
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(falling)))
    }

    func testNoEntryWithoutPullback() {
        let rising = (0..<250).map { 100 + 0.2 * Double($0) }
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(rising)))
    }

    func testNoEntryWithTooFewBars() {
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(Array(pullbackInUptrend.suffix(150)))))
    }

    func testExitWhenCloseAboveSMA5() {
        let series = pullbackInUptrend + [150.0]
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        XCTAssertEqual(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay), .aboveSMA5)
    }

    func testStayInWhileBelowSMA5AndUnderTimeLimit() {
        let series = pullbackInUptrend + [141.5]
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        XCTAssertNil(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay))
    }

    func testExitAfterTenTradingDays() {
        // 10 giorni sempre in leggero calo: mai sopra SMA5, esce a tempo
        let series = pullbackInUptrend + (1...10).map { 142.0 - 0.1 * Double($0) }
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(250 * 86_400))
        XCTAssertEqual(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay), .timeLimit)
    }

    func testFormingBarDroppedWhileMarketOpen() {
        let now = Date()
        let candles = [
            Candle(timestamp: now.addingTimeInterval(-86_400 * 2), open: 1, high: 1, low: 1, close: 1, volume: 1),
            Candle(timestamp: now, open: 1, high: 1, low: 1, close: 1, volume: 1)
        ]
        XCTAssertEqual(DailyStrategy.closedBars(candles, now: now, marketOpen: true).count, 1)
        XCTAssertEqual(DailyStrategy.closedBars(candles, now: now, marketOpen: false).count, 2)
    }

    func testDailyBookRemembersDecisionsOnlyForToday() {
        var book = DailyBook()
        book.markDecided("SPY", day: "2026-11-10")
        XCTAssertTrue(book.alreadyDecided("SPY", day: "2026-11-10"))
        XCTAssertFalse(book.alreadyDecided("SPY", day: "2026-11-11"))
        book.markDecided("QQQ", day: "2026-11-11")
        XCTAssertFalse(book.alreadyDecided("SPY", day: "2026-11-11"))
    }

    func testShadowResolvesOnFirstCloseAboveSMA5() throws {
        let series = pullbackInUptrend + [141.0, 150.0, 151.0]
        let candles = bars(series)
        let day = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        let entry = ShadowEntry(symbol: "SPY", day: day, entry: 142, stop: 130, outcome: ShadowEntry.brainSkip)
        let exit = try XCTUnwrap(ShadowEvaluator.resolve(entry, bars: candles))
        XCTAssertEqual(exit.price, 150, accuracy: 1e-9)
    }

    func testShadowResolvesOnStop() throws {
        let series = pullbackInUptrend + [120.0]
        let day = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        let entry = ShadowEntry(symbol: "SPY", day: day, entry: 142, stop: 135, outcome: ShadowEntry.bought)
        let exit = try XCTUnwrap(ShadowEvaluator.resolve(entry, bars: bars(series)))
        XCTAssertEqual(exit.price, 120, accuracy: 1e-9, "Gap sotto lo stop: esce all'apertura")
    }

    func testShadowSummaryComparesChosenAndSkipped() {
        var a = ShadowEntry(symbol: "SPY", day: "d", entry: 100, stop: 90, outcome: ShadowEntry.bought)
        a.exitPrice = 102
        var b = ShadowEntry(symbol: "QQQ", day: "d", entry: 100, stop: 90, outcome: ShadowEntry.brainSkip)
        b.exitPrice = 99
        let summary = ShadowSummary.from([a, b])
        XCTAssertEqual(summary.chosenAverage ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(summary.skippedAverage ?? 0, -0.01, accuracy: 1e-9)
        XCTAssertNil(summary.feedbackText, "Con meno di 3 esiti niente feedback a Kimi")
    }

    func testBasketHasNoDuplicates() {
        XCTAssertEqual(Set(DailyStrategy.basket).count, DailyStrategy.basket.count)
    }

    // MARK: - Dimensionamento con solo stop

    private let account = RiskRules.Account(equity: 100_000, cash: 100_000, buyingPower: 400_000)

    func testStopOnlySizingRespectsRiskAndCap() throws {
        let result = try RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 12.5, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ).get()
        XCTAssertLessThanOrEqual(result.riskAmount, 1_000 + 1e-6)
        XCTAssertLessThanOrEqual(result.quantity * result.limitPrice, 25_000 + 1e-6)
        XCTAssertLessThan(result.stopPrice, result.limitPrice)
        XCTAssertEqual(result.quantity, result.quantity.rounded(.down))
    }

    func testStopOnlySizingRejectsInvalidInput() {
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 0, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Stop nullo: va rifiutato") }
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 10, stopDistance: 20, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Stop sotto zero: va rifiutato") }
    }

    func testStopOnlySizingTooSmallAccount() {
        let tiny = RiskRules.Account(equity: 100, cash: 100, buyingPower: 100)
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 12.5, account: tiny,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Meno di un'azione: va rifiutato") }
    }

    func testDefaultModeIsDaily() {
        XCTAssertEqual(StrategyConfig().tradingMode, .daily)
        let legacy = try? JSONDecoder().decode(StrategyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy?.tradingMode, .daily)
        XCTAssertEqual(legacy?.widgetShowsAmounts, false, "Importi nel widget nascosti di default")
    }
}
