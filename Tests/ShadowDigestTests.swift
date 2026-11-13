import XCTest
@testable import QuantSwarmAlphaZero

/// ShadowDigest (task "Kimi + registro ombra"): gli ultimi 10 esiti risolti
/// del registro ombra con il rendimento reale, per l'auto-correzione dei bias
/// di Brain e Reviewer. Record leggeri: costruito al volo, mai salvato.
final class ShadowDigestTests: XCTestCase {
    private func entry(symbol: String, day: String, outcome: String,
                       entryPrice: Double, exitPrice: Double?, exitDay: String?) -> ShadowEntry {
        var e = ShadowEntry(symbol: symbol, day: day, entry: entryPrice,
                            stop: entryPrice * 0.95, outcome: outcome, eventFlag: nil)
        e.exitPrice = exitPrice
        e.exitDay = exitDay
        return e
    }

    func testEmptyRegistryGivesNoDigest() {
        XCTAssertNil(ShadowDigest.from([]))
        // Voci non risolte (trade ancora aperti) non bastano.
        let open = entry(symbol: "SPY", day: "2026-11-01", outcome: ShadowEntry.bought,
                         entryPrice: 100, exitPrice: nil, exitDay: nil)
        XCTAssertNil(ShadowDigest.from([open]))
    }

    func testLatestTenResolvedOutcomesOnly() {
        var entries: [ShadowEntry] = []
        for i in 0..<15 {
            entries.append(entry(symbol: "S\(i)", day: "2026-10-\(String(format: "%02d", i + 1))",
                                 outcome: i % 2 == 0 ? ShadowEntry.bought : ShadowEntry.brainSkip,
                                 entryPrice: 100, exitPrice: 110, exitDay: "2026-10-\(String(format: "%02d", i + 2))"))
        }
        guard let digest = ShadowDigest.from(entries) else {
            return XCTFail("digest atteso con 15 esiti risolti")
        }
        XCTAssertEqual(digest.recent.count, 10) // al massimo 10
        // I più recenti per ultimi: il primo della lista è il sesto più vecchio.
        XCTAssertEqual(digest.recent.first?.symbol, "S5")
        XCTAssertEqual(digest.recent.last?.symbol, "S14")
        // Rendimenti in %: 110/100 − 1 = +10%.
        XCTAssertEqual(digest.recent.first?.returnPct ?? 0, 10, accuracy: 0.0001)
        // Le medie coprono TUTTI i 15 risolti, non solo 10.
        XCTAssertEqual(digest.chosenAveragePct ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(digest.skippedAveragePct ?? 0, 10, accuracy: 0.0001)
    }

    func testChosenVersusSkippedAverages() {
        let entries = [
            entry(symbol: "SPY", day: "2026-10-01", outcome: ShadowEntry.bought,
                  entryPrice: 100, exitPrice: 90, exitDay: "2026-10-05"),   // scelto: −10%
            entry(symbol: "QQQ", day: "2026-10-02", outcome: ShadowEntry.brainSkip,
                  entryPrice: 100, exitPrice: 120, exitDay: "2026-10-06"), // scartato: +20%
            entry(symbol: "IWM", day: "2026-10-03", outcome: ShadowEntry.bought,
                  entryPrice: 100, exitPrice: 105, exitDay: "2026-10-07"), // scelto: +5%
        ]
        guard let digest = ShadowDigest.from(entries) else {
            return XCTFail("digest atteso")
        }
        XCTAssertEqual(digest.chosenAveragePct ?? 0, -2.5, accuracy: 0.0001)  // (−10 + 5) / 2
        XCTAssertEqual(digest.skippedAveragePct ?? 0, 20, accuracy: 0.0001)
        // La bandiera chosen distingue scelti e scartati nel payload Kimi.
        XCTAssertTrue(digest.recent[0].chosen)   // SPY comprato
        XCTAssertFalse(digest.recent[1].chosen)  // QQQ scartato dal Brain
        XCTAssertEqual(digest.recent[1].outcome, ShadowEntry.brainSkip)
        // Ordine per giorno di USCITA: SPY (05), QQQ (06), IWM (07).
        XCTAssertEqual(digest.recent.map(\.symbol), ["SPY", "QQQ", "IWM"])
    }

    func testNilAverageWhenOneSideHasNoResolvedTrades() {
        let entries = [
            entry(symbol: "SPY", day: "2026-10-01", outcome: ShadowEntry.bought,
                  entryPrice: 100, exitPrice: 110, exitDay: "2026-10-05"),
            entry(symbol: "QQQ", day: "2026-10-02", outcome: ShadowEntry.brainSkip,
                  entryPrice: 100, exitPrice: nil, exitDay: nil), // mai uscito
        ]
        guard let digest = ShadowDigest.from(entries) else {
            return XCTFail("digest atteso")
        }
        XCTAssertEqual(digest.chosenAveragePct ?? 0, 10, accuracy: 0.0001)
        XCTAssertNil(digest.skippedAveragePct) // nessuno scartato risolto
    }

    // MARK: - Payload per i prompt Kimi (leggero per costruzione)

    func testKimiShadowPayloadIsCompact() throws {
        XCTAssertNil(KimiService.shadowPayload(nil)) // nessun dato: campo nullo

        let entries = [
            entry(symbol: "SPY", day: "2026-10-01", outcome: ShadowEntry.bought,
                  entryPrice: 100, exitPrice: 110, exitDay: "2026-10-05"),
            entry(symbol: "QQQ", day: "2026-10-02", outcome: ShadowEntry.reviewerReject,
                  entryPrice: 100, exitPrice: 95, exitDay: "2026-10-06"),
        ]
        guard let digest = ShadowDigest.from(entries) else {
            return XCTFail("digest atteso")
        }
        let payload = try XCTUnwrap(KimiService.shadowPayload(digest))
        XCTAssertEqual((payload["recent"] as? [[String: Any]])?.count, 2)
        let recent = try XCTUnwrap(payload["recent"] as? [[String: Any]])
        XCTAssertTrue(recent[0]["chosen"] as? Bool == true)
        XCTAssertEqual(recent[0]["return_pct"] as? Double, 10)
        XCTAssertEqual(payload["chosen_avg_pct"] as? Double, 10)
        XCTAssertEqual(payload["skipped_avg_pct"] as? Double, -5)
    }
}
