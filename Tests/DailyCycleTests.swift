import XCTest
@testable import QuantSwarmAlphaZero

// MARK: - Finti broker e Kimi

private struct FakeError: Error {}

actor FakeBroker: BrokerClient {
    var marketOpen = true
    var brokerDown = false
    var acct = BrokerAccount(equity: 100_000, cash: 100_000, buyingPower: 400_000)
    var heldPositions: [BrokerPosition] = []
    var orders: [BrokerOrder] = []
    var bars: [String: [Candle]] = [:]
    var price: Double = 142
    var failClose = false
    var timeoutButCreated = false
    /// Bug B4: l'ordine creato prima del timeout viene poi rifiutato dal broker.
    var rejectedRecovered = false
    var newsItems: [NewsHeadline] = []
    func news(symbols: [String], hours: Int) async throws -> [NewsHeadline] { newsItems }
    func set(news: [NewsHeadline]) { newsItems = news }

    var entryCalls: [(symbol: String, qty: Double, limit: Double, stop: Double)] = []
    var stopCalls: [(symbol: String, qty: Double, stop: Double)] = []
    var cancelled: [String] = []
    var closed: [String] = []
    var created: [String: String] = [:]

    init(bars: [String: [Candle]]) { self.bars = bars }

    func set(positions: [BrokerPosition]) { heldPositions = positions }
    func set(orders: [BrokerOrder]) { self.orders = orders }
    func set(marketOpen: Bool) { self.marketOpen = marketOpen }
    func set(failClose: Bool) { self.failClose = failClose }
    func set(timeoutButCreated: Bool) { self.timeoutButCreated = timeoutButCreated }
    func set(rejectedRecovered: Bool) { self.rejectedRecovered = rejectedRecovered }
    /// true simula lo STOP del motore durante il ciclo (CancellationError).
    var cancelDuringScout = false

    func set(brokerDown: Bool) { self.brokerDown = brokerDown }
    func set(cancelDuringScout: Bool) { self.cancelDuringScout = cancelDuringScout }

    func isMarketOpen() async throws -> Bool {
        if cancelDuringScout { throw CancellationError() }
        if brokerDown { throw FakeError() }
        return marketOpen
    }
    func account() async throws -> BrokerAccount { acct }
    func positions() async throws -> [BrokerPosition] { heldPositions }
    func openOrders() async throws -> [BrokerOrder] { orders }
    func dailyBars(symbol: String) async throws -> [Candle] {
        guard let b = bars[symbol] else { throw FakeError() }
        return b
    }
    func latestPrice(symbol: String) async throws -> Double { price }
    func cancelOrder(id: String) async throws {
        cancelled.append(id)
        // Annullare un ordine annulla anche le sue gambe.
        orders.removeAll { $0.id == id || $0.parentOrderId == id }
    }
    func closePosition(symbol: String) async throws -> String? {
        if failClose { throw FakeError() }
        closed.append(symbol)
        heldPositions.removeAll { $0.symbol == symbol }
        return "close-\(symbol)"
    }
    var lastTakeProfit: Double?

    func submitEntryWithStop(symbol: String, quantity: Double, limitPrice: Double,
                             stopPrice: Double, takeProfitPrice: Double?, clientOrderId: String) async throws -> String {
        entryCalls.append((symbol, quantity, limitPrice, stopPrice))
        lastTakeProfit = takeProfitPrice
        let id = "entry-\(entryCalls.count)"
        if timeoutButCreated {
            created[clientOrderId] = id
            throw URLError(.timedOut)
        }
        return id
    }
    func submitStop(symbol: String, quantity: Double, stopPrice: Double) async throws -> String {
        stopCalls.append((symbol, quantity, stopPrice))
        return "stop-\(stopCalls.count)"
    }
    func orderRef(byClientOrderId clientOrderId: String) async throws -> BrokerOrderRef? {
        created[clientOrderId].map { BrokerOrderRef(id: $0, status: rejectedRecovered ? "rejected" : "new") }
    }
    func filledAveragePrice(orderId: String) async throws -> Double? { price }
}

actor FakeBrain: DailyBrain {
    var decideError = false
    var reviewApproves = true
    var decideCalls = 0
    var reviewCalls = 0
    var lastCandidates: [DailyStrategy.Candidate] = []

    func set(decideError: Bool) { self.decideError = decideError }
    func set(reviewApproves: Bool) { self.reviewApproves = reviewApproves }

    func decide(candidates: [DailyStrategy.Candidate], market: [String: DailyStrategy.Snapshot],
                openPositions: [String], slots: Int, feedback: String?,
                shadow: ShadowDigest?) async throws -> [DailyVerdict] {
        decideCalls += 1
        lastCandidates = candidates
        if decideError { throw FakeError() }
        return candidates.map { DailyVerdict(symbol: $0.symbol, action: "buy", confidence: 0.8, rationale: "test") }
    }

    func review(candidate: DailyStrategy.Candidate, verdict: DailyVerdict,
                market: [String: DailyStrategy.Snapshot], shadow: ShadowDigest?) async throws -> KimiReview {
        reviewCalls += 1
        return KimiReview(verdict: reviewApproves ? "approve" : "reject", reason: "test")
    }
}

// MARK: - Test

final class DailyCycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_735_732_800)
    private let today = "2026-11-10"

    private func candles(_ closes: [Double]) -> [Candle] {
        closes.enumerated().map { index, close in
            Candle(timestamp: start.addingTimeInterval(Double(index) * 86_400),
                   open: close, high: close * 1.005, low: close * 0.995, close: close, volume: 1_000)
        }
    }

    /// Trend lungo + 3 giorni di ribasso: segnale d'ingresso, chiusura sotto SMA5.
    private var pullback: [Candle] { candles((0..<247).map { 100 + 0.2 * Double($0) } + [146, 144, 142]) }
    /// Sempre in salita: nessun segnale e chiusura sopra SMA5 (uscita).
    private var rising: [Candle] { candles((0..<250).map { 100 + 0.2 * Double($0) }) }

    private func input(book: DailyBook = DailyBook(), block: String? = nil) -> DailyCycleInput {
        DailyCycleInput(book: book, today: today, riskFraction: 0.01, maxOpenPositions: 3, entryBlock: block)
    }

    private func runner(_ broker: FakeBroker, _ brain: FakeBrain) -> DailyCycleRunner {
        DailyCycleRunner(broker: broker, brain: brain, basket: ["SPY"], exitFillWaitSeconds: 0)
    }

    private func position(_ qty: Double = 10, entry: Double = 140) -> BrokerPosition {
        BrokerPosition(symbol: "SPY", quantity: qty, averageEntryPrice: entry, unrealizedPL: 0)
    }

    private func stopOrder(_ qty: Double = 10, stop: Double = 135) -> BrokerOrder {
        BrokerOrder(id: "s1", symbol: "SPY", side: "sell", type: "stop", status: "new", quantity: qty,
                    filledQuantity: 0, stopPrice: stop, parentOrderId: "p1", submittedAt: nil)
    }

    private func bookWithSPY(day: String = "2026-11-03", stop: Double = 135) -> DailyBook {
        var book = DailyBook()
        book.entries["SPY"] = day
        book.stops["SPY"] = stop
        return book
    }

    func testNoSignalMeansZeroKimiCalls() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(input()) { _ in }
        XCTAssertEqual(result.kimiCalls, 0)
        let calls = await brain.decideCalls
        XCTAssertEqual(calls, 0)
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 0)
    }

    func testBrokerDownAbortsWithoutKimi() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(brokerDown: true)
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(input()) { _ in }
        XCTAssertTrue(result.aborted)
        let calls = await brain.decideCalls
        XCTAssertEqual(calls, 0)
    }

    func testStopDuringCycleIsNotLoggedAsBrokerError() async {
        // STOP del motore durante il ciclo: CancellationError, NON un errore
        // del broker. Prima il catch generico lo loggava come "broker non
        // raggiungibile" (righe false nel log alla chiusura sessione).
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(cancelDuringScout: true)
        let brain = FakeBrain()
        let sink = LogSink()
        let result = await runner(broker, brain).run(input()) { event in
            if let message = event.log { await sink.add(message) }
        }
        let logs = await sink.all()
        XCTAssertTrue(result.aborted)
        XCTAssertTrue(logs.isEmpty, "lo STOP non va loggato come errore broker: \(logs)")
        let calls = await brain.decideCalls
        XCTAssertEqual(calls, 0)
    }

    func testEntryBlockSkipsKimi() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(input(block: "stop giornaliero attivo")) { _ in }
        XCTAssertEqual(result.kimiCalls, 0)
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 0)
    }

    func testBrainFailureMeansNoOrders() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        await brain.set(decideError: true)
        let result = await runner(broker, brain).run(input()) { _ in }
        XCTAssertTrue(result.orders.isEmpty)
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 0)
    }

    func testReviewerRejectionMeansNoOrders() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        await brain.set(reviewApproves: false)
        let result = await runner(broker, brain).run(input()) { _ in }
        XCTAssertTrue(result.orders.isEmpty)
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 0)
        XCTAssertEqual(result.kimiCalls, 2)
    }

    func testApprovedSignalPlacesOrderWithStopWithinRisk() async throws {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(input()) { _ in }
        XCTAssertEqual(result.orders.count, 1)
        let order = try XCTUnwrap(result.orders.first)
        XCTAssertLessThan(order.stopPrice, order.limitPrice)
        XCTAssertLessThanOrEqual((order.limitPrice - order.stopPrice) * order.quantity, 1_000 + 1e-6)
        XCTAssertLessThanOrEqual(order.quantity * order.limitPrice, 25_000 + 1e-6)
        XCTAssertEqual(result.book.entries["SPY"], today)
        XCTAssertEqual(result.book.stops["SPY"] ?? 0, order.stopPrice, accuracy: 1e-9)
        XCTAssertTrue(result.book.alreadyDecided("SPY", day: today))
        let tp = await broker.lastTakeProfit
        XCTAssertGreaterThan(tp ?? 0, order.limitPrice, "Il take-profit deve stare sopra l'ingresso")
        XCTAssertEqual(result.book.placedEntries, 1)
        XCTAssertEqual(result.book.shadow.last?.outcome, ShadowEntry.bought)
    }

    func testShadowRecordsReviewerRejection() async {
        let brain = FakeBrain()
        await brain.set(reviewApproves: false)
        let result = await runner(FakeBroker(bars: ["SPY": pullback]), brain).run(input()) { _ in }
        XCTAssertEqual(result.book.shadow.count, 1)
        XCTAssertEqual(result.book.shadow.first?.outcome, ShadowEntry.reviewerReject)
        XCTAssertEqual(result.book.shadow.first?.day, today)
    }

    func testShadowFlagsEventfulCandidates() async {
        // Notizia con evento ad alto impatto: il registro ombra segna il
        // candidato, ma gli ordini restano identici (prova in ombra).
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(news: [NewsHeadline(id: 1, headline: "Fed holds rates steady", createdAt: Date(),
                                             symbols: ["SPY"], source: "benzinga", url: nil)])
        let result = await runner(broker, FakeBrain()).run(input()) { _ in }
        XCTAssertEqual(result.book.shadow.first?.eventFlag, true)
        XCTAssertEqual(result.orders.count, 1, "La prova in ombra non cambia nessun ordine")

        // Notizia senza evento: flag false, non nil.
        let quiet = FakeBroker(bars: ["SPY": pullback])
        await quiet.set(news: [NewsHeadline(id: 2, headline: "Apple announces new colors", createdAt: Date(),
                                            symbols: ["SPY"], source: "benzinga", url: nil)])
        let quietResult = await runner(quiet, FakeBrain()).run(input()) { _ in }
        XCTAssertEqual(quietResult.book.shadow.first?.eventFlag, false)

        // Nessuna notizia: flag false da subito, mai nil nelle voci nuove.
        let clean = await runner(FakeBroker(bars: ["SPY": pullback]), FakeBrain()).run(input()) { _ in }
        XCTAssertEqual(clean.book.shadow.first?.eventFlag, false)
    }

    func testOrphanTakeProfitCancelledBeforeRestoringStop() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(positions: [position(10)])
        let tp = BrokerOrder(id: "tp1", symbol: "SPY", side: "sell", type: "limit", status: "new", quantity: 10,
                             filledQuantity: 0, stopPrice: nil, parentOrderId: "p1", submittedAt: nil)
        await broker.set(orders: [tp])
        _ = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        let cancelled = await broker.cancelled
        XCTAssertTrue(cancelled.contains("tp1"), "Un target senza stop gemello va annullato prima di rimettere lo stop")
        let stops = await broker.stopCalls.count
        XCTAssertEqual(stops, 1)
    }

    func testUnfilledStaleEntryIsCounted() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        let entry = BrokerOrder(id: "p1", symbol: "SPY", side: "buy", type: "limit", status: "new",
                                quantity: 10, filledQuantity: 0, stopPrice: nil, parentOrderId: nil, submittedAt: nil)
        await broker.set(orders: [entry])
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY(day: "2026-11-09"))) { _ in }
        XCTAssertEqual(result.book.unfilledEntries, 1)
        XCTAssertNil(result.book.entries["SPY"])
    }

    func testTimeoutRecoversOrderWithoutDuplicate() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(timeoutButCreated: true)
        let result = await runner(broker, FakeBrain()).run(input()) { _ in }
        XCTAssertEqual(result.orders.count, 1)
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 1, "Mai un secondo invio dopo un timeout")
    }

    func testTimeoutWithRejectedOrderIsNotAnEntry() async {
        // Bug B4: l'invio va in timeout e l'ordine ritrovato per client_order_id
        // è STATO RIFIUTATO dal broker: non è un ingresso riuscito. Prima il
        // solo fatto di trovarlo lo dichiarava riuscito.
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(timeoutButCreated: true)
        await broker.set(rejectedRecovered: true)
        let result = await runner(broker, FakeBrain()).run(input()) { _ in }
        XCTAssertTrue(result.orders.isEmpty, "un ordine rifiutato non finisce negli ordini riusciti")
        XCTAssertNil(result.book.entries["SPY"], "nessun ingresso segnato nel registro")
    }

    func testAlreadyDecidedTodayIsNotPaidAgain() async {
        var book = DailyBook()
        book.markDecided("SPY", day: today)
        let brain = FakeBrain()
        let result = await runner(FakeBroker(bars: ["SPY": pullback]), brain).run(input(book: book)) { _ in }
        XCTAssertEqual(result.kimiCalls, 0)
    }

    func testStoppedOutPositionIsRemovedFromBook() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        XCTAssertNil(result.book.entries["SPY"])
        XCTAssertNil(result.book.stops["SPY"])
    }

    func testMissingStopIsRestored() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(positions: [position(10)])
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY(stop: 135))) { _ in }
        let stops = await broker.stopCalls
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.qty, 10)
        XCTAssertEqual(stops.first?.stop, 135)
        XCTAssertEqual(result.book.entries["SPY"], "2026-11-03")
    }

    func testCoveredPositionGetsNoExtraStop() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(positions: [position(10)])
        await broker.set(orders: [stopOrder(10)])
        _ = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        let stops = await broker.stopCalls.count
        XCTAssertEqual(stops, 0, "Uno stop in più potrebbe aprire uno short")
    }

    func testExitAboveSMA5ClosesWithRealFillPrice() async throws {
        let broker = FakeBroker(bars: ["SPY": rising])
        await broker.set(positions: [position(10, entry: 140)])
        await broker.set(orders: [stopOrder(10)])
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        let closed = await broker.closed
        XCTAssertEqual(closed, ["SPY"])
        let cancelled = await broker.cancelled
        XCTAssertTrue(cancelled.contains("s1"))
        let exit = try XCTUnwrap(result.exits.first)
        XCTAssertEqual(exit.reason, .aboveSMA5)
        XCTAssertEqual(exit.realizedPnL ?? 0, (142 - 140) * 10, accuracy: 1e-9)
        XCTAssertNil(result.book.entries["SPY"])
    }

    func testFailedExitRestoresStop() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        await broker.set(positions: [position(10)])
        await broker.set(orders: [stopOrder(10, stop: 135)])
        await broker.set(failClose: true)
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        let stops = await broker.stopCalls
        XCTAssertEqual(stops.count, 1, "Dopo un'uscita fallita lo stop va rimesso")
        XCTAssertEqual(stops.first?.stop, 135)
        XCTAssertEqual(stops.first?.qty, 10)
        XCTAssertTrue(result.exits.isEmpty)
        XCTAssertEqual(result.book.entries["SPY"], "2026-11-03")
    }

    func testExitDeferredWhenMarketClosed() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        await broker.set(positions: [position(10)])
        await broker.set(orders: [stopOrder(10)])
        await broker.set(marketOpen: false)
        let result = await runner(broker, FakeBrain()).run(input(book: bookWithSPY())) { _ in }
        let cancelled = await broker.cancelled
        let closed = await broker.closed
        XCTAssertTrue(cancelled.isEmpty, "A mercato chiuso lo stop non si tocca")
        XCTAssertTrue(closed.isEmpty)
        XCTAssertTrue(result.exits.isEmpty)
    }

    func testPartialEntryResidualCancelledAndProtected() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(positions: [position(5)])
        let entry = BrokerOrder(id: "p1", symbol: "SPY", side: "buy", type: "limit", status: "partially_filled",
                                quantity: 10, filledQuantity: 5, stopPrice: nil, parentOrderId: nil, submittedAt: nil)
        let leg = BrokerOrder(id: "s1", symbol: "SPY", side: "sell", type: "stop", status: "held",
                              quantity: 10, filledQuantity: 0, stopPrice: 135, parentOrderId: "p1", submittedAt: nil)
        await broker.set(orders: [entry, leg])
        _ = await runner(broker, FakeBrain()).run(input(book: bookWithSPY(day: "2026-11-09"))) { _ in }
        let cancelled = await broker.cancelled
        XCTAssertTrue(cancelled.contains("p1"))
        let stops = await broker.stopCalls
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.qty, 5, "Lo stop copre solo la quantità comprata")
    }

    // MARK: - Capitale del bot

    private func capInput(_ cap: Double, book: DailyBook = DailyBook()) -> DailyCycleInput {
        DailyCycleInput(book: book, today: today, riskFraction: 0.01, maxOpenPositions: 3,
                        entryBlock: nil, capitalCap: cap)
    }

    func testCapitalCapScalesRiskAndPositionToBotCapital() async throws {
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(capInput(5_000)) { _ in }
        let order = try XCTUnwrap(result.orders.first)
        // Conto da 100.000 ma capitale bot 5.000: rischio ≤ 1% di 5.000, posizione ≤ 25% di 5.000.
        XCTAssertLessThanOrEqual((order.limitPrice - order.stopPrice) * order.quantity, 50 + 1e-6)
        XCTAssertLessThanOrEqual(order.quantity * order.limitPrice, 1_250 + 1e-6)
        XCTAssertGreaterThan(order.quantity, 0)
    }

    func testCommittedCapitalBlocksEntriesWithoutCallingKimi() async {
        // QQQ già del bot per ~6.000 USD con capitale 5.000: niente nuovi ingressi.
        let broker = FakeBroker(bars: ["SPY": pullback, "QQQ": rising])
        await broker.set(marketOpen: false)
        await broker.set(positions: [BrokerPosition(symbol: "QQQ", quantity: 40, averageEntryPrice: 140, unrealizedPL: 0)])
        await broker.set(orders: [BrokerOrder(id: "q1", symbol: "QQQ", side: "sell", type: "stop", status: "new",
                                              quantity: 40, filledQuantity: 0, stopPrice: 130, parentOrderId: "p", submittedAt: nil)])
        var book = DailyBook()
        book.entries["QQQ"] = "2026-11-05"
        book.stops["QQQ"] = 130
        let brain = FakeBrain()
        let runner = DailyCycleRunner(broker: broker, brain: brain, basket: ["SPY", "QQQ"], exitFillWaitSeconds: 0)
        let result = await runner.run(capInput(5_000, book: book)) { _ in }
        XCTAssertGreaterThan(result.botExposure, 5_000)
        XCTAssertEqual(result.kimiCalls, 0, "Senza capitale libero Kimi non va chiamato")
        let entries = await broker.entryCalls.count
        XCTAssertEqual(entries, 0)
    }

    func testPositionsOutsideTheBotDoNotCountAsBotExposure() async {
        // Una posizione non del bot (non nel registro) non consuma il suo capitale.
        let broker = FakeBroker(bars: ["SPY": pullback, "QQQ": rising])
        await broker.set(marketOpen: false)
        await broker.set(positions: [BrokerPosition(symbol: "QQQ", quantity: 40, averageEntryPrice: 140, unrealizedPL: 0)])
        let brain = FakeBrain()
        let runner = DailyCycleRunner(broker: broker, brain: brain, basket: ["SPY", "QQQ"], exitFillWaitSeconds: 0)
        let result = await runner.run(capInput(5_000)) { _ in }
        XCTAssertEqual(result.botExposure, 0, accuracy: 1e-9)
        XCTAssertEqual(result.orders.count, 1)
    }

    func testUnaffordableCandidateNeverReachesKimi() async {
        // Capitale troppo piccolo per 1 azione entro il 25%: zero crediti spesi.
        let broker = FakeBroker(bars: ["SPY": pullback])
        let brain = FakeBrain()
        let result = await runner(broker, brain).run(capInput(400)) { _ in }
        XCTAssertEqual(result.kimiCalls, 0)
        XCTAssertFalse(result.book.alreadyDecided("SPY", day: today), "Va rivalutato se il capitale cambia")
    }

    func testCycleReportsEquityAndBenchmark() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        let result = await runner(broker, FakeBrain()).run(input()) { _ in }
        XCTAssertEqual(result.equity, 100_000)
        XCTAssertNotNil(result.benchmarkClose)
    }

    func testCandidatesReachBrainWithNews() async {
        let broker = FakeBroker(bars: ["SPY": pullback])
        await broker.set(news: [NewsHeadline(id: 1, headline: "Fed tiene i tassi", createdAt: Date(),
                                             symbols: ["SPY"], source: "benzinga", url: nil)])
        let brain = FakeBrain()
        _ = await runner(broker, brain).run(input()) { _ in }
        let candidates = await brain.lastCandidates
        XCTAssertEqual(candidates.first?.news.count, 1)
        XCTAssertTrue(candidates.first?.news.first?.contains("Fed tiene i tassi") ?? false)
    }

    func testZeroCreditsOnlyOnKimiStages() async {
        let broker = FakeBroker(bars: ["SPY": rising])
        let collector = EventCollector()
        _ = await runner(broker, FakeBrain()).run(input()) { await collector.add($0) }
        let skipped = await collector.events.filter { $0.state == .skipped && $0.stage != nil }
        XCTAssertFalse(skipped.isEmpty)
        for event in skipped {
            let kimi = event.stage?.usesKimi ?? false
            XCTAssertEqual(event.detail.contains("crediti"), kimi, "\(String(describing: event.stage)): \(event.detail)")
        }
    }
}

final class NewsTests: XCTestCase {
    private func item(_ id: Int, _ symbols: [String], minutesAgo: Double) -> NewsHeadline {
        NewsHeadline(id: id, headline: "N\(id)", createdAt: Date().addingTimeInterval(-minutesAgo * 60),
                     symbols: symbols, source: "benzinga", url: nil)
    }

    func testPickPutsOwnNewsFirstThenMarketWithoutDuplicates() {
        let all = [item(1, ["SPY"], minutesAgo: 5), item(2, ["XLF"], minutesAgo: 30),
                   item(3, ["XLF", "SPY"], minutesAgo: 10), item(4, ["AAPL"], minutesAgo: 1)]
        let picked = NewsHeadline.pick(for: "XLF", from: all)
        XCTAssertEqual(picked.map(\.id), [3, 2, 1], "Prima le notizie sull'ETF, poi il mercato; AAPL esclusa")
        XCTAssertEqual(NewsHeadline.pick(for: "XLF", from: all, limit: 1).count, 1)
    }

    func testCompactLineHasTimeAndTitle() {
        XCTAssertTrue(item(9, ["SPY"], minutesAgo: 0).compact.hasSuffix("ET · N9"))
    }
}

actor EventCollector {
    private(set) var events: [DailyCycleEvent] = []
    func add(_ event: DailyCycleEvent) { events.append(event) }
}
