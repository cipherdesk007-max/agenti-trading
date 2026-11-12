import XCTest
@testable import QuantSwarmAlphaZero

final class ShadowSummaryTests: XCTestCase {
    private func entry(_ outcome: String, ret: Double, day: Int) -> ShadowEntry {
        var e = ShadowEntry(symbol: "S\(day)", day: String(format: "2026-01-%02d", day % 28 + 1), entry: 100, stop: 90, outcome: outcome)
        e.exitPrice = 100 * (1 + ret)
        e.exitDay = String(format: "2026-%02d-%02d", day / 28 + 2, day % 28 + 1)
        return e
    }

    func testGroupsAndEdge() throws {
        let entries = [
            entry(ShadowEntry.bought, ret: 0.03, day: 1),
            entry(ShadowEntry.bought, ret: 0.01, day: 2),
            entry(ShadowEntry.brainSkip, ret: -0.02, day: 3),
            entry(ShadowEntry.reviewerReject, ret: -0.01, day: 4),
            entry(ShadowEntry.noSlot, ret: 0.00, day: 5)
        ]
        let s = ShadowSummary.from(entries)
        XCTAssertEqual(s.rules.count, 5)
        XCTAssertEqual(s.rules.average ?? 0, 0.002, accuracy: 1e-9)
        XCTAssertEqual(s.chosen.average ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(s.chosen.winRate ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(s.reviewerRejected.count, 1)
        XCTAssertEqual(s.kimiEdge ?? 0, 0.018, accuracy: 1e-9)
        XCTAssertEqual(s.verdict, .notEnoughData(have: 5, need: 30))
    }

    func testVerdictAfterEnoughOutcomes() {
        var good: [ShadowEntry] = []
        for i in 0..<40 {
            good.append(entry(i % 4 == 0 ? ShadowEntry.bought : ShadowEntry.brainSkip, ret: i % 4 == 0 ? 0.02 : -0.01, day: i))
        }
        XCTAssertEqual(ShadowSummary.from(good).verdict, .kimiAddsValue)
        var bad: [ShadowEntry] = []
        for i in 0..<40 {
            bad.append(entry(i % 4 == 0 ? ShadowEntry.bought : ShadowEntry.brainSkip, ret: i % 4 == 0 ? -0.02 : 0.01, day: i))
        }
        XCTAssertEqual(ShadowSummary.from(bad).verdict, .kimiHurts)
    }

    func testTrendOlderVsRecent() throws {
        var entries: [ShadowEntry] = []
        // Prima metà: Kimi sceglie i peggiori; seconda metà: i migliori.
        for i in 0..<20 {
            let older = i < 10
            let pick = i % 2 == 0
            let ret = pick ? (older ? -0.02 : 0.02) : 0.0
            entries.append(entry(pick ? ShadowEntry.bought : ShadowEntry.brainSkip, ret: ret, day: i))
        }
        let s = ShadowSummary.from(entries)
        XCTAssertLessThan(try XCTUnwrap(s.olderEdge), 0)
        XCTAssertGreaterThan(try XCTUnwrap(s.recentEdge), 0)
    }

    // MARK: - Filtro evento 48h (prova in ombra)

    func testEventFilterMatchesOnlyImpactfulWords() {
        XCTAssertTrue(EventFilter48h.isEventful(["Fed holds rates steady"]))
        XCTAssertTrue(EventFilter48h.isEventful(["SPY edges higher", "CPI surprises"]))
        XCTAssertTrue(EventFilter48h.isEventful(["Earnings: Apple beats"]))
        XCTAssertTrue(EventFilter48h.isEventful(["Oil jumps as war escalates"]))
        XCTAssertFalse(EventFilter48h.isEventful(["Apple announces new colors"]))
        XCTAssertFalse(EventFilter48h.isEventful(["Software update rolls out"]), "war dentro software è un falso positivo evitato")
        XCTAssertFalse(EventFilter48h.isEventful(["Stocks toward record highs"]), "war dentro toward è un falso positivo evitato")
        XCTAssertFalse(EventFilter48h.isEventful([]))
        XCTAssertEqual(Set(EventFilter48h.matchedKeywords(in: ["Fed signals rate cut after CPI"])), ["fed", "cpi", "rate cut"])
        XCTAssertTrue(EventFilter48h.matchedKeywords(in: ["Apple announces new colors"]).isEmpty)
    }

    func testLegacyShadowEntryDecodesWithoutEventFlag() throws {
        // Le voci registrate prima della prova in ombra non hanno il campo:
        // la decodifica deve riuscire e lasciare il flag a nil.
        let legacy = #"{"symbol":"SPY","day":"2026-01-05","entry":100,"stop":90,"outcome":"bought"}"#
        let decoded = try JSONDecoder().decode(ShadowEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.eventFlag, "Le voci storiche restano senza flag, non false")
        XCTAssertEqual(decoded.symbol, "SPY")
    }

    func testEventFlagSurvivesRoundTrip() throws {
        var e = entry(ShadowEntry.bought, ret: 0.02, day: 9)
        e.eventFlag = true
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(ShadowEntry.self, from: data)
        XCTAssertEqual(back.eventFlag, true)
    }

    func testEventGroupsAndFilterEdge() throws {
        var flaggedLoss = entry(ShadowEntry.bought, ret: -0.04, day: 1)
        flaggedLoss.eventFlag = true
        var flaggedWin = entry(ShadowEntry.brainSkip, ret: 0.01, day: 2)
        flaggedWin.eventFlag = true
        var cleanA = entry(ShadowEntry.bought, ret: 0.02, day: 3)
        cleanA.eventFlag = false
        var cleanB = entry(ShadowEntry.brainSkip, ret: 0.00, day: 4)
        cleanB.eventFlag = false
        let legacy = entry(ShadowEntry.bought, ret: 0.05, day: 5) // flag nil: fuori dal confronto

        let s = ShadowSummary.from([flaggedLoss, flaggedWin, cleanA, cleanB, legacy])
        XCTAssertEqual(s.eventFlagged.count, 2)
        XCTAssertEqual(s.eventClean.count, 2)
        XCTAssertEqual(s.eventFlagged.average ?? 0, -0.015, accuracy: 1e-9)
        XCTAssertEqual(s.eventClean.average ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.eventFilterEdge), 0.025, accuracy: 1e-9,
                       "Positivo = i candidati con evento hanno reso meno: il filtro proteggeva")
        XCTAssertEqual(s.rules.count, 5, "Le voci senza flag contano comunque negli altri gruppi")
    }

    func testEventFilterEdgeNilWithoutBothSides() {
        var onlyFlagged = entry(ShadowEntry.bought, ret: -0.04, day: 1)
        onlyFlagged.eventFlag = true
        let s = ShadowSummary.from([onlyFlagged])
        XCTAssertNil(s.eventFilterEdge, "Serve almeno un esito per lato prima di misurare il filtro")
    }
}
