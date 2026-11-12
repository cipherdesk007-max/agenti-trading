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
    var marketSells: [(symbol: String, qty: Int, id: String)] = []
    var closed: [String] = []
    /// client_order_id → status dell'ordine "sul broker".
    var known: [String: String] = [:]
    /// Se true, submitAuction lancia e registra l'ordine come rifiutato.
    var rejectAuction = false

    init(isOpen: Bool, nextClose: Date?) {
        self.isOpen = isOpen
        self.nextClose = nextClose
    }

    func set(held: [BrokerPosition]) { self.held = held }
    func set(orders: [BrokerOrder]) { self.orders = orders }
    func set(account: BrokerAccount) { acct = account }
    func set(rejectAuction: Bool) { self.rejectAuction = rejectAuction }

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
    func submitMarket(symbol: String, quantity: Int, side: String,
                      clientOrderId: String) async throws -> String {
        marketSells.append((symbol, quantity, clientOrderId))
        if let i = held.firstIndex(where: { $0.symbol.uppercased() == symbol.uppercased() }) {
            let rest = held[i].quantity - Double(quantity)
            var updated = held
            updated.remove(at: i)
            if rest > 0 {
                updated.append(BrokerPosition(symbol: held[i].symbol, quantity: rest,
                                              averageEntryPrice: held[i].averageEntryPrice,
                                              unrealizedPL: held[i].unrealizedPL))
            }
            held = updated
        }
        known[clientOrderId] = "new"
        return "m-\(symbol)"
    }
    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> String {
        submitted.append((symbol, quantity, side, timeInForce, clientOrderId))
        if rejectAuction {
            // Il broker ha registrato l'ordine ma lo ha rifiutato.
            known[clientOrderId] = "rejected"
            throw NightFakeError()
        }
        known[clientOrderId] = "new"
        return "o-\(symbol)"
    }
    func orderRef(byClientOrderId id: String) async throws -> BrokerOrderRef? {
        known[id].map { BrokerOrderRef(id: "broker-\(id)", status: $0) }
    }
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
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.side, "sell")
        XCTAssertEqual(sent.first?.tif, "opg")
        XCTAssertEqual(sent.first?.qty, 2)
        XCTAssertEqual(result.sells, ["SPYM"])
        XCTAssertNil(result.book.positions["SPYM"], "la posizione esce dal registro appena la vendita OPG è in coda")
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
        book.positions["GLDM"] = NightPosition(day: "2026-11-10", quantity: 3)
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

    // MARK: - Bug B1: la notte vende solo le sue azioni

    func testSellWindowSellsOnlyNightSharesWhenDailyOwnsSameSymbol() async {
        // SPY: 4 azioni della giornaliera + 2 della notte. L'OPG deve vendere
        // SOLO le 2 della notte: prima vendeva tutte le 6 e lo stop GTC
        // residuo della giornaliera poteva persino aprire uno short.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 6, averageEntryPrice: 700, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPY"] = NightPosition(day: "2026-11-10", quantity: 2)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.side, "sell")
        XCTAssertEqual(sent.first?.tif, "opg")
        XCTAssertEqual(sent.first?.qty, 2, "solo le azioni della notte, mai quelle della giornaliera")
        XCTAssertNil(result.book.positions["SPY"])
    }

    func testSellWindowLegacyEntryWithoutQuantitySellsAllHeld() async {
        // Registro scritto dalla versione precedente (senza quantità):
        // quantità ignota, si vende tutto il detenuto del simbolo.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 3, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: nil)
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.first?.qty, 3)
    }

    func testLeftoverClosesOnlyNightSharesNotDailyOnes() async {
        // Mattina saltata con lo stesso simbolo della giornaliera: la
        // chiusura "leftover" deve vendere solo le azioni della notte.
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        await broker.set(held: [BrokerPosition(symbol: "GLD", quantity: 5, averageEntryPrice: 365, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["GLD"] = NightPosition(day: "2026-11-10", quantity: 2)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(10))) { _ in }
        let sells = await broker.marketSells
        XCTAssertEqual(sells.count, 1)
        XCTAssertEqual(sells.first?.qty, 2, "solo le 2 azioni della notte")
        let closed = await broker.closed
        XCTAssertTrue(closed.isEmpty, "non chiude la posizione intera: le altre 3 sono della giornaliera")
        XCTAssertNil(result.book.positions["GLD"])
    }

    // MARK: - Bug B4: un ordine rifiutato non è un invio riuscito

    func testRejectedAuctionOrderIsNotTreatedAsSuccess() async {
        // La OPG viene rifiutata dal broker: il ciclo NON deve dichiararla
        // riuscita (prima il lookup per client_order_id trovava l'ordine
        // rifiutato e lo contava come venduto).
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        await broker.set(rejectAuction: true)
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        XCTAssertTrue(result.sells.isEmpty, "una vendita rifiutata non è una vendita riuscita")
        XCTAssertEqual(result.book.positions["SPYM"]?.day, "2026-11-10",
                       "la posizione resta nel registro: si ritenta alla prossima finestra utile")
    }

    // MARK: - Registro: retrocompatibilità del formato

    func testNightBookDecodesLegacyFormatAndRoundTrips() throws {
        let legacy = #"{"positions":{"SPY":"2026-11-10","QQQM":"2026-11-09"},"nights":3}"#
        let book = try JSONDecoder().decode(NightBook.self, from: Data(legacy.utf8))
        XCTAssertEqual(book.nights, 3)
        XCTAssertEqual(book.positions["SPY"]?.day, "2026-11-10")
        XCTAssertNil(book.positions["SPY"]?.quantity, "quantità ignota nel formato vecchio")
        let reencoded = try JSONEncoder().encode(book)
        let again = try JSONDecoder().decode(NightBook.self, from: reencoded)
        XCTAssertEqual(again, book, "il formato nuovo si codifica e si rilegge identico")
    }
}
