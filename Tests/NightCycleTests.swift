import XCTest
@testable import QuantSwarmAlphaZero

private struct NightFakeError: Error {}

private actor FakeNightBroker: NightBroker {
    var isOpen: Bool
    var nextClose: Date?
    var acct = BrokerAccount(equity: 1_000, cash: 1_000, buyingPower: 1_000)
    var held: [BrokerPosition] = []
    var orders: [BrokerOrder] = []
    var prices: [String: Double] = ["SPY": 760, "SPYM": 89.5, "QQQ": 692, "QQQM": 285,
                                    "IWM": 283, "VTWO": 114, "GLD": 365, "GLDM": 79]
    var submitted: [(symbol: String, qty: Int, side: String, tif: String, id: String)] = []
    var closed: [String] = []
    var known: Set<String> = []

    init(isOpen: Bool, nextClose: Date?) {
        self.isOpen = isOpen
        self.nextClose = nextClose
    }

    func set(held: [BrokerPosition]) { self.held = held }
    func set(orders: [BrokerOrder]) { self.orders = orders }
    func set(account: BrokerAccount) { acct = account }

    func nightClock() async throws -> (isOpen: Bool, nextClose: Date?) { (isOpen, nextClose) }
    func account() async throws -> BrokerAccount { acct }
    func positions() async throws -> [BrokerPosition] { held }
    func openOrders() async throws -> [BrokerOrder] { orders }
    func latestPrice(symbol: String) async throws -> Double {
        guard let p = prices[symbol] else { throw NightFakeError() }
        return p
    }
    func closePosition(symbol: String) async throws -> String? {
        closed.append(symbol)
        held.removeAll { $0.symbol == symbol }
        return "c-\(symbol)"
    }
    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> String {
        submitted.append((symbol, quantity, side, timeInForce, clientOrderId))
        known.insert(clientOrderId)
        return "o-\(symbol)"
    }
    func orderId(byClientOrderId id: String) async throws -> String? { known.contains(id) ? "o" : nil }
}

final class NightCycleTests: XCTestCase {
    /// 11/11/2026 alle ore indicate di New York.
    private func et(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
        c.year = 2026; c.month = 11; c.day = 11; c.hour = hour; c.minute = minute
        return c.date!
    }

    // MARK: - Finestre di Alpaca

    func testPhases() {
        XCTAssertEqual(NightStrategy.phase(now: et(12), isOpen: true, nextClose: et(16)), .buyWindow)
        if case .wait = NightStrategy.phase(now: et(15, 55), isOpen: true, nextClose: et(16)) {} else {
            XCTFail("Troppo vicino alla chiusura")
        }
        XCTAssertEqual(NightStrategy.phase(now: et(8), isOpen: false, nextClose: nil), .sellWindow)
        XCTAssertEqual(NightStrategy.phase(now: et(20), isOpen: false, nextClose: nil), .sellWindow)
        if case .wait = NightStrategy.phase(now: et(9, 29), isOpen: false, nextClose: nil) {} else {
            XCTFail("OPG rifiutate dalle 9:28")
        }
        if case .wait = NightStrategy.phase(now: et(17), isOpen: false, nextClose: nil) {} else {
            XCTFail("OPG rifiutate fra le 16 e le 19")
        }
    }

    // MARK: - Divisione del capitale

    func testSmallAccountUsesTwinsAndStaysInBudget() {
        let prices: [String: Double] = ["SPY": 760, "SPYM": 89.5, "QQQ": 692, "QQQM": 285,
                                        "IWM": 283, "VTWO": 114, "GLD": 365, "GLDM": 79]
        let picks = NightStrategy.allocate(budget: 970, prices: prices)
        XCTAssertEqual(Set(picks.map(\.symbol)), ["SPYM", "QQQM", "VTWO", "GLDM"])
        let spent = picks.reduce(0) { $0 + Double($1.quantity) * $1.price }
        XCTAssertLessThanOrEqual(spent, 970)
        XCTAssertGreaterThan(spent, 800, "Quasi tutto investito")
    }

    func testLargeAccountBuysOriginals() {
        let prices: [String: Double] = ["SPY": 760, "SPYM": 89.5, "QQQ": 692, "QQQM": 285,
                                        "IWM": 283, "VTWO": 114, "GLD": 365, "GLDM": 79]
        let picks = NightStrategy.allocate(budget: 100_000, prices: prices)
        XCTAssertEqual(Set(picks.map(\.symbol)), ["SPY", "QQQ", "IWM", "GLD"])
        let values = picks.map { Double($0.quantity) * $0.price }
        XCTAssertLessThan((values.max()! - values.min()!) / 25_000, 0.05, "Peso quasi uguale")
    }

    func testTinyBudgetBuysNothing() {
        XCTAssertTrue(NightStrategy.allocate(budget: 50, prices: ["SPYM": 89.5, "GLDM": 79]).isEmpty)
    }

    // MARK: - Ciclo

    func testBuyWindowQueuesCloseAuctionBuys() async {
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        let input = NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(14))
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0).run(input) { _ in }
        let sent = await broker.submitted
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0.side == "buy" && $0.tif == "cls" })
        XCTAssertEqual(result.book.positions.count, sent.count)
        // Un secondo controllo lo stesso giorno non compra di nuovo.
        let again = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: result.book, today: "2026-11-11", now: et(14, 30))) { _ in }
        let after = await broker.submitted.count
        XCTAssertEqual(after, sent.count)
        XCTAssertTrue(again.buys.isEmpty)
    }

    func testSellWindowQueuesOpeningAuctionSells() async {
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = "2026-11-10"
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.side, "sell")
        XCTAssertEqual(sent.first?.tif, "opg")
        XCTAssertEqual(sent.first?.qty, 2)
        XCTAssertEqual(result.sells, ["SPYM"])
    }

    func testDailyPositionsAreNeverTouched() async {
        // SPY della giornaliera sul conto: non è nel registro notte, la notte non lo vende.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 1, averageEntryPrice: 700, unrealizedPL: 0)])
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertTrue(sent.isEmpty)
    }

    func testLeftoverFromLastNightClosedBeforeNewBuy() async {
        // Mattina saltata: la posizione di ieri si chiude a mercato, poi si ricompra in chiusura.
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        await broker.set(held: [BrokerPosition(symbol: "GLDM", quantity: 3, averageEntryPrice: 79, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["GLDM"] = "2026-11-10"
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(14))) { _ in }
        let closed = await broker.closed
        XCTAssertEqual(closed, ["GLDM"])
        let buys = await broker.submitted.filter { $0.side == "buy" }
        XCTAssertFalse(buys.isEmpty)
    }

    func testEntryBlockStopsBuysOnly() async {
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(14),
                                 entryBlock: "stop drawdown attivo")) { _ in }
        let sent = await broker.submitted
        XCTAssertTrue(sent.isEmpty)
    }

    func testCapitalCapLimitsBudget() async {
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        await broker.set(account: BrokerAccount(equity: 100_000, cash: 100_000, buyingPower: 200_000))
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(14), capitalCap: 1_000)) { _ in }
        let spent = result.buys.reduce(0) { $0 + Double($1.quantity) * $1.price }
        XCTAssertLessThanOrEqual(spent, 1_000)
        XCTAssertGreaterThan(spent, 0)
    }
}
