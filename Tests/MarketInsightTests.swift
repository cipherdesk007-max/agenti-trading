import XCTest
@testable import QuantSwarmAlphaZero

final class MarketInsightTests: XCTestCase {
    private func candles(_ closes: [Double]) -> [Candle] {
        let start = Date(timeIntervalSince1970: 1_735_732_800)
        return closes.enumerated().map { i, c in
            Candle(timestamp: start.addingTimeInterval(Double(i) * 86_400), open: c, high: c * 1.005, low: c * 0.995, close: c, volume: 1)
        }
    }

    private var pullback: [Candle] { candles((0..<247).map { 100 + 0.2 * Double($0) } + [146, 144, 142]) }
    private var rising: [Candle] { candles((0..<250).map { 100 + 0.2 * Double($0) }) }
    private var falling: [Candle] { candles((0..<250).map { 200 - 0.2 * Double($0) }) }

    func testSignalWhenTrendUpAndDeepPullback() {
        let i = MarketInsight.evaluate(symbol: "SPY", bars: pullback, held: false, capital: 100_000, riskFraction: 0.01)
        XCTAssertEqual(i.state, .signal)
        XCTAssertNotNil(i.snapshot)
    }

    func testSignalOutOfCapitalIsFlagged() {
        let i = MarketInsight.evaluate(symbol: "SPY", bars: pullback, held: false, capital: 300, riskFraction: 0.01)
        XCTAssertEqual(i.state, .unaffordable)
    }

    func testTrendStates() {
        XCTAssertEqual(MarketInsight.evaluate(symbol: "A", bars: rising, held: false, capital: 100_000, riskFraction: 0.01).state, .trendUp)
        XCTAssertEqual(MarketInsight.evaluate(symbol: "A", bars: falling, held: false, capital: 100_000, riskFraction: 0.01).state, .trendDown)
        XCTAssertEqual(MarketInsight.evaluate(symbol: "A", bars: rising, held: true, capital: 100_000, riskFraction: 0.01).state, .held)
        XCTAssertEqual(MarketInsight.evaluate(symbol: "A", bars: Array(rising.prefix(50)), held: false, capital: 100_000, riskFraction: 0.01).state, .noData)
    }

    func testDayChange() throws {
        let i = MarketInsight.evaluate(symbol: "A", bars: candles([100, 102]), held: false, capital: 1_000, riskFraction: 0.01)
        XCTAssertEqual(try XCTUnwrap(i.dayChange), 0.02, accuracy: 1e-9)
    }

    func testMovingAverage() {
        let ma = MarketInsight.movingAverage([1, 2, 3, 4, 5], period: 3)
        XCTAssertNil(ma[0]); XCTAssertNil(ma[1])
        XCTAssertEqual(ma[2] ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(ma[4] ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(MarketInsight.movingAverage([1, 2], period: 0).compactMap { $0 }.count, 0)
    }
}
