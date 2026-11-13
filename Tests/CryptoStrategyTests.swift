import XCTest
@testable import QuantSwarmAlphaZero

/// Regole V4 della modalità CRYPTO · 24/7 (proposta 20, studio run 43358878933):
/// Donchian20 sopra SMA200, uscita chandelier 3 ATR, budget 1/5 per coppia,
/// ordini frazionati e blocco drawdown al 10%.
final class CryptoStrategyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_735_689_600) // 2024-01-01 UTC

    private func bar(_ day: Int, close: Double, high: Double? = nil, low: Double? = nil) -> Candle {
        Candle(timestamp: base.addingTimeInterval(TimeInterval(day) * 86_400),
               open: close, high: high ?? close * 1.01, low: low ?? close * 0.99,
               close: close, volume: 1_000)
    }

    /// Serie che non dà segnali: 220 barre piatte a 100 (high 101, low 99).
    private var flatBars: [Candle] {
        (0..<220).map { bar($0, close: 100) }
    }

    // MARK: - Paniere

    func testPairsAreTheFiveRequested() {
        XCTAssertEqual(CryptoStrategy.pairs, ["BTC/USD", "ETH/USD", "SOL/USD", "AVAX/USD", "LINK/USD"])
        XCTAssertEqual(CryptoStrategy.pairs.count, 5)
    }

    // MARK: - Ingresso

    func testEntryOnDonchianBreakoutAboveSMA200() {
        var bars = flatBars
        bars.append(bar(220, close: 130, high: 131, low: 129)) // rottura del massimo
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)
        XCTAssertEqual(signal?.state, .entry)
        // Regime rispettato: chiusura sopra la SMA200 e sopra il Donchian.
        XCTAssertGreaterThan(signal!.close, signal!.sma200)
        XCTAssertGreaterThan(signal!.close, signal!.donchianHigh)
        XCTAssertNil(signal!.chandelier) // nessuna posizione: niente chandelier
    }

    func testNoEntryWithoutDonchianBreak() {
        var bars = flatBars
        bars.append(bar(220, close: 101, high: 150, low: 100)) // uguale al massimo Donchian, non sopra
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)
        // 101 > SMA200 (≈100) ma NON sopra il massimo HIGH delle 20 barre
        // precedenti (101): niente rottura, niente ingresso.
        XCTAssertEqual(signal?.state, .flat)
    }

    func testFlatBelowSMA200WithoutPosition() {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 90, high: 91, low: 89))
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)
        XCTAssertEqual(signal?.state, .flat)
    }

    // MARK: - Posizione aperta

    func testHoldWithChandelierBelowClose() {
        let bars = flatBars
        // Ingresso a 100, massimo chiusura 102: chandelier = 102 − 3×ATR(=2) = 96.
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: 102)
        XCTAssertEqual(signal?.state, .hold)
        XCTAssertEqual(signal?.chandelier ?? 0, 102 - 3 * 2, accuracy: 0.0001)
    }

    func testExitBelowChandelier() {
        let bars = flatBars
        // Massimo chiusura 150: chandelier = 150 − 6 = 144, ultima chiusura 100 sotto.
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: 150)
        XCTAssertEqual(signal?.state, .exit)
        XCTAssertLessThan(signal!.close, signal!.chandelier!)
    }

    func testExitBelowSMA200EvenWithHighChandelier() {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 90, high: 91, low: 89))
        // Chandelier alto (92 − 3 = 89): l'uscita deve arrivare dalla SMA200.
        let sma = (199 * 100 + 90) / 200
        XCTAssertLessThan(90, sma) // precondizione: davvero sotto la media
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: 92)
        XCTAssertEqual(signal?.state, .exit)
        XCTAssertLessThan(signal!.close, signal!.sma200)
    }

    func testWarmupWithTooFewBars() {
        let bars = (0..<100).map { bar($0, close: 100) }
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)
        XCTAssertEqual(signal?.state, .warmup)
    }

    // MARK: - Sizing frazionato

    func testPositionBudgetIsOneFifthOfTotal() {
        XCTAssertEqual(CryptoStrategy.positionBudget(total: 5_000, cash: 5_000), 1_000, accuracy: 0.0001)
        // La cassa vince se è minore: mai usare soldi che non ci sono.
        XCTAssertEqual(CryptoStrategy.positionBudget(total: 5_000, cash: 300), 300, accuracy: 0.0001)
        XCTAssertEqual(CryptoStrategy.positionBudget(total: 0, cash: 100), 0, accuracy: 0.0001)
    }

    func testFractionalQtyTruncatesAtEightDecimals() {
        // 1000 USD di BTC a 130: 7,69230769… troncato a 8 decimali.
        let qty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)
        XCTAssertNotNil(qty)
        XCTAssertEqual(qty!, (1_000.0 / 130.0 * 1e8).rounded(.down) / 1e8, accuracy: 1e-12)
        XCTAssertGreaterThan(qty!, 7.69)
        XCTAssertLessThan(qty!, 7.7)
        // Mai zero o infinito.
        XCTAssertNil(CryptoStrategy.fractionalQty(budget: 0, price: 130))
        XCTAssertNil(CryptoStrategy.fractionalQty(budget: 100, price: 0))
    }

    // MARK: - Blocco drawdown

    func testDrawdownBlockAtTenPercent() {
        XCTAssertTrue(CryptoStrategy.drawdownBlocked(equity: 89, peak: 100))   // −11%: FERMO
        XCTAssertFalse(CryptoStrategy.drawdownBlocked(equity: 90.5, peak: 100)) // −9,5%: ok
        XCTAssertFalse(CryptoStrategy.drawdownBlocked(equity: 50, peak: nil))   // niente picco: libero
        XCTAssertFalse(CryptoStrategy.drawdownBlocked(equity: 120, peak: 100)) // nuovo picco
    }

    // MARK: - Chip esplicativi (il pannello non mostra più "FUORI" secco)

    func testChipLabelFlatBelowSMA200ExplainsTheRegime() {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 90, high: 91, low: 89))
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)!
        XCTAssertEqual(signal.state, .flat)
        XCTAssertEqual(signal.chipLabel, "FUORI · sotto SMA200")
        XCTAssertEqual(signal.flatShortText, "fuori sotto SMA200")
    }

    func testChipLabelFlatAboveSMA200ShowsTheBreakoutLevel() {
        var bars = flatBars
        bars.append(bar(220, close: 100.5, high: 100.6, low: 100.4)) // sopra SMA200, nessuna rottura
        let signal = CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: bars, heldHighestClose: nil)!
        XCTAssertEqual(signal.state, .flat)
        XCTAssertTrue(signal.close > signal.sma200) // precondizione: regime ok
        XCTAssertTrue(signal.chipLabel.hasPrefix("FUORI · attende rottura "),
                      "chip = \(signal.chipLabel)")
        XCTAssertEqual(signal.flatShortText, "fuori, attende rottura")
    }

    func testChipLabelOtherStates() {
        XCTAssertEqual(CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: (0..<100).map { bar($0, close: 100) },
                                               heldHighestClose: nil)!.chipLabel, "DATI…")
        var entryBars = flatBars
        entryBars.append(bar(220, close: 130, high: 131, low: 129))
        XCTAssertEqual(CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: entryBars,
                                               heldHighestClose: nil)!.chipLabel, "ENTRATA")
        XCTAssertEqual(CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: flatBars,
                                               heldHighestClose: 102)!.chipLabel, "IN POSIZIONE")
        XCTAssertEqual(CryptoStrategy.evaluate(symbol: "BTC/USD", closedBars: flatBars,
                                               heldHighestClose: 150)!.chipLabel, "USCITA")
    }

    func testPriceTextAdaptsToMagnitude() {
        // BTC: migliaia senza decimali; AVAX: decimali fino a 4 sotto 10 USD.
        XCTAssertTrue(CryptoStrategy.priceText(68_780.63).hasPrefix("68.781") ||
                      CryptoStrategy.priceText(68_780.63).hasPrefix("68,781"))
        XCTAssertTrue(CryptoStrategy.priceText(8.118).hasPrefix("8,118") ||
                      CryptoStrategy.priceText(8.118).hasPrefix("8.118"))
        XCTAssertFalse(CryptoStrategy.priceText(1_925.11).contains(","), "niente decimali sopra 1000")
    }
}
