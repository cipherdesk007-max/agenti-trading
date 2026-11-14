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
        // Parla degli ETF originali, non dei gemelli micro come scelta principale.
        XCTAssertTrue(advice!.detail.contains("ETF originali"))
        XCTAssertTrue(advice!.detail.contains("niente gemelli micro necessari"))
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

    /// Lo studio rifatto il 14/11/2026 con la dimensione delle posizioni
    /// dell'app (tools/studio_universo.py, run 43572591958) dà alla crypto una
    /// perdita massima del 41%: il consiglio deve dirlo, in ogni fascia in cui
    /// nomina la crypto, e non può più chiamarla "validata".
    func testEveryAdviceThatNamesCryptoStatesItsRisk() {
        let small = BalanceAdvisor.advise(equity: 1_000)
        XCTAssertTrue(small?.detail.contains("−41%") ?? false)
        let medium = BalanceAdvisor.advise(equity: 3_000)
        XCTAssertTrue(medium?.alternative?.contains("−41%") ?? false)
        for advice in [small, medium] {
            let text = (advice?.detail ?? "") + (advice?.alternative ?? "")
            XCTAssertFalse(text.contains("validat"), "Niente \"validata dallo studio\": lo studio usava posizioni 7 volte più piccole")
        }
    }
}
