import XCTest
@testable import QuantSwarmAlphaZero

final class EquityHistoryTests: XCTestCase {
    func testSameDayReplacesNewDayAppends() {
        var points = EquityHistory.record([], day: "2026-11-02", equity: 100_000, benchmark: 600, capital: 10_000)
        points = EquityHistory.record(points, day: "2026-11-02", equity: 100_200, benchmark: nil)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].equity, 100_200)
        XCTAssertEqual(points[0].benchmark, 600, "Senza un nuovo prezzo SPY si tiene quello del giorno")
        XCTAssertEqual(points[0].capital, 10_000)
        points = EquityHistory.record(points, day: "2026-11-03", equity: 100_100, benchmark: 606)
        XCTAssertEqual(points.count, 2)
    }

    func testPastDaysAndInvalidValuesAreIgnored() {
        let points = EquityHistory.record([], day: "2026-11-05", equity: 100_000, benchmark: 600)
        XCTAssertEqual(EquityHistory.record(points, day: "2026-11-04", equity: 1, benchmark: 1), points)
        XCTAssertEqual(EquityHistory.record(points, day: "2026-11-06", equity: .nan, benchmark: 600), points)
        XCTAssertEqual(EquityHistory.record(points, day: "2026-11-06", equity: -5, benchmark: 600), points)
        XCTAssertEqual(EquityHistory.record(points, day: "", equity: 100, benchmark: 600), points)
    }

    func testReturnIsMeasuredOnBotCapital() throws {
        // +500 USD su un conto da 100.000 con capitale bot 10.000 = +5%.
        var points = EquityHistory.record([], day: "2026-11-02", equity: 100_000, benchmark: 600, capital: 10_000)
        points = EquityHistory.record(points, day: "2026-11-03", equity: 100_500, benchmark: 612, capital: 10_000)
        let summary = try XCTUnwrap(EquityHistory.summary(points))
        XCTAssertEqual(summary.botReturn, 0.05, accuracy: 1e-9)
        XCTAssertEqual(summary.benchmarkReturn ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(summary.days, 2)
    }

    func testMaxDrawdownFromPeak() throws {
        var points: [EquityPoint] = []
        for (i, value) in [10_000.0, 11_000, 9_900, 10_500].enumerated() {
            points = EquityHistory.record(points, day: "2026-11-0\(i + 1)", equity: value, benchmark: nil)
        }
        let summary = try XCTUnwrap(EquityHistory.summary(points))
        XCTAssertEqual(summary.maxDrawdown, 9_900.0 / 11_000 - 1, accuracy: 1e-9)
        XCTAssertNil(summary.benchmarkReturn)
    }

    func testCapitalNeverAboveEquityAndHistoryIsCapped() {
        let one = EquityHistory.record([], day: "2026-11-02", equity: 3_000, benchmark: nil, capital: 10_000)
        XCTAssertEqual(one[0].capital, 3_000)
        var points: [EquityPoint] = []
        for i in 0..<(EquityHistory.maximumPoints + 10) {
            points = EquityHistory.record(points, day: String(format: "D%05d", i), equity: 100, benchmark: nil)
        }
        XCTAssertEqual(points.count, EquityHistory.maximumPoints)
        XCTAssertEqual(points.first?.day, "D00010")
    }

    func testSummaryNeedsTwoPoints() {
        XCTAssertNil(EquityHistory.summary([]))
        XCTAssertNil(EquityHistory.summary([EquityPoint(day: "2026-11-02", equity: 1, benchmark: nil)]))
    }
}
