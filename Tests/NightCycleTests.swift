import XCTest
@testable import QuantSwarmAlphaZero

struct NightFakeError: Error {}

actor FakeNightBroker: NightBroker {
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
    /// Simboli le cui aste vengono rifiutate (per simulare MOC parziali).
    var rejectSymbols: Set<String> = []
    /// Calendario di borsa finto: nil = endpoint non disponibile (il ciclo usa solo clock).
    var calendar: [TradingDay]? = nil
    /// orderId → prezzo di esecuzione (filled_avg_price).
    var fills: [String: Double] = [:]
    /// "SIMBOLO|giorno|kind" → prezzo reale dell'asta.
    var auctions: [String: Double] = [:]

    init(isOpen: Bool, nextClose: Date?) {
        self.isOpen = isOpen
        self.nextClose = nextClose
    }

    func set(held: [BrokerPosition]) { self.held = held }
    func set(orders: [BrokerOrder]) { self.orders = orders }
    func set(isOpen: Bool, nextClose: Date?) { self.isOpen = isOpen; self.nextClose = nextClose }
    func set(account: BrokerAccount) { acct = account }
    func set(rejectAuction: Bool) { self.rejectAuction = rejectAuction }
    func set(rejectSymbols: Set<String>) { self.rejectSymbols = rejectSymbols }
    /// Cambia lo stato di un ordine noto (simula l'asta: filled, canceled…).
    func markOrder(clientOrderId: String, status: String) { known[clientOrderId] = status }
    func set(calendar: [TradingDay]?) { self.calendar = calendar }
    func set(fills: [String: Double]) { self.fills = fills }
    /// Se true, submitAuction lancia l'errore 40310000 di Alpaca (conto con
    /// trading sospeso dall'utente).
    var rejectWithFrozen = false
    func set(rejectWithFrozen: Bool) { self.rejectWithFrozen = rejectWithFrozen }

    func set(auctions: [String: Double]) { self.auctions = auctions }
    /// true simula lo STOP del motore durante il ciclo (CancellationError).
    var cancelOnClock = false
    func set(cancelOnClock: Bool) { self.cancelOnClock = cancelOnClock }

    func nightClock() async throws -> (isOpen: Bool, nextClose: Date?) {
        if cancelOnClock { throw CancellationError() }
        return (isOpen, nextClose)
    }
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
        if rejectWithFrozen {
            // Il conto rifiuta TUTTI i nuovi ordini (flag "trades suspended").
            known[clientOrderId] = "rejected"
            throw QuantSwarmError.httpStatus(
                403, "{\"code\":40310000,\"message\":\"new orders are rejected by user request\"}"
            )
        }
        if rejectAuction || rejectSymbols.contains(symbol.uppercased()) {
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
    func orderFillPrice(orderId: String) async throws -> Double? { fills[orderId] }
    func auctionPrice(symbol: String, day: String, kind: AuctionKind) async throws -> Double? {
        auctions["\(symbol.uppercased())|\(day)|\(kind.rawValue)"]
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

    // MARK: - Finestre: fine settimana, festivo infrasettimanale, mezza giornata

    func testPhaseWeekendQueuesOPGOutsideAuctionWindow() {
        // Sabato 14/11/2026 e domenica 15/11/2026: il calendario non li contiene,
        // ma non sono festivi infrasettimanali.
        let calendar = [TradingDay(date: "2026-11-16", close: et(day: 16, 16))]
        // Sabato 12:00 ET (mercato chiuso): dentro 9:28–19:00 ET → wait.
        if case .wait = NightStrategy.phase(now: et(day: 14, 12), isOpen: false, nextClose: nil,
                                            calendar: calendar, today: "2026-11-14") {} else {
            XCTFail("sabato di giorno si aspetta: le OPG si accettano solo fuori 9:28–19:00 ET")
        }
        // Sabato 20:00 ET: OPG in coda per lunedì.
        XCTAssertEqual(NightStrategy.phase(now: et(day: 14, 20), isOpen: false, nextClose: nil,
                                               calendar: calendar, today: "2026-11-14"), .sellWindow)
        // Domenica 21:00 ET: idem.
        XCTAssertEqual(NightStrategy.phase(now: et(day: 15, 21), isOpen: false, nextClose: nil,
                                               calendar: calendar, today: "2026-11-15"), .sellWindow)
    }

    func testPhaseWeekdayHolidayStillWaits() {
        // Giovedì 26/11/2026 (festivo infrasettimanale, es. Thanksgiving): wait festivo.
        let calendar = [TradingDay(date: "2026-11-27", close: et(day: 27, 13))]
        if case .wait(let why) = NightStrategy.phase(now: et(day: 26, 20), isOpen: false, nextClose: nil,
                                                      calendar: calendar, today: "2026-11-26") {
            XCTAssertTrue(why.contains("festivo"), "il wait deve dire che è festivo")
        } else {
            XCTFail("festivo infrasettimanale: nessuna asta nemmeno la sera")
        }
    }

    func testPhaseEarlyCloseAfternoonWaits() {
        // Venerdì 27/11/2026 mezza giornata: chiusura 13:00 ET. Alle 13:30 il mercato
        // è chiuso ma siamo dentro 9:28–19:00 ET: l'OPG verrebbe rifiutata da Alpaca.
        let calendar = [TradingDay(date: "2026-11-27", close: et(day: 27, 13))]
        if case .wait = NightStrategy.phase(now: et(day: 27, 13, 30), isOpen: false, nextClose: nil,
                                            calendar: calendar, today: "2026-11-27") {} else {
            XCTFail("dopo una chiusura anticipata alle 13:00 ET non si mette OPG alle 13:30")
        }
        // Alle 19:30 ET invece sì.
        XCTAssertEqual(NightStrategy.phase(now: et(day: 27, 19, 30), isOpen: false, nextClose: nil,
                                               calendar: calendar, today: "2026-11-27"), .sellWindow)
    }

    func testWeekendEveningQueuesOPGForMonday() async {
        // Sabato 14/11 20:00 ET con posizione in registro: OPG in coda per lundi 16.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(calendar: [TradingDay(date: "2026-11-16", close: et(day: 16, 16))])
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-13", quantity: 2)
        let res = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-14", now: et(day: 14, 20))) { _ in }
        let sent = await broker.submitted
        XCTAssertEqual(sent.filter { $0.tif == "opg" && $0.side == "sell" }.count, 1,
                       "sabato sera l'OPG va in coda per lundi")
        XCTAssertEqual(res.book.positions["SPYM"]?.sellQueuedDay, "2026-11-14")
        XCTAssertNotNil(res.book.positions["SPYM"]?.sellQueuedOrderId, "il client_order_id dell'OPG va salvato nel registro")
    }

    // MARK: - Conferma della vendita dallo stato dell'ordine OPG

    func testOPGFilledByOrderStatusClearsBookEvenWhenHeldDidNotDrop() async {
        // SPY: 2 azioni della notte + 4 della giornaliera. L'OPG risulta FILLED
        // sul broker ma il detenuto resta 6: la conferma viene dallo STATO
        // dell'ordine (client_order_id), non dal calo del detenuto.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 6, averageEntryPrice: 700, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPY"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        let opgId = await broker.submitted.filter { $0.side == "sell" }.last!.4
        await broker.markOrder(clientOrderId: opgId, status: "filled")
        await broker.set(orders: [])
        // Il detenuto resta 6 (la giornaliera non vende): solo lo stato "filled" toglie la voce.
        let next = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 20))) { _ in }
        XCTAssertNil(next.book.positions["SPY"], "OPG filled (stato ordine) → via dal registro anche se il detenuto non è sceso")
        let sent = await broker.submitted
        XCTAssertEqual(sent.filter { $0.side == "sell" }.count, 1, "nessuna seconda vendita")
    }

    func testOPGCanceledByOrderStatusStaysAsResidual() async {
        // L'OPG risulta CANCELED sul broker: la voce resta (residuo) e al prossimo
        // buy window viene chiusa a mercato solo la quantità della notte.
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 6, averageEntryPrice: 700, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPY"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        let opgId = await broker.submitted.filter { $0.side == "sell" }.last!.4
        await broker.markOrder(clientOrderId: opgId, status: "canceled")
        await broker.set(orders: [])
        await broker.set(isOpen: true, nextClose: et(day: 12, 16))
        let morning = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 10))) { _ in }
        let sells = await broker.marketSells
        XCTAssertEqual(sells.first?.1, 2, "chiusura a mercato di SOLO le 2 azioni della notte, non le 6 detenute")
        if let spy = morning.book.positions["SPY"] {
            XCTAssertEqual(spy.day, "2026-11-12", "se SPY è nel registro è un nuovo acquisto di oggi, non il residuo")
        }
    }

    // MARK: - Acquisti MOC parziali e blocco famiglia con residuo

    func testPartialMOCRetriesOnlyMissingFamiliesWithTwin() async {
        // Budget per 4 originali; la MOC di QQQ è rifiutata: si ritenta solo quella
        // famiglia, col gemello QQQM. Nessuna famiglia doppia.
        let broker = FakeNightBroker(isOpen: true, nextClose: et(day: 12, 16))
        await broker.set(account: BrokerAccount(equity: 100_000, cash: 100_000, buyingPower: 400_000))
        await broker.set(rejectSymbols: ["QQQ"])
        let res = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: NightBook(), today: "2026-11-12", now: et(day: 12, 10))) { _ in }
        let sent = await broker.submitted
        let buys = sent.filter { $0.side == "buy" && $0.tif == "cls" }.map { $0.0 }
        func family(of s: String) -> Int {
            NightStrategy.families.firstIndex { $0.symbols.contains(s) } ?? -1
        }
        // Nel registro una sola MOC per famiglia (il retry interno di submit può
        // aver ritentato l'originale rifiutato: quello non conta come successo).
        XCTAssertEqual(Set(res.book.positions.keys.map(family)).count, 4, "una sola MOC per famiglia: niente duplicati")
        XCTAssertTrue(buys.contains("QQQM"), "la famiglia mancante viene ritentata col gemello")
        XCTAssertFalse(res.book.positions.keys.contains("QQQ"), "l'originale rifiutato non entra nel registro")
        XCTAssertTrue(res.book.positions.keys.contains("SPY") && res.book.positions.keys.contains("IWM")
                      && res.book.positions.keys.contains("GLD"))
    }

    func testResidualOnTwinBlocksOriginalOfSameFamily() async {
        // Residuo SPYM del giorno prima con OPG ancora aperta: la famiglia S&P 500
        // è bloccata, stasera non si compra né SPY né SPYM.
        let broker = FakeNightBroker(isOpen: true, nextClose: et(day: 12, 16))
        await broker.set(account: BrokerAccount(equity: 100_000, cash: 100_000, buyingPower: 400_000))
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        await broker.set(orders: [BrokerOrder(id: "opg1", symbol: "SPYM", side: "sell", type: "market",
                                               status: "new", quantity: 2, filledQuantity: 0,
                                               stopPrice: nil, parentOrderId: nil, submittedAt: nil)])
        await broker.markOrder(clientOrderId: "qsn-s-SPYM-2026-11-11-1", status: "new")
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-11", quantity: 2, sellQueuedDay: "2026-11-11",
                                               sellQueuedHeld: 2, sellQueuedOrderId: "qsn-s-SPYM-2026-11-11-1")
        _ = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-12", now: et(day: 12, 10))) { _ in }
        let sent = await broker.submitted
        let buySymbols = sent.filter { $0.side == "buy" }.map { $0.0 }
        XCTAssertFalse(buySymbols.contains("SPY") || buySymbols.contains("SPYM"),
                       "con un residuo su SPYM non si compra SPY (stessa famiglia)")
        XCTAssertEqual(buySymbols.count, 3, "si comprano le altre 3 famiglie")
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

    /// Divisione della NOTTE parametrica su 500 / 1.000 / 10.000 / 100.000 /
    /// 1.000.000 USD (CONTROLLO FINALE): mai oltre il budget (97% del capitale),
    /// mai quantità zero o negative, 4 famiglie dès che il budget lo permette.
    func testAllocateParametricBudgets() {
        let prices: [String: Double] = ["SPY": 760, "SPYM": 89.5, "QQQ": 692, "QQQM": 285,
                                        "IWM": 283, "VTWO": 114, "GLD": 365, "GLDM": 79]
        for equity in [500.0, 1_000, 10_000, 100_000, 1_000_000] {
            let budget = equity * (1 - NightStrategy.cashBuffer)
            let picks = NightStrategy.allocate(budget: budget, prices: prices)
            let spent = picks.reduce(0) { $0 + Double($1.quantity) * $1.price }
            XCTAssertLessThanOrEqual(spent, budget + 1e-6, "Mai oltre il budget a equity \(equity)")
            XCTAssertTrue(picks.allSatisfy { $0.quantity > 0 }, "Mai quantità zero/negative a equity \(equity)")
            if equity >= 1_000 {
                XCTAssertEqual(picks.count, 4, "Le 4 famiglie a equity \(equity)")
            }
        }
    }

    // MARK: - Ciclo

    func testFrozenAccountLogsActionableAdviceNotRawJSON() async {
        // Conto con trading sospeso (40310000): il log deve spiegare COSA
        // fare (voce del pannello Alpaca), non sputare il JSON dell'errore
        // per ogni simbolo (report 13/11 16:03).
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        await broker.set(rejectWithFrozen: true)
        let input = NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(14))
        let sink = LogSink()
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0).run(input) { event in
            if let message = event.log { await sink.add(message) }
        }
        let logs = await sink.all()
        XCTAssertTrue(result.buys.isEmpty, "con il conto sospeso nessun ordine passa")
        let frozen = logs.filter { $0.contains("TRADING SOSPESO") }
        XCTAssertFalse(frozen.isEmpty, "il rifiuto deve dire che il conto ha il trading sospeso: \(logs)")
        XCTAssertTrue(frozen.allSatisfy { !$0.contains("40310000") }, "niente JSON grezzo: \(frozen)")
        XCTAssertFalse(logs.contains { $0.contains("Errore HTTP") })
    }

    func testStopDuringCycleIsNotLoggedAsBrokerError() async {
        // STOP del motore durante il ciclo: CancellationError, NON un errore
        // del broker. Prima il catch generico lo loggava come "broker non
        // raggiungibile" (righe false nel log alla chiusura sessione).
        let broker = FakeNightBroker(isOpen: true, nextClose: et(16))
        await broker.set(cancelOnClock: true)
        let input = NightCycleInput(book: NightBook(), today: "2026-11-11", now: et(14))
        let sink = LogSink()
        let result = await NightCycleRunner(broker: broker, settleWaitSeconds: 0).run(input) { event in
            if let message = event.log { await sink.add(message) }
        }
        let logs = await sink.all()
        XCTAssertTrue(result.aborted)
        XCTAssertTrue(logs.isEmpty, "lo STOP non va loggato come errore broker: \(logs)")
    }

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
        // L'asta esegue: lo stato dell'OPG sul broker diventa "filled".
        let opgId = await broker.submitted.filter { $0.side == "sell" }.last!.4
        await broker.markOrder(clientOrderId: opgId, status: "filled")
        await broker.set(held: [BrokerPosition(symbol: "SPY", quantity: 4, averageEntryPrice: 700, unrealizedPL: 0)])
        await broker.set(orders: [])
        let next = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 20))) { _ in }
        XCTAssertNil(next.book.positions["SPY"], "OPG executed (stato filled) = via dal registro")
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

    // MARK: - Misura executed-vs-asta (solo report)

    func testAuctionDiffIsMeasuredOnceAndReported() async {
        // Sera 11/11: OPG in coda per SPYM (nel finto l'id è "o-SPYM").
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        XCTAssertEqual(evening.book.fillChecks.count, 1, "l'OPG in coda viene tracciata per la misura")
        // L'OPG si è eseguita all'apertura del 12/11: asta reale 90.00, eseguito 90.25.
        await broker.set(held: [])
        await broker.set(orders: [])
        await broker.set(fills: ["o-SPYM": 90.25])
        await broker.set(auctions: ["SPYM|2026-11-12|open": 90.00])
        let next = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 20))) { _ in }
        XCTAssertEqual(next.auctionDiffs.count, 1)
        let d = next.auctionDiffs.first!
        XCTAssertEqual(d.symbol, "SPYM")
        XCTAssertEqual(d.side, "sell")
        XCTAssertEqual(d.executed, 90.25, accuracy: 1e-9)
        XCTAssertEqual(d.auction, 90.00, accuracy: 1e-9)
        XCTAssertEqual(d.diff, 0.25, accuracy: 1e-9)
        XCTAssertTrue(next.book.fillChecks.isEmpty, "la misura è one-shot: tolta dal registro")
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 1, "la misura non genera ordini")
    }

    func testAuctionMeasurementIsOptional() async {
        // API aste/fill che non rispondono: nessun diff, nessun ordine, e il
        // check viene tolto quando l'ordine non è più aperto (niente blocchi).
        let broker = FakeNightBroker(isOpen: false, nextClose: nil)
        await broker.set(held: [BrokerPosition(symbol: "SPYM", quantity: 2, averageEntryPrice: 89, unrealizedPL: 0)])
        var book = NightBook()
        book.positions["SPYM"] = NightPosition(day: "2026-11-10", quantity: 2)
        let evening = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: book, today: "2026-11-11", now: et(20))) { _ in }
        await broker.set(held: [])
        await broker.set(orders: [])
        let next = await NightCycleRunner(broker: broker, settleWaitSeconds: 0)
            .run(NightCycleInput(book: evening.book, today: "2026-11-12", now: et(day: 12, 20))) { _ in }
        XCTAssertTrue(next.auctionDiffs.isEmpty)
        XCTAssertTrue(next.book.fillChecks.isEmpty)
        let sent = await broker.submitted
        XCTAssertEqual(sent.count, 1)
    }
}
