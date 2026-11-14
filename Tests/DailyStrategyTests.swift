import XCTest
@testable import QuantSwarmAlphaZero

/// Test della modalità giornaliera (Trend + Pullback) e del dimensionamento
/// con solo stop. Girano a ogni build: se falliscono, niente IPA.
final class DailyStrategyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01 12:00 UTC

    private func bars(_ closes: [Double]) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(
                timestamp: start.addingTimeInterval(Double(index) * 86_400),
                open: close, high: close * 1.005, low: close * 0.995, close: close, volume: 1_000
            )
        }
    }

    /// Trend rialzista lungo, poi 3 giorni di ribasso: pullback in trend.
    private var pullbackInUptrend: [Double] {
        (0..<247).map { 100 + 0.2 * Double($0) } + [146.0, 144.0, 142.0]
    }

    func testEntryOnPullbackInUptrend() throws {
        let candidate = try XCTUnwrap(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(pullbackInUptrend)))
        XCTAssertGreaterThan(candidate.snapshot.close, candidate.snapshot.sma200)
        XCTAssertLessThan(candidate.snapshot.rsi2, DailyStrategy.rsiEntryThreshold)
        XCTAssertEqual(candidate.stopDistance, DailyStrategy.stopATR * candidate.snapshot.atr14, accuracy: 1e-9)
    }

    func testNoEntryBelowSMA200() {
        let falling = (0..<250).map { 200 - 0.3 * Double($0) }
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(falling)))
    }

    func testNoEntryWithoutPullback() {
        let rising = (0..<250).map { 100 + 0.2 * Double($0) }
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(rising)))
    }

    func testNoEntryWithTooFewBars() {
        XCTAssertNil(DailyStrategy.entryCandidate(symbol: "SPY", bars: bars(Array(pullbackInUptrend.suffix(150)))))
    }

    func testExitWhenCloseAboveSMA5() {
        let series = pullbackInUptrend + [150.0]
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        XCTAssertEqual(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay), .aboveSMA5)
    }

    func testStayInWhileBelowSMA5AndUnderTimeLimit() {
        let series = pullbackInUptrend + [141.5]
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        XCTAssertNil(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay))
    }

    func testExitAfterTenTradingDays() {
        // 10 giorni sempre in leggero calo: mai sopra SMA5, esce a tempo
        let series = pullbackInUptrend + (1...10).map { 142.0 - 0.1 * Double($0) }
        let entryDay = DailyStrategy.tradingDay(start.addingTimeInterval(250 * 86_400))
        XCTAssertEqual(DailyStrategy.exitReason(bars: bars(series), entryDay: entryDay), .timeLimit)
    }

    func testFormingBarDroppedWhileMarketOpen() {
        let now = Date()
        let candles = [
            Candle(timestamp: now.addingTimeInterval(-86_400 * 2), open: 1, high: 1, low: 1, close: 1, volume: 1),
            Candle(timestamp: now, open: 1, high: 1, low: 1, close: 1, volume: 1)
        ]
        XCTAssertEqual(DailyStrategy.closedBars(candles, now: now, marketOpen: true).count, 1)
        XCTAssertEqual(DailyStrategy.closedBars(candles, now: now, marketOpen: false).count, 2)
    }

    func testDailyBookRemembersDecisionsOnlyForToday() {
        var book = DailyBook()
        book.markDecided("SPY", day: "2026-11-10")
        XCTAssertTrue(book.alreadyDecided("SPY", day: "2026-11-10"))
        XCTAssertFalse(book.alreadyDecided("SPY", day: "2026-11-11"))
        book.markDecided("QQQ", day: "2026-11-11")
        XCTAssertFalse(book.alreadyDecided("SPY", day: "2026-11-11"))
    }

    func testShadowResolvesOnFirstCloseAboveSMA5() throws {
        let series = pullbackInUptrend + [141.0, 150.0, 151.0]
        let candles = bars(series)
        let day = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        let entry = ShadowEntry(symbol: "SPY", day: day, entry: 142, stop: 130, outcome: ShadowEntry.brainSkip)
        let exit = try XCTUnwrap(ShadowEvaluator.resolve(entry, bars: candles))
        XCTAssertEqual(exit.price, 150, accuracy: 1e-9)
    }

    func testShadowResolvesOnStop() throws {
        let series = pullbackInUptrend + [120.0]
        let day = DailyStrategy.tradingDay(start.addingTimeInterval(249 * 86_400))
        let entry = ShadowEntry(symbol: "SPY", day: day, entry: 142, stop: 135, outcome: ShadowEntry.bought)
        let exit = try XCTUnwrap(ShadowEvaluator.resolve(entry, bars: bars(series)))
        XCTAssertEqual(exit.price, 120, accuracy: 1e-9, "Gap sotto lo stop: esce all'apertura")
    }

    func testShadowSummaryComparesChosenAndSkipped() {
        var a = ShadowEntry(symbol: "SPY", day: "d", entry: 100, stop: 90, outcome: ShadowEntry.bought)
        a.exitPrice = 102
        var b = ShadowEntry(symbol: "QQQ", day: "d", entry: 100, stop: 90, outcome: ShadowEntry.brainSkip)
        b.exitPrice = 99
        let summary = ShadowSummary.from([a, b])
        XCTAssertEqual(summary.chosenAverage ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(summary.skippedAverage ?? 0, -0.01, accuracy: 1e-9)
        XCTAssertNil(summary.feedbackText, "Con meno di 3 esiti niente feedback a Kimi")
    }

    func testBasketHasNoDuplicates() {
        XCTAssertEqual(Set(DailyStrategy.basket).count, DailyStrategy.basket.count)
    }

    // MARK: - Dimensionamento con solo stop

    private let account = RiskRules.Account(equity: 100_000, cash: 100_000, buyingPower: 400_000)

    func testStopOnlySizingRespectsRiskAndCap() throws {
        let result = try RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 12.5, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ).get()
        XCTAssertLessThanOrEqual(result.riskAmount, 1_000 + 1e-6)
        XCTAssertLessThanOrEqual(result.quantity * result.limitPrice, 25_000 + 1e-6)
        XCTAssertLessThan(result.stopPrice, result.limitPrice)
        XCTAssertEqual(result.quantity, result.quantity.rounded(.down))
    }

    func testStopOnlySizingRejectsInvalidInput() {
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 0, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Stop nullo: va rifiutato") }
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 10, stopDistance: 20, account: account,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Stop sotto zero: va rifiutato") }
    }

    func testStopOnlySizingTooSmallAccount() {
        let tiny = RiskRules.Account(equity: 100, cash: 100, buyingPower: 100)
        if case .success = RiskRules.sizeStopOnly(
            currentPrice: 500, stopDistance: 12.5, account: tiny,
            riskFraction: 0.01, constraints: .alpacaStock
        ) { XCTFail("Meno di un'azione: va rifiutato") }
    }

    func testDefaultModeIsPortfolio() {
        XCTAssertEqual(StrategyConfig().tradingMode, .portfolio)
        let legacy = try? JSONDecoder().decode(StrategyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy?.tradingMode, .portfolio)
        XCTAssertEqual(legacy?.widgetShowsAmounts, false, "Importi nel widget nascosti di default")
    }
}

final class CorrelationTests: XCTestCase {
    private func series(_ f: (Int) -> Double, count: Int = 80) -> [Candle] {
        let start = Date(timeIntervalSince1970: 1_735_732_800)
        return (0..<count).map { i in
            let c = f(i)
            return Candle(timestamp: start.addingTimeInterval(Double(i) * 86_400), open: c, high: c, low: c, close: c, volume: 1)
        }
    }

    func testIdenticalAndOppositeMoves() throws {
        let a = series { 100 + sin(Double($0)) * 3 + Double($0) * 0.1 }
        let b = series { 50 + sin(Double($0)) * 1.5 + Double($0) * 0.05 }
        XCTAssertEqual(try XCTUnwrap(DailyStrategy.correlation(a, b)), 1, accuracy: 0.05)
        let c = series { 100 - sin(Double($0)) * 3 }
        XCTAssertLessThan(try XCTUnwrap(DailyStrategy.correlation(a, c)), -0.8)
    }

    func testNotEnoughCommonDays() {
        let a = series({ 100 + Double($0) }, count: 15)
        XCTAssertNil(DailyStrategy.correlation(a, a))
    }

    // MARK: - Prova in ombra proposta 22: ordine a regole + IC bootstrap

    /// Candidato finto con RSI2 e correlazioni a piacere: per l'ordinamento
    /// contano solo quelle chiavi.
    private func rulesCandidate(_ symbol: String, rsi2: Double, correlations: [String: Double] = [:]) -> DailyStrategy.Candidate {
        DailyStrategy.Candidate(
            symbol: symbol,
            snapshot: DailyStrategy.Snapshot(close: 100, sma200: 90, sma5: 101, rsi2: rsi2, atr14: 2),
            recentCloses: [],
            correlations: correlations
        )
    }

    func testRulesOrderRanksByRsi2ThenCorrelationThenSymbol() {
        let deep = rulesCandidate("QQQ", rsi2: 2)
        let mid = rulesCandidate("IWM", rsi2: 5)
        let shallow = rulesCandidate("SPY", rsi2: 9)
        XCTAssertEqual(RulesOrder.rank([shallow, mid, deep], heldSymbols: []).map(\.symbol),
                       ["QQQ", "IWM", "SPY"],
                       "RSI2 più basso primo: il pullback più profondo è il migliore")

        // Parità di RSI2: vince la correlazione più bassa verso le posizioni aperte.
        let twins = [
            rulesCandidate("TLT", rsi2: 4, correlations: ["SPY": 0.9]),
            rulesCandidate("GLD", rsi2: 4, correlations: ["SPY": -0.8]),
        ]
        XCTAssertEqual(RulesOrder.rank(twins, heldSymbols: ["SPY"]).map(\.symbol),
                       ["GLD", "TLT"],
                       "a parità di RSI2 conta il valore assoluto: -0,8 pesa come 0,9")

        // Parità anche lì: correlazione con gli altri candidati, poi simbolo.
        let equal = [
            rulesCandidate("QQQ", rsi2: 4, correlations: ["SPY": 0.5, "IWM": 0.9]),
            rulesCandidate("IWM", rsi2: 4, correlations: ["SPY": 0.5, "QQQ": 0.9]),
        ]
        XCTAssertEqual(RulesOrder.rank(equal, heldSymbols: ["SPY"]).map(\.symbol),
                       ["IWM", "QQQ"],
                       "parità totale: ordine alfabetico, deterministico")
    }

    func testRulesOrderPicksRespectSlots() {
        let list = [rulesCandidate("SPY", rsi2: 9), rulesCandidate("QQQ", rsi2: 2), rulesCandidate("IWM", rsi2: 5)]
        XCTAssertEqual(RulesOrder.picks(list, heldSymbols: [], slots: 2), Set(["QQQ", "IWM"]))
        XCTAssertEqual(RulesOrder.picks(list, heldSymbols: [], slots: 5), Set(["QQQ", "IWM", "SPY"]))
        XCTAssertEqual(RulesOrder.picks(list, heldSymbols: [], slots: 0), Set<String>(),
                       "senza posti liberi l'ordine a regole non comprerebbe niente")
    }

    func testBootstrapIntervalIsDeterministicWithFixedSeed() throws {
        let a: [Double] = [0.010, -0.020, 0.030, 0.005, -0.001, 0.020, -0.005, 0.015, -0.010, 0.002]
        let b: [Double] = [0.004, -0.001, 0.008, -0.006, 0.002, -0.003, 0.001, 0.006, -0.002, 0.0005]
        var aByDay: [String: [Double]] = [:]
        var bByDay: [String: [Double]] = [:]
        for (index, value) in a.enumerated() { aByDay["d\(index)"] = [value] }
        for (index, value) in b.enumerated() { bByDay["d\(index)"] = [value] }
        let interval = try XCTUnwrap(ShadowBootstrap.interval95ByDay(aByDay, bByDay))
        // Valori attesi calcolati con la STESSA procedura (SplitMix64, seed 42,
        // 5000 ricampionamenti di GIORNI interi, percentili 2,5-97,5): il test
        // inchioda l'algoritmo in-app a quello usato per il banco di prova.
        XCTAssertEqual(interval.low, -0.00415, accuracy: 1e-9)
        XCTAssertEqual(interval.high, 0.0115, accuracy: 1e-9)
        // Un giorno presente solo su un lato: i resample che restano senza
        // valori per un lato si scartano (187 su 5000), l'intervallo resta
        // calcolabile e i percentili si prendono sui resample VALIDI.
        let second = try XCTUnwrap(ShadowBootstrap.interval95ByDay(
            ["d0": [0.02], "d1": [-0.01], "d2": [0.03]], ["d0": [0.001], "d1": [-0.002]]))
        XCTAssertEqual(second.low, -0.008, accuracy: 1e-9)
        XCTAssertEqual(second.high, 0.0256666667, accuracy: 1e-9)
        XCTAssertNil(ShadowBootstrap.interval95ByDay([:], bByDay), "un lato vuoto non dà intervallo")
    }

    func testShadowSummaryPagellaOrdineARegole() {
        var entries: [ShadowEntry] = []
        // 32 voci che l'ordine a regole avrebbe comprato, +2% ciascuna;
        // 30 di queste le aveva comprate anche il Brain (esiti "comprato").
        for index in 0..<32 {
            var e = ShadowEntry(symbol: "P\(index)", day: "d\(index)", entry: 100, stop: 90,
                                outcome: index < 30 ? ShadowEntry.bought : ShadowEntry.brainSkip)
            e.rulesPick = true
            e.exitPrice = 102
            e.exitDay = "e\(index)"
            entries.append(e)
        }
        // 31 voci che l'ordine a regole avrebbe saltato, +1% ciascuna.
        for index in 0..<31 {
            var e = ShadowEntry(symbol: "N\(index)", day: "d\(index)", entry: 100, stop: 90,
                                outcome: ShadowEntry.brainSkip)
            e.rulesPick = false
            e.exitPrice = 101
            e.exitDay = "e\(index)"
            entries.append(e)
        }
        // Voce storica senza flag: fuori dalla pagella dell'ordine a regole,
        // dentro tutti gli altri conti.
        var old = ShadowEntry(symbol: "OLD", day: "z", entry: 100, stop: 90, outcome: ShadowEntry.brainSkip)
        old.exitPrice = 150
        old.exitDay = "z1"
        entries.append(old)

        let summary = ShadowSummary.from(entries)
        XCTAssertEqual(summary.rulesPicked.count, 32)
        XCTAssertEqual(summary.rulesNotPicked.count, 31, "la voce senza flag non entra nella pagella a regole")
        XCTAssertEqual(summary.rules.count, 64, "ma resta in tutti i segnali delle regole")
        XCTAssertEqual(summary.rulesOrderEdge ?? 0, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.rulesVsBrainEdge ?? 1, 0, accuracy: 1e-12)
        // Serie costanti: l'IC della differenza è un punto (0,01).
        XCTAssertEqual(summary.rulesOrderInterval?.low ?? -1, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.rulesOrderInterval?.high ?? -1, 0.01, accuracy: 1e-12)
        // Disaccordi: le 2 voci picked non comprate sono "solo regole",
        // nessuna "solo catena": sotto la soglia di 30 per lato, niente IC.
        XCTAssertEqual(summary.rulesOnly.count, 2)
        XCTAssertEqual(summary.chainOnly.count, 0)
        XCTAssertNil(summary.disagreementInterval, "sotto la soglia di 30 per lato niente IC")
        // Reviewer: i 30 comprati sono i "non bocciati", ma nessun bocciato:
        // l'IC del veto resta nil finché entrambi i lati non hanno 30 esiti.
        XCTAssertEqual(summary.reviewerApproved.count, 30)
        XCTAssertEqual(summary.reviewerRejected.count, 0)
        XCTAssertNil(summary.reviewerInterval)

        // Sotto la soglia di 30 esiti per lato: pagella sì, intervallo no.
        var few: [ShadowEntry] = []
        for index in 0..<10 {
            var picked = ShadowEntry(symbol: "p\(index)", day: "d\(index)", entry: 100, stop: 90,
                                      outcome: ShadowEntry.bought)
            picked.rulesPick = true
            picked.exitPrice = 103
            picked.exitDay = "e"
            few.append(picked)
            var skipped = ShadowEntry(symbol: "n\(index)", day: "d\(index)", entry: 100, stop: 90,
                                      outcome: ShadowEntry.brainSkip)
            skipped.rulesPick = false
            skipped.exitPrice = 99
            skipped.exitDay = "e"
            few.append(skipped)
        }
        let small = ShadowSummary.from(few)
        XCTAssertEqual(small.rulesPicked.count, 10)
        XCTAssertEqual(small.rulesNotPicked.count, 10)
        XCTAssertNil(small.rulesOrderInterval, "senza 30 esiti per lato niente IC: i numeri sono rumore")
        XCTAssertNil(small.disagreementInterval)
        XCTAssertNil(small.reviewerInterval)
    }

    func testShadowSummaryDisaccordiRegoleCatenaEReviewer() {
        var entries: [ShadowEntry] = []
        // 30 giorni: in ognuno le regole avrebbero comprato ma la catena Kimi
        // no (+2%), la catena ha comprato ma le regole no (+0,5%), e il
        // Reviewer ha bocciato una terza voce (+0,1%, senza flag: fuori dai
        // gruppi dell'ordine a regole, dentro quelli del Reviewer).
        for index in 0..<30 {
            var rulesOnly = ShadowEntry(symbol: "R\(index)", day: "dd\(index)", entry: 100, stop: 90,
                                         outcome: ShadowEntry.brainSkip)
            rulesOnly.rulesPick = true
            rulesOnly.exitPrice = 102
            rulesOnly.exitDay = "x"
            entries.append(rulesOnly)
            var chainOnly = ShadowEntry(symbol: "C\(index)", day: "dd\(index)", entry: 100, stop: 90,
                                        outcome: ShadowEntry.bought)
            chainOnly.rulesPick = false
            chainOnly.exitPrice = 100.5
            chainOnly.exitDay = "x"
            entries.append(chainOnly)
            var rejected = ShadowEntry(symbol: "V\(index)", day: "dd\(index)", entry: 100, stop: 90,
                                       outcome: ShadowEntry.reviewerReject)
            rejected.exitPrice = 100.1
            rejected.exitDay = "x"
            entries.append(rejected)
        }
        let summary = ShadowSummary.from(entries)
        XCTAssertEqual(summary.rulesOnly.count, 30)
        XCTAssertEqual(summary.chainOnly.count, 30)
        XCTAssertEqual(summary.reviewerApproved.count, 30, "i comprati davvero sono i buy non bocciati dal Reviewer")
        XCTAssertEqual(summary.reviewerRejected.count, 30)
        XCTAssertEqual(summary.rulesVsBrainEdge ?? 0, 0.015, accuracy: 1e-12)
        // Serie costanti per giorno: ogni IC della differenza è un punto
        // (0,02 − 0,005 = 0,015 per i disaccordi, 0,005 − 0,001 = 0,004
        // per il Reviewer).
        XCTAssertEqual(summary.disagreementInterval?.low ?? -1, 0.015, accuracy: 1e-12)
        XCTAssertEqual(summary.disagreementInterval?.high ?? -1, 0.015, accuracy: 1e-12)
        XCTAssertEqual(summary.reviewerInterval?.low ?? -1, 0.004, accuracy: 1e-12)
        XCTAssertEqual(summary.reviewerInterval?.high ?? -1, 0.004, accuracy: 1e-12)
        // Sotto la soglia (29 per lato): pagella sì, IC no.
        var fewer: [ShadowEntry] = []
        for index in 0..<29 {
            var rulesOnly = ShadowEntry(symbol: "R\(index)", day: "dd\(index)", entry: 100, stop: 90,
                                         outcome: ShadowEntry.brainSkip)
            rulesOnly.rulesPick = true
            rulesOnly.exitPrice = 102
            rulesOnly.exitDay = "x"
            fewer.append(rulesOnly)
            var chainOnly = ShadowEntry(symbol: "C\(index)", day: "dd\(index)", entry: 100, stop: 90,
                                        outcome: ShadowEntry.bought)
            chainOnly.rulesPick = false
            chainOnly.exitPrice = 100.5
            chainOnly.exitDay = "x"
            fewer.append(chainOnly)
        }
        let almost = ShadowSummary.from(fewer)
        XCTAssertEqual(almost.rulesOnly.count, 29)
        XCTAssertEqual(almost.chainOnly.count, 29)
        XCTAssertNil(almost.disagreementInterval, "con 29 esiti per lato l'IC non compare: servono 30")
    }
}
