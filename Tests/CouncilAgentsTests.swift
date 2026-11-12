import XCTest
@testable import QuantSwarmAlphaZero

/// Test del consiglio degli specialisti (FASE 2-4 del progetto): regole
/// deterministiche di tecnica/quant/notizie/fondamentali/portafoglio,
/// divergenze, digest giornaliero, pagella e payload per Kimi.
/// Tutto locale: zero chiamate di rete, zero crediti.
final class CouncilAgentsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01 12:00 UTC

    // MARK: - Fixture

    private func candles(_ closes: [Double], frame: Double = 900) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(
                timestamp: start.addingTimeInterval(Double(index) * frame),
                open: close, high: close * 1.005, low: close * 0.995, close: close, volume: 1_000
            )
        }
    }

    private func indicators(
        rsi14: Double? = nil, ema12: Double? = nil, ema26: Double? = nil,
        sma50: Double? = nil, sma200: Double? = nil, atr14: Double? = nil,
        high20: Double? = nil, low20: Double? = nil, avgVolume20: Double? = nil
    ) -> IndicatorSnapshot {
        IndicatorSnapshot(rsi14: rsi14, ema12: ema12, ema26: ema26, sma50: sma50,
                          sma200: sma200, atr14: atr14, high20: high20, low20: low20,
                          avgVolume20: avgVolume20)
    }

    private func context(
        closes15: [Double], i15: IndicatorSnapshot,
        closes1: [Double] = [100, 100.2, 100.4, 100.6],
        i1: IndicatorSnapshot = IndicatorSnapshot(
            rsi14: 55, ema12: 100.4, ema26: 100.2, sma50: 100, sma200: 98,
            atr14: 0.5, high20: 101, low20: 99, avgVolume20: 1_000
        )
    ) -> MarketContext {
        MarketContext(
            oneMinuteCandles: candles(closes1, frame: 60),
            fifteenMinuteCandles: candles(closes15),
            oneMinuteIndicators: i1,
            fifteenMinuteIndicators: i15
        )
    }

    private func position(_ symbol: String, value: Double) -> AlpacaPosition {
        let json = "{\"symbol\":\"\(symbol)\",\"qty\":\"10\",\"market_value\":\"\(value)\"}"
        return try! JSONDecoder().decode(AlpacaPosition.self, from: Data(json.utf8))
    }

    private func entryOrder(_ symbol: String) -> AlpacaOrder {
        AlpacaOrder(id: "o1", status: "new", symbol: symbol, side: "buy", type: "limit",
                    quantity: "1", filledQuantity: "0", filledAveragePrice: nil,
                    submittedAt: nil, legs: nil, parentOrderId: nil,
                    stopPrice: nil, limitPrice: "100", clientOrderId: nil)
    }

    // MARK: - Tecnica

    func testTechnicalLongOnAlignedSetup() throws {
        let c = context(
            closes15: Array(repeating: 100.0, count: 40) + [101],
            i15: indicators(rsi14: 55, ema12: 100.9, ema26: 100.5, sma50: 100,
                            sma200: 98, atr14: 0.8, high20: 100.8, low20: 98)
        )
        let report = TechnicalSpecialist.report(symbol: "SPY", context: c)
        XCTAssertEqual(report.signal, .long)
        XCTAssertEqual(report.agent, .technical)
        XCTAssertFalse(report.evidence.isEmpty)
        XCTAssertTrue(report.confidence > 0)
    }

    func testTechnicalShortOnBreakdown() throws {
        let c = context(
            closes15: Array(repeating: 100.0, count: 40) + [95],
            i15: indicators(rsi14: 45, ema12: 96, ema26: 99, sma50: 100,
                            sma200: 102, atr14: 1.2, high20: 100, low20: 95.05)
        )
        let report = TechnicalSpecialist.report(symbol: "SPY", context: c)
        XCTAssertEqual(report.signal, .short)
    }

    func testTechnicalAbstainWithoutData() throws {
        let report = TechnicalSpecialist.report(symbol: "SPY", context: nil)
        XCTAssertEqual(report.signal, .abstain)
        XCTAssertFalse(report.missingData.isEmpty)
    }

    func testTechnicalNeutralOnMixedConditions() throws {
        // Sopra SMA200 (favorevole) ma EMA12<EMA26 su 15m (contrario), RSI
        // fuori zona sana, lontano dai massimi e 1m disallineato: 1 favorevole
        // contro 1 sfavorevole → né long (servono 3) né short (trend su).
        let c = context(
            closes15: Array(repeating: 100.0, count: 40) + [99.5],
            i15: indicators(rsi14: 30, ema12: 99.4, ema26: 99.6, sma50: 100,
                            sma200: 95, atr14: 0.5, high20: 105, low20: 98),
            i1: indicators(rsi14: 50, ema12: 99.8, ema26: 100.2, sma50: 100,
                           sma200: 98, atr14: 0.4, high20: 101, low20: 99)
        )
        let report = TechnicalSpecialist.report(symbol: "SPY", context: c)
        XCTAssertEqual(report.signal, .neutral)
    }

    // MARK: - Quant

    func testQuantLongOnOversoldZScore() throws {
        let closes = Array(repeating: 100.0, count: 19) + [90]
        let c = context(closes15: closes, i15: indicators(sma200: 80))
        let report = QuantSpecialist.report(symbol: "SPY", context: c)
        XCTAssertEqual(report.signal, .long)
        XCTAssertTrue(report.evidence[0].contains("z-score"))
    }

    func testQuantShortOnOverboughtZScore() throws {
        let closes = Array(repeating: 100.0, count: 19) + [110]
        let c = context(closes15: closes, i15: indicators(sma200: 90))
        let report = QuantSpecialist.report(symbol: "SPY", context: c)
        XCTAssertEqual(report.signal, .short)
    }

    func testQuantAbstainWithTooFewCloses() throws {
        let report = QuantSpecialist.report(symbol: "SPY", context: nil)
        XCTAssertEqual(report.signal, .abstain)
    }

    // MARK: - Notizie

    func testNewsLongOnPositiveHeadlines() throws {
        let report = NewsSpecialist.report(symbol: "SPY", headlines: [
            "Company beats earnings expectations",
            "Stock rallies on strong growth"
        ])
        XCTAssertEqual(report.signal, .long)
        XCTAssertEqual(report.agent, .news)
    }

    func testNewsShortOnNegativeHeadlines() throws {
        let report = NewsSpecialist.report(symbol: "SPY", headlines: [
            "Market crash fears grow",
            "Analyst downgrade after guidance miss"
        ])
        XCTAssertEqual(report.signal, .short)
    }

    func testNewsAbstainWithoutHeadlines() throws {
        let report = NewsSpecialist.report(symbol: "SPY", headlines: [])
        XCTAssertEqual(report.signal, .abstain)
        XCTAssertEqual(report.timeframe, "48h")
    }

    func testNewsHeadlinesFromText() {
        let lines = NewsSpecialist.headlines(from: "Titolo uno\n\nTitolo due\n")
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 2)
    }

    // MARK: - Fondamentali

    func testFundamentalAlwaysAbstains() throws {
        let report = FundamentalSpecialist.report(symbol: "SPY")
        XCTAssertEqual(report.signal, .abstain)
        XCTAssertEqual(report.confidence, 0)
        XCTAssertFalse(report.missingData.isEmpty)
    }

    // MARK: - Portafoglio

    func testPortfolioShortWhenSymbolAlreadyHeld() throws {
        let report = PortfolioSpecialist.report(symbol: "SPY",
                                                positions: [position("SPY", value: 5_000)],
                                                openOrders: [], botEquity: 10_000,
                                                maxOpenPositions: 5)
        XCTAssertEqual(report.signal, .short)
    }

    func testPortfolioShortWhenCapReached() throws {
        let report = PortfolioSpecialist.report(symbol: "XLF",
                                                positions: [position("SPY", value: 5_000)],
                                                openOrders: [entryOrder("QQQ")],
                                                botEquity: 10_000,
                                                maxOpenPositions: 2)
        XCTAssertEqual(report.signal, .short)
    }

    func testPortfolioLongWhenSlotFree() throws {
        let report = PortfolioSpecialist.report(symbol: "XLF",
                                                positions: [],
                                                openOrders: [],
                                                botEquity: 10_000,
                                                maxOpenPositions: 5)
        XCTAssertEqual(report.signal, .long)
        XCTAssertEqual(report.confidence, 0.9, accuracy: 1e-9)
    }

    func testPortfolioFlagsFamilyOverlap() throws {
        let report = PortfolioSpecialist.report(symbol: "VOO",
                                                positions: [position("SPY", value: 2_000)],
                                                openOrders: [], botEquity: 10_000,
                                                maxOpenPositions: 5)
        XCTAssertEqual(report.signal, .long)
        XCTAssertTrue(report.risks.contains { $0.contains("SPY") })
    }

    // MARK: - Divergenze

    private func report(_ signal: CouncilSignal, agent: CouncilAgentID = .technical) -> AgentReport {
        AgentReport(agent: agent, timestamp: start, asset: "SPY", timeframe: "15m",
                    analysis: "test", signal: signal, confidence: 0.5,
                    evidence: ["e"], invalidation: "i")
    }

    func testDivergenceStrongWhenLongAndShortCoexist() throws {
        let assessment = CouncilDivergence.assess([report(.long), report(.short, agent: .quantitative)])
        XCTAssertTrue(assessment.strong)
        XCTAssertNotNil(assessment.note)
        XCTAssertEqual(assessment.favorable, [.technical])
        XCTAssertEqual(assessment.adverse, [.quantitative])
    }

    func testDivergenceNilWhenCouncilAgrees() throws {
        let assessment = CouncilDivergence.assess([report(.long), report(.neutral, agent: .quantitative)])
        XCTAssertNil(assessment.note)
        XCTAssertFalse(assessment.strong)
    }

    func testDivergenceNotesAdverseCouncil() throws {
        let assessment = CouncilDivergence.assess([report(.short), report(.abstain, agent: .news)])
        XCTAssertNotNil(assessment.note)
        XCTAssertFalse(assessment.strong)
    }

    // MARK: - Consiglio veloce e digest giornaliero

    func testFastModeReportsContainAllLocalSpecialists() throws {
        let reports = Council.fastModeReports(
            symbol: "SPY", context: nil, newsText: "", positions: [],
            openOrders: [], botEquity: 10_000, maxOpenPositions: 5
        )
        XCTAssertEqual(Set(reports.map(\.agent)), [.technical, .quantitative, .news, .fundamental, .portfolio])
        // Nessun campo vuoto: formato standard anche quando mancano i dati.
        for report in reports {
            XCTAssertFalse(report.analysis.isEmpty)
            XCTAssertFalse(report.invalidation.isEmpty)
        }
    }

    func testDailyDigestJudgesCandidate() throws {
        let candidate = DailyStrategy.Candidate(
            symbol: "SPY",
            snapshot: .init(close: 100, sma200: 90, sma5: 96, rsi2: 8, atr14: 2),
            recentCloses: Array(repeating: 100.0, count: 9) + [98],
            news: ["Fed decision expected this week"]
        )
        let digest = Council.dailyDigest(for: candidate)
        XCTAssertEqual(digest.count, 4)
        XCTAssertEqual(digest[0].signal, .long) // tecnica: pullback sopra SMA200
        XCTAssertEqual(digest[0].agent, .technical)
        XCTAssertEqual(digest[3].signal, .abstain) // fondamentali: nessuna API
    }

    // MARK: - Pagella

    func testScorecardMathAndNeutralsNotJudged() throws {
        let entries: [(reports: [AgentReport], outcomeMovePct: Double)] = [
            ([report(.long)], +1.0),      // vinto
            ([report(.short)], -2.0),     // vinto
            ([report(.short)], +1.0),     // perso
            ([report(.neutral)], +5.0),   // non giudicato
            ([report(.abstain, agent: .news)], -5.0), // non giudicato
        ]
        let cards = AgentScorecard.scorecards(from: entries)
        let technical = cards.first { $0.agent == .technical }
        XCTAssertEqual(technical?.judged, 3)
        XCTAssertEqual(technical?.hits, 2)
        XCTAssertNil(technical?.hitRate) // servono almeno 5 giudizi
        XCTAssertTrue(cards.allSatisfy { $0.agent != .news }) // news mai giudicato
    }

    func testScorecardHitRateWithFiveJudgments() throws {
        let entries: [(reports: [AgentReport], outcomeMovePct: Double)] =
            (0..<5).map { _ in ([report(.long)], +1.0) }
        let cards = AgentScorecard.scorecards(from: entries)
        XCTAssertEqual(cards.first?.judged, 5)
        XCTAssertEqual(cards.first?.hitRate ?? 0, 1.0, accuracy: 1e-9)
    }

    // MARK: - Payload per Kimi

    func testSpecialistPayloadIsCompactAndComplete() throws {
        let r = AgentReport(
            agent: .quantitative, timestamp: start, asset: "SPY", timeframe: "15m",
            analysis: "analisi", signal: .short, confidence: 0.75,
            evidence: ["e1", "e2", "e3", "e4", "e5"], risks: ["r1", "r2", "r3"],
            missingData: ["m1"], invalidation: "inv"
        )
        let payload = KimiService.specialistPayload([r])
        XCTAssertEqual(payload.count, 1)
        let item = try XCTUnwrap(payload.first)
        XCTAssertEqual(item["agent"] as? String, "quantitative")
        XCTAssertEqual(item["signal"] as? String, "short")
        XCTAssertEqual((item["evidence"] as? [String])?.count, 3) // troncato a 3
        XCTAssertEqual((item["risks"] as? [String])?.count, 2)    // troncato a 2
        XCTAssertEqual(item["missing_data_count"] as? Int, 1)
        XCTAssertEqual(item["invalidation"] as? String, "inv")
        XCTAssertEqual(item["abstained"] as? Bool, false)
    }

    // MARK: - Memoria (CouncilRecord)

    @available(iOS 17, *)
    func testCouncilRecordRoundTripsReportsAndDivergence() throws {
        let decision = KimiDecision(
            symbol: "SPY", action: .hold, confidence: 0.6, entryPrice: 100,
            stopLoss: 98, takeProfit: 105, winProbability: 0.5, payoffRatio: 2.5,
            rationale: "dati misti"
        )
        let divergence = CouncilDivergence.assess([report(.long), report(.short, agent: .quantitative)])
        let record = CouncilRecord(
            reports: [report(.long, agent: .portfolio)],
            divergence: divergence,
            decision: decision,
            price: 100
        )
        XCTAssertEqual(record.action, "hold")
        XCTAssertEqual(record.reports.count, 1)
        XCTAssertEqual(record.reports.first?.agent, .portfolio)
        XCTAssertEqual(record.divergence?.strong, true)
        XCTAssertEqual(record.divergence?.adverse, [.quantitative])
        XCTAssertFalse(record.evaluated)
        XCTAssertNil(record.outcomeMovePct)
    }
}
