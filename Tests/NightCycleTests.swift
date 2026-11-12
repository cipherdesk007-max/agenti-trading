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
    /// Ordine cronologico delle azioni sul broker finto, per verificare l'ordine degli invii.
    var events: [String] = []
    /// client_order_id → status dell'ordine "sul broker".
    var known: [String: String] = [:]
    /// Se true, submitAuction lancia e registra l'ordine come rifiutato.
    var rejectAuction = false
    /// Calendario di borsa finto: nil = endpoint non disponibile (il ciclo usa solo clock).
    var calendar: [TradingDay]? = nil

    init(isOpen: Bool, nextClose: Date?) {
        self.isOpen = isOpen
        self.nextClose = nextClose
    }

    func set(held: [BrokerPosition]) { self.held = held }
    func set(orders: [BrokerOrder]) { self.orders = orders }
    func set(isOpen: Bool, nextClose: Date?) { self.isOpen = isOpen; self.nextClose = nextClose }
    func set(account: BrokerAccount) { acct = account }
    func set(rejectAuction: Bool) { self.rejectAuction = rejectAuction }
    func set(calendar: [TradingDay]?) { self.calendar = calendar }

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
        events.append("close \(symbol)")
        held.removeAll { $0.symbol == symbol }
        return "c-\(symbol)"
    }
    func submitMarket(symbol: String, quantity: Int, side: String,
                      clientOrderId: String) async throws -> String {
        marketSells.append((symbol, quantity, clientOrderId))
        events.append("sell-market \(symbol) \(quantity)")
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
        events.append("auction \(side) \(timeInForce) \(symbol) \(quantity)")
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
    func tradingDays(from: Date, to: Date) async throws -> [TradingDay] {
        if let calendar { return calendar }
        throw NightFakeError()
    }
}

final class NightCycleTests: XCTestCase {
    /// 11/11/2026 alle ore indicate di New York.
    private func et(_ hour: Int, _ minute: Int = 0) -> Date {
        et(day: 11, hour, minute)
    }

    private func et(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return c.date!
    }

    // MARK: - Finestre di Alpaca

    func testPhases() {
        XCTAssertEqual(NightStrategy.phase(now: et(12), isOpen: true, nextClose: et(16), calendar: nil, today: "2026-11-11"), .buyWindow)
        if case .wait = NightStrategy.phase(now: et(15, 55), isOpen: true, nextClose: et(16), calendar: nil, today: "2026-11-11") {} else {
            XCTFail("Troppo vicino alla chiusura")
        }
        XCTAssertEqual(NightStrategy.phase(now: et(8), isOpen: false, nextClose: nil, calendar: nil, today: "2026-11-11"), .sellWindow)
        XCTAssertEqual(NightStrategy.phase(now: et(20), isOpen: false, nextClose: nil, calendar: nil, today: "2026-11-11"), .sellWindow)
        if case .wait = NightStrategy.phase(now: et(9, 29), isOpen: false, nextClose: nil, calendar: nil, today: "2026-11-11") {} else {
            XCTFail("OPG rifiutate dalle 9:28")
        }
        if case .wait = NightStrategy.phase(now: et(17), isOpen: false, nextClose: nil, calendar: nil, today: "2026-11-11") {} else {
            XCTFail("OPG rifiutate fra le 16 e le 19")
        }
    }

    // MARK: - Calendario di borsa (GET /v2/calendar)

    func testPhaseHolidayBlocksAuctionOrders() {
        // Calendario disponibile e oggi (11/11) NON è giorno di borsa: festivo.
        let calendar = [TradingDay(date: "2026-11-12", close: et(day: 12, 16))]
        if case .wait(let why) = NightStrategy.phase(now: et(20), isOpen: false, nextClose: nil,
                                                      calendar: calendar, today: "2026-11-11") {
            XCTAssertTrue(why.contains("festivo"), "il wait deve dire che è festivo")
        } else {
            XCTFail("nei festivi niente ordini d'asta")
        }
    }

    func testPhaseEarlyCloseUsesCalendarClose() {
        // Mezza giornata: il calendario dice chiusura 13:00 ET, l'orologio 16:00.
        let calendar = [TradingDay(date: "2026-11-11", close: et(13))]
        // A 12:55 mancano 5 minuti alla chiusura reale: niente MOC (l'orologio da solo direbbe il contrario).
        if case .wait = NightStrategy.phase(now: et(12, 55), isOpen: true, nextClose: et(16),
                                            calendar: calendar, today: "2026-11-11") {} else {
            XCTFail("la chiusura esatta del calendario deve vincere su nextClose")
        }
        XCTAssertEqual(NightStrategy.phase(now: et(10), isOpen: true, nextClose: et(16),
                                           calendar: calendar, today: "2026-11-11"), .buyWindow)
    }

    func testHolidayCyclePlacesNoOrders() async {
        // Sera di festivo con posizione in registro: il calendario dice che oggi
        // non si negozia, quindi nessuna OPG.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(calendar: [TradingDay(date: "2026-11-12", close: et(day: 12, 16))])
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        let sent = await broker.submitted
        XCTAssertTrue(sent.isEmpty, "nei festivi nessuna OPG/MOC")
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
        let kept = result.book.positions["SPYM"]
        XCTAssertEqual(kept?.day, "2026-11-10")
        XCTAssertEqual(kept?.quantity, 2)
        XCTAssertEqual(kept?.sellQueuedDay, "2026-11-11", "la posizione resta nel registro, marcata in coda")
        XCTAssertEqual(kept?.sellQueuedHeld, 2)
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
        XCTAssertEqual(result.book.positions["SPY"]?.sellQueuedDay, "2026-11-11")
        XCTAssertEqual(result.book.positions["SPY"]?.quantity, 2, "la quantità resta: serve per cancellarla quando l'asta la esegue")
        XCTAssertEqual(result.book.positions["SPY"]?.sellQueuedHeld, 6)
    }

    func testSellWindowLegacyEntryWithoutQuantitySellsAllHeld() async {
        // Registro scritto dalla versione precedente (senza quantità):
        // quantità ignota, si vende tutto il detenuto del simbolo, UNA sola volta.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 3, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: nil)
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(8))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.first?.qty, 3)
        XCTAssertNil(result.book.positions["SPYM"],
                     "voce legacy esce subito dopo la coda: la vendita di tutto il detenuto va fatta una sola volta")
        // Se l'OPG sparisce, un ciclo dopo non la reinvia (altrimenti venderebbe di
        // nuovo tutto il detenuto, anche le azioni della giornaliera sullo stesso simbolo).
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: result.book, today: "2026-11-11", now: et(21))) { _ in }
        let sentAfter = await broker.submitted
        XCTAssertEqual(sentAfter.count, 1, "nessun re-invio per voce legacy")
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
        XCTAssertNil(result.book.positions["SPYM"]?.sellQueuedDay, "invio fallito: niente coda")
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
        // Formato di B1 (day + quantity, senza coda): resta leggibile.
        let b1 = #"{"positions":{"SPY":{"day":"2026-11-10","quantity":2}},"nights":1}"#
        let b1Book = try JSONDecoder().decode(NightBook.self, from: Data(b1.utf8))
        XCTAssertEqual(b1Book.positions["SPY"]?.quantity, 2)
        XCTAssertNil(b1Book.positions["SPY"]?.sellQueuedDay)
        // Il campo "in coda" codifica e si rilegge.
        var modern = NightBook()
        modern.positions["SPY"] = NightPosition(day: "2026-11-11", quantity: 2,
                                                sellQueuedDay: "2026-11-11", sellQueuedHeld: 6)
        let data = try JSONEncoder().encode(modern)
        XCTAssertEqual(try JSONDecoder().decode(NightBook.self, from: data), modern)
    }

    // MARK: - OPG annullata all'asta: niente azioni orfane

    func testCanceledOPGIsClosedNextDayAndNotStacked() async {
        // Sera 11/11: OPG in coda, la posizione resta nel registro marcata.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        XCTAssertEqual(evening.book.positions["SPYM"]?.sellQueuedDay, "2026-11-11")
        // L'OPG viene annullata all'asta: le azioni restano, nessun ordine aperto.
        await broker.set(orders: [])
        await broker.set(isOpen: true, nextClose: et(day: 12, 16))
        // Mattina dopo (12/11, mercato aperto): il residuo si chiude a mercato,
        // SOLO quella quantità, e solo dopo si ricompra in chiusura.
        let morning = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12",
                                 now: et(day: 12, 10))) { _ in }
        let closed = await broker.closed
        XCTAssertEqual(closed, ["SPYM"], "il residuo viene chiuso a mercato il giorno dopo")
        XCTAssertTrue(morning.sells.contains("SPYM"))
        XCTAssertTrue(morning.book.positions.values.allSatisfy { $0.day == "2026-11-12" },
                      "nessun residuo del giorno prima resta nel registro")
        let events = await broker.events
        let closeIdx = events.firstIndex { $0 == "close SPYM" }
        let buyIdx = events.firstIndex { $0.hasPrefix("auction buy") }
        XCTAssertNotNil(closeIdx)
        XCTAssertNotNil(buyIdx)
        XCTAssertLessThan(closeIdx!, buyIdx!, "prima si vende il residuo, poi si ricompra: niente doppia esposizione")
        // Un secondo controllo lo stesso giorno non compra di nuovo.
        let again = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: morning.book, today: "2026-11-12", now: et(day: 12, 11))) { _ in }
        XCTAssertTrue(again.buys.isEmpty)
    }

    func testExecutedOPGWithSharedSymbolClearsTheBook() async {
        // SPY: 2 azioni della notte + 4 della giornaliera. Sera 11/11: OPG in
        // coda con detenuto 6. L'asta esegue: vende le 2 della notte, restano 4.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 6, averageEntryPrice: 700, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPY"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        XCTAssertEqual(evening.book.positions["SPY"]?.sellQueuedHeld, 6)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 4, averageEntryPrice: 700, unrealizedPL: 0)])
        await broker.set(orders: [])
        let next = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 20))) { _ in }
        XCTAssertNil(next.book.positions["SPY"], "detenuto sceso di 2 = OPG eseguita: via dal registro")
        let sent = await broker.submitted
        XCTAssertEqual(sent.filter { $0.side == "sell" }.count, 1,
                       "nessuna seconda vendita: le 4 rimaste sono della giornaliera")
    }

    func testRequeuedOPGWithSharedSymbolSellsOnlyNightShares() async {
        // SPY: 2 azioni della notte + 4 della giornaliera. L'OPG in coda sparisce
        // (annullata): al re-invio la quantità resta quella della notte, mai il
        // detenuto totale (sennò si venderebbero anche le azioni della giornaliera).
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 6, averageEntryPrice: 700, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPY"] = NightPosition(day: "2026-11-10", quantity: 2)
        let first = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        XCTAssertEqual(first.book.positions["SPY"]?.sellQueuedDay, "2026-11-11")
        await broker.set(orders: [])  // l'OPG viene annullata: nessun ordine aperto
        let second = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: first.book, today: "2026-11-11", now: et(21))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 2, "l'OPG sparita viene rimessa in coda")
        XCTAssertEqual(sent.last?.qty, 2, "solo le 2 azioni della notte, non le 6 detenute")
        XCTAssertEqual(second.book.positions["SPY"]?.sellQueuedHeld, 6)
    }
}
