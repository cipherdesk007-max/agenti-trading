import XCTest
@testable import QuantSwarmAlphaZero

/// Il filtro gratuito deve chiamare Kimi solo su setup di ACQUISTO.
final class FilterTriggerTests: XCTestCase {
    private func candles(_ closes: [Double], volumes: [Double]? = nil) -> [Candle] {
        closes.enumerated().map { index, close in
            let open = index == 0 ? close : closes[index - 1]
            return Candle(
                timestamp: Date(timeIntervalSince1970: Double(index) * 900),
                open: open,
                high: max(open, close) + 0.05,
                low: min(open, close) - 0.05,
                close: close,
                volume: volumes?[index] ?? 1_000
            )
        }
    }

    func testTooFewCandlesNeverTrigger() {
        XCTAssertNil(FilterTrigger.evaluate(candles: candles(Array(repeating: 100, count: 20))))
    }

    func testFlatMarketDoesNotTrigger() {
        XCTAssertNil(FilterTrigger.evaluate(candles: candles(Array(repeating: 100, count: 40))))
    }

    func testSteadyDowntrendDoesNotTrigger() {
        // Nuovi minimi continui: prima era un trigger, ora è solo ribasso.
        let closes = (0..<40).map { 110 - Double($0) * 0.25 }
        XCTAssertNil(FilterTrigger.evaluate(candles: candles(closes)))
    }

    func testBreakoutWithVolumeTriggers() {
        var closes = Array(repeating: 100.0, count: 39)
        closes.append(101.0)
        var volumes = Array(repeating: 1_000.0, count: 39)
        volumes.append(2_500)
        XCTAssertNotNil(FilterTrigger.evaluate(candles: candles(closes, volumes: volumes)))
    }

    func testBreakoutWithoutVolumeDoesNotTriggerAsBreakout() {
        var closes = Array(repeating: 100.0, count: 39)
        closes.append(101.0)
        var volumes = Array(repeating: 1_000.0, count: 39)
        volumes.append(100)
        let trigger = FilterTrigger.evaluate(candles: candles(closes, volumes: volumes))
        XCTAssertFalse(trigger?.contains("rottura") ?? false)
    }

    func testBullishEMACrossTriggers() {
        // Discesa lunga poi risalita decisa: EMA12 incrocia sopra EMA26.
        var closes = (0..<30).map { 110 - Double($0) * 0.3 }
        var trigger: String?
        var price = closes.last!
        for _ in 0..<15 {
            price += 0.8
            closes.append(price)
            if let found = FilterTrigger.evaluate(candles: candles(closes)) {
                trigger = found
                break
            }
        }
        XCTAssertNotNil(trigger, "una risalita decisa deve produrre un setup long")
    }
}
