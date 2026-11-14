import XCTest
@testable import QuantSwarmAlphaZero

/// Gli indirizzi scritti fissi nel codice. Il primo è la riga più delicata
/// dell'app: decide se gli ordini vanno al conto simulato o a quello reale.
final class FixedURLTests: XCTestCase {
    func testPaperAccountTalksOnlyToThePaperHost() {
        let paper = AlpacaCredentials(keyID: "k", secretKey: "s", paperTrading: true)
        XCTAssertEqual(paper.tradingBaseURL.absoluteString, "https://paper-api.alpaca.markets")
    }

    func testLiveAccountUsesTheLiveHost() {
        let live = AlpacaCredentials(keyID: "k", secretKey: "s", paperTrading: false)
        XCTAssertEqual(live.tradingBaseURL.absoluteString, "https://api.alpaca.markets")
    }

    func testMarketDataAddressesAreTheSameForPaperAndLive() {
        for paper in [true, false] {
            let credentials = AlpacaCredentials(keyID: "k", secretKey: "s", paperTrading: paper)
            XCTAssertEqual(credentials.marketDataBaseURL.absoluteString, "https://data.alpaca.markets")
            XCTAssertEqual(credentials.marketDataStreamURL.absoluteString, "wss://stream.data.alpaca.markets/v2/iex")
        }
    }

    func testUpdateSourceIsTheReleasesRepository() {
        XCTAssertEqual(UpdateChecker.sourceURL.absoluteString,
                       "https://raw.githubusercontent.com/cipherdesk007-max/quantswarm-releases/main/apps.json")
    }

    func testFixedKeepsAValidAddressUnchanged() {
        XCTAssertEqual(URL.fixed("https://api.moonshot.ai/v1/models"),
                       URL(string: "https://api.moonshot.ai/v1/models"))
    }

    func testFixedNeverStopsTheAppOnAMalformedAddress() {
        XCTAssertTrue(URL.fixed("").isFileURL,
                      "Un indirizzo malformato deve diventare un indirizzo che non risponde, non un arresto dell'app")
    }
}
