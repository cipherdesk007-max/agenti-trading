import XCTest
@testable import QuantSwarmAlphaZero

/// BALANCE ADVISOR: consiglio della modalità in base al saldo, tre fasce
/// stabilite dal proprietario (<1.500 · 1.500–5.000 · >5.000 USD).
final class BalanceAdvisorTests: XCTestCase {
    func testNoAdviceWithoutBalance() {
        XCTAssertNil(BalanceAdvisor.advise(equity: nil))
        XCTAssertNil(BalanceAdvisor.advise(equity: 0))
        XCTAssertNil(BalanceAdvisor.advise(equity: -100))
        XCTAssertNil(BalanceAdvisor.advise(equity: .nan))
        XCTAssertNil(BalanceAdvisor.advise(equity: .infinity))
    }

    func testSmallBalanceRecommendsCrypto() {
        let advice = BalanceAdvisor.advise(equity: 1_000)
        XCTAssertEqual(advice?.recommended, .crypto)
        XCTAssertTrue(advice!.headline.contains("CRYPTO"))
        // La motivazione parlano di ordini frazionati (niente blocchi di liquidità).
        XCTAssertTrue(advice!.detail.contains("frazionat"))
        XCTAssertNotNil(advice!.alternative) // c'è sempre una seconda via
    }

    func testMicroBoundaryJustBelow1500() {
        let advice = BalanceAdvisor.advise(equity: 1_499)
        XCTAssertEqual(advice?.recommended, .crypto)
    }

    func testMediumBalanceRecommendsPortfolioMicroOrCrypto() {
        let advice = BalanceAdvisor.advise(equity: 1_500) // soglia inclusa
        XCTAssertEqual(advice?.recommended, .portfolio)
        XCTAssertTrue(advice!.detail.contains("micro"))
        XCTAssertNotNil(advice!.alternative)
        XCTAssertTrue(advice!.alternative!.contains("CRYPTO"))

        let mid = BalanceAdvisor.advise(equity: 3_000)
        XCTAssertEqual(mid?.recommended, .portfolio)
        let top = BalanceAdvisor.advise(equity: 5_000) // 5.000 è ancora "medio"
        XCTAssertEqual(top?.recommended, .portfolio)
        XCTAssertNotNil(top?.alternative)
    }

    func testLargeBalanceRecommendsFullPortfolio() {
        let advice = BalanceAdvisor.advise(equity: 5_001)
        XCTAssertEqual(advice?.recommended, .portfolio)
        XCTAssertTrue(advice!.headline.contains("completo"))
        XCTAssertNil(advice!.alternative) // fascia piena: nessuna alternativa
        XCTAssertFalse(advice!.detail.contains("micro"))
    }

    func testMaskedAmountsHideTheBalance() {
        let plain = BalanceAdvisor.advise(equity: 1_000)
        let masked = BalanceAdvisor.advise(equity: 1_000, maskAmounts: true)
        XCTAssertTrue(plain!.detail.contains("1.000 USD") || plain!.detail.contains("1000 USD"))
        XCTAssertFalse(masked!.detail.contains("USD"))
        XCTAssertTrue(masked!.detail.contains("fascia"))
        // Il consiglio non cambia: solo il numero è nascosto.
        XCTAssertEqual(plain!.recommended, masked!.recommended)
        XCTAssertEqual(plain!.headline, masked!.headline)
    }
}
