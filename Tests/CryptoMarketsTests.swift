import XCTest
@testable import QuantSwarmAlphaZero

/// MERCATI in modalità CRYPTO: la casella di ogni coppia dice lo stato della
/// regola V4 con le stesse parole degli ETF.
final class CryptoMarketsTests: XCTestCase {
    private func signal(_ state: CryptoStrategy.Signal.State, close: Double = 100, sma: Double = 90,
                        donchian: Double = 110) -> CryptoStrategy.Signal {
        CryptoStrategy.Signal(symbol: "BTC/USD", state: state, close: close, sma200: sma,
                              donchianHigh: donchian, atr22: 3, chandelier: nil)
    }

    func testBelowTheAverageIsTrendDownAndSaysWhy() {
        let insight = MarketInsight.crypto(pair: "BTC/USD", signal: signal(.flat, close: 80, sma: 90),
                                           livePrice: 82, held: false)
        XCTAssertEqual(insight.state, .trendDown)
        XCTAssertEqual(insight.close ?? 0, 82, accuracy: 1e-9)
        XCTAssertEqual(insight.dayChange ?? 0, 82.0 / 80.0 - 1, accuracy: 1e-9)
        XCTAssertTrue(insight.reason.contains("non compra"), insight.reason)
    }

    func testAboveTheAverageWaitsForTheBreakout() {
        let insight = MarketInsight.crypto(pair: "BTC/USD", signal: signal(.flat, close: 100, sma: 90, donchian: 110),
                                           livePrice: 101, held: false)
        XCTAssertEqual(insight.state, .trendUp)
        XCTAssertTrue(insight.reason.contains("110"), insight.reason)
    }

    func testEntryIsASignalAndPositionIsHeld() {
        XCTAssertEqual(MarketInsight.crypto(pair: "BTC/USD", signal: signal(.entry), livePrice: 100, held: false).state, .signal)
        XCTAssertEqual(MarketInsight.crypto(pair: "BTC/USD", signal: signal(.hold), livePrice: 100, held: true).state, .held)
        let exiting = MarketInsight.crypto(pair: "BTC/USD", signal: signal(.exit), livePrice: 100, held: true)
        XCTAssertEqual(exiting.state, .held)
        XCTAssertTrue(exiting.reason.contains("esce"), exiting.reason)
    }

    /// Senza segnale (app appena aperta) o senza prezzo live la casella non
    /// inventa numeri: nessuna variazione, stato "dati".
    func testNoSignalMeansNoInventedNumbers() {
        let empty = MarketInsight.crypto(pair: "SOL/USD", signal: nil, livePrice: nil, held: false)
        XCTAssertEqual(empty.state, .noData)
        XCTAssertNil(empty.close)
        XCTAssertNil(empty.dayChange)
        let warmup = MarketInsight.crypto(pair: "SOL/USD", signal: signal(.warmup, close: 0), livePrice: 0, held: false)
        XCTAssertEqual(warmup.state, .noData)
        XCTAssertNil(warmup.close)
        // Prezzo live assente ma segnale presente: si usa l'ultima chiusura, variazione zero.
        let noLive = MarketInsight.crypto(pair: "BTC/USD", signal: signal(.flat, close: 80, sma: 90), livePrice: 0, held: false)
        XCTAssertEqual(noLive.close ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(noLive.dayChange ?? 1, 0, accuracy: 1e-9)
    }
}
