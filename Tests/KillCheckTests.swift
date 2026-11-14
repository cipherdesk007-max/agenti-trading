import XCTest
@testable import QuantSwarmAlphaZero

/// Dopo HARD KILL il conto si rilegge: "completato" si dice solo se è vero.
final class KillCheckTests: XCTestCase {
    func testNoPositionsMeansFlat() {
        let check = KillCheck.evaluate(positions: [], orderSymbols: [])
        XCTAssertTrue(check.isFlat)
        XCTAssertTrue(check.stillOpen.isEmpty)
        XCTAssertTrue(check.queued.isEmpty)
    }

    /// Mercato chiuso: le azioni restano in portafoglio con la vendita in coda.
    func testPositionWithClosingOrderIsQueuedNotOpen() {
        let check = KillCheck.evaluate(positions: [("SPY", 3), ("QQQ", 2)], orderSymbols: ["QQQ", "SPY"])
        XCTAssertFalse(check.isFlat)
        XCTAssertEqual(check.queued, ["QQQ", "SPY"])
        XCTAssertTrue(check.stillOpen.isEmpty)
    }

    /// Una chiusura non è partita: la posizione è ancora lì senza ordine.
    func testPositionWithoutClosingOrderIsReportedAsStillOpen() {
        let check = KillCheck.evaluate(positions: [("SPY", 3), ("TLT", 5)], orderSymbols: ["SPY"])
        XCTAssertEqual(check.stillOpen, ["TLT"])
        XCTAssertEqual(check.queued, ["SPY"])
        XCTAssertFalse(check.isFlat)
    }

    /// Crypto: posizione scritta "BTCUSD", ordine scritto "BTC/USD".
    func testCryptoSymbolsMatchAcrossTheTwoSpellings() {
        let check = KillCheck.evaluate(positions: [("BTCUSD", 0.01)], orderSymbols: ["BTC/USD"])
        XCTAssertEqual(check.queued, ["BTCUSD"])
        XCTAssertTrue(check.stillOpen.isEmpty)
    }

    /// Residui a zero (posizione appena chiusa) non contano.
    func testZeroQuantityIsIgnored() {
        let check = KillCheck.evaluate(positions: [("SPY", 0)], orderSymbols: [])
        XCTAssertTrue(check.isFlat)
    }
}
