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
}
