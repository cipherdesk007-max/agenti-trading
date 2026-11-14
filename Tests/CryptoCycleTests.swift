import XCTest
@testable import QuantSwarmAlphaZero

// MARK: - Broker crypto finto (Swift 6 strict concurrency: stato solo via await)

/// Registra ordini, cancellazioni e sequenza delle chiamate, così i test
/// verificano l'ordine ESATTO delle operazioni (stop annullato PRIMA della
/// vendita, market PRIMA dello stop GTC).
actor FakeCryptoBroker: CryptoBrokerClient {
    /// Come fallisce l'invio di un ordine a mercato.
    enum MarketFailure: Sendable {
        case none
        /// No esplicito del broker (HTTP 403: saldo insufficiente).
        case refusal
        /// Rete caduta: la richiesta non è mai arrivata.
        case network
        /// Rete caduta DOPO che il broker ha registrato l'ordine (risposta persa).
        case lostResponse
        /// client_order_id già usato (HTTP 422): l'ordine era già stato inviato.
        case duplicate
    }

    let equity: Double
    let cash: Double
    /// Barre per coppia; una coppia assente simula errore/rate-limit.
    let bars: [String: [Candle]]
    let livePrices: [String: Double]
    /// Quantità a carico del broker per coppia (assente = posizione chiusa).
    let brokerQty: [String: Double]
    /// Fattore di fill degli ordini market (1 = pieno, 0.5 = parziale).
    let fillFactor: Double
    /// true simula lo STOP del motore durante il ciclo (CancellationError).
    let cancelOnAccount: Bool
    /// Stato per id ordine (se assente: vedi orderStatus).
    let statuses: [String: String]
    /// Id per cui orderStatus lancia un errore di rete.
    let statusErrorIds: Set<String>
    /// true: ogni submitStopLimit viene rifiutato (stop mai piazzato).
    let failStopLimit: Bool
    let marketFailure: MarketFailure
    /// Ordini che il broker conosce già, per client_order_id (ricerca).
    let knownOrders: [String: BrokerOrderRef]
    /// Quantità eseguita degli ordini noti, per id.
    let knownFilledQty: [String: Double]
    /// true: la ricerca per client_order_id non risponde (rete).
    let failOrderLookup: Bool
    /// Stop di vendita già vivi sul broker, per coppia.
    let liveStops: [String: [CryptoOpenStop]]
    /// Id il cui annullo non si conferma mai (resta "pending_cancel").
    let stuckCancelIds: Set<String>

    private(set) var events: [String] = []
    private(set) var marketOrders: [MarketCall] = []
    private(set) var stopOrders: [StopCall] = []
    private(set) var canceled: [String] = []
    private var nextId = 0
    /// Quantità inviata per ogni ordine market, per id.
    private var marketQtyById: [String: Double] = [:]

    struct MarketCall: Sendable, Equatable {
        let symbol: String, qty: Double, side: String, clientOrderId: String, id: String
    }

    struct StopCall: Sendable, Equatable {
        let symbol: String, qty: Double, stopPrice: Double, limitPrice: Double, clientOrderId: String, id: String
    }

    struct Snapshot: Sendable, Equatable {
        var events: [String]
        var marketOrders: [MarketCall]
        var stopOrders: [StopCall]
        var canceled: [String]
    }

    init(equity: Double, cash: Double, bars: [String: [Candle]] = [:],
         livePrices: [String: Double] = [:], brokerQty: [String: Double] = [:],
         fillFactor: Double = 1.0, cancelOnAccount: Bool = false,
         statuses: [String: String] = [:], statusErrorIds: Set<String> = [],
         failStopLimit: Bool = false, marketFailure: MarketFailure = .none,
         knownOrders: [String: BrokerOrderRef] = [:], knownFilledQty: [String: Double] = [:],
         failOrderLookup: Bool = false, liveStops: [String: [CryptoOpenStop]] = [:],
         stuckCancelIds: Set<String> = []) {
        self.equity = equity
        self.cash = cash
        self.bars = bars
        self.livePrices = livePrices
        self.brokerQty = brokerQty
        self.fillFactor = fillFactor
        self.cancelOnAccount = cancelOnAccount
        self.statuses = statuses
        self.statusErrorIds = statusErrorIds
        self.failStopLimit = failStopLimit
        self.marketFailure = marketFailure
        self.knownOrders = knownOrders
        self.knownFilledQty = knownFilledQty
        self.failOrderLookup = failOrderLookup
        self.liveStops = liveStops
        self.stuckCancelIds = stuckCancelIds
    }

    func snapshot() -> Snapshot {
        Snapshot(events: events, marketOrders: marketOrders,
                  stopOrders: stopOrders, canceled: canceled)
    }

    func account() async throws -> BrokerAccount {
        if cancelOnAccount { throw CancellationError() }
        return BrokerAccount(equity: equity, cash: cash, buyingPower: cash)
    }

    func cryptoBars(symbol: String) async throws -> [Candle] {
        guard let bars = bars[symbol] else {
            throw QuantSwarmError.invalidServerResponse("nessun dato per \(symbol)")
        }
        return bars
    }

    /// Senza un prezzo esplicito il live coincide con l'ultima chiusura
    /// (app aperta proprio alla chiusura della barra).
    func latestPrice(symbol: String) async throws -> Double {
        livePrices[symbol] ?? bars[symbol]?.last?.close ?? 100
    }

    func positionQty(symbol: String) async throws -> Double {
        brokerQty[symbol] ?? 0
    }

    private func recordMarket(symbol: String, quantity: Double, side: String,
                              clientOrderId: String) -> String {
        nextId += 1
        let id = "mkt-\(nextId)"
        events.append("market:\(side):\(id)")
        marketOrders.append(MarketCall(symbol: symbol, qty: quantity, side: side,
                                       clientOrderId: clientOrderId, id: id))
        marketQtyById[id] = quantity
        return id
    }

    func submitMarket(symbol: String, quantity: Double, side: String,
                      clientOrderId: String) async throws -> String {
        switch marketFailure {
        case .none:
            return recordMarket(symbol: symbol, quantity: quantity, side: side, clientOrderId: clientOrderId)
        case .refusal:
            events.append("market-refused:\(side)")
            throw QuantSwarmError.httpStatus(403, "insufficient balance (simulato)")
        case .network:
            events.append("market-network:\(side)")
            throw URLError(.timedOut)
        case .lostResponse:
            _ = recordMarket(symbol: symbol, quantity: quantity, side: side, clientOrderId: clientOrderId)
            throw URLError(.networkConnectionLost)
        case .duplicate:
            events.append("market-duplicate:\(side)")
            throw QuantSwarmError.httpStatus(422, "client_order_id must be unique (simulato)")
        }
    }

    func submitStopLimit(symbol: String, quantity: Double, stopPrice: Double,
                         limitPrice: Double, clientOrderId: String) async throws -> String {
        if failStopLimit {
            throw QuantSwarmError.invalidServerResponse("stop_limit rifiutato (simulato)")
        }
        nextId += 1
        let id = "stp-\(nextId)"
        events.append("stopLimit:\(id)")
        stopOrders.append(StopCall(symbol: symbol, qty: quantity, stopPrice: stopPrice,
                                    limitPrice: limitPrice, clientOrderId: clientOrderId, id: id))
        return id
    }

    func cancelOrder(id: String) async throws {
        events.append("cancel:\(id)")
        canceled.append(id)
    }

    /// Stato esplicito se dato; altrimenti come un broker vero: un ordine
    /// annullato risulta "canceled" (o resta "pending_cancel" se bloccato),
    /// un ordine a mercato "filled" (o "partially_filled" / "new" secondo il
    /// fattore di fill), ogni altro ordine "new" (vivo).
    func orderStatus(orderId: String) async throws -> String {
        if statusErrorIds.contains(orderId) {
            throw QuantSwarmError.invalidServerResponse("stato non raggiungibile (simulato)")
        }
        if let explicit = statuses[orderId] { return explicit }
        if canceled.contains(orderId) {
            return stuckCancelIds.contains(orderId) ? "pending_cancel" : "canceled"
        }
        if marketQtyById[orderId] != nil {
            if fillFactor >= 1 { return "filled" }
            return fillFactor > 0 ? "partially_filled" : "new"
        }
        return "new"
    }

    func filledQuantity(orderId: String) async throws -> Double {
        if let known = knownFilledQty[orderId] { return known }
        return (marketQtyById[orderId] ?? 0) * fillFactor
    }

    func orderRef(byClientOrderId clientOrderId: String) async throws -> BrokerOrderRef? {
        if failOrderLookup { throw URLError(.timedOut) }
        if let known = knownOrders[clientOrderId] { return known }
        guard let call = marketOrders.last(where: { $0.clientOrderId == clientOrderId }) else { return nil }
        return BrokerOrderRef(id: call.id, status: fillFactor >= 1 ? "filled" : "partially_filled")
    }

    func openSellStops(symbol: String) async throws -> [CryptoOpenStop] {
        let own = stopOrders.filter { $0.symbol == symbol && !canceled.contains($0.id) }
            .map { CryptoOpenStop(id: $0.id, quantity: $0.qty, stopPrice: $0.stopPrice) }
        return (liveStops[symbol] ?? []).filter { !canceled.contains($0.id) } + own
    }
}

// MARK: - Test del ciclo

/// Raccolta dei log emessi dal ciclo (Swift 6 strict concurrency: lo stato
/// mutabile vive dietro l'attore, il resto del test legge con await).
actor LogSink {
    private(set) var logs: [String] = []
    func add(_ message: String) { logs.append(message) }
    func all() -> [String] { logs }
}

/// Ciclo live della modalità CRYPTO (CryptoCycleRunner): ingressi frazionati
/// SENZA bracket (market semplice, poi stop_limit GTC separato), uscite con
/// lo stop annullato prima della vendita, chandelier che sale e mai scende,
/// riconciliazione con le posizioni reali del broker, blocco drawdown.
final class CryptoCycleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_735_689_600)

    private func bar(_ day: Int, close: Double, high: Double? = nil, low: Double? = nil) -> Candle {
        Candle(timestamp: base.addingTimeInterval(TimeInterval(day) * 86_400),
               open: close, high: high ?? close * 1.01, low: low ?? close * 0.99,
               close: close, volume: 1_000)
    }

    /// Serie che non dà segnali: 220 barre a 100 (high 101, low 99).
    private var flatBars: [Candle] { (0..<220).map { bar($0, close: 100) } }

    /// Serie con rottura Donchian20 sopra SMA200 sull'ultima barra (entry).
    private var entryBars: [Candle] {
        var bars = (0..<220).map { bar($0, close: 100) }
        bars.append(bar(220, close: 130, high: 131, low: 129))
        return bars
    }

    private func run(_ broker: FakeCryptoBroker, book: CryptoBook,
                     pairs: [String] = ["BTC/USD"], capitalCap: Double = .infinity,
                     entryBlock: String? = nil) async -> CryptoCycleResult {
        let input = CryptoCycleInput(book: book, today: "2026-11-13",
                                     capitalCap: capitalCap, entryBlock: entryBlock, pairs: pairs)
        return await runner(broker).run(input) { _ in }
    }

    /// Runner con le attese di conferma azzerate (i test non dormono).
    private func runner(_ broker: FakeCryptoBroker) -> CryptoCycleRunner {
        var runner = CryptoCycleRunner(broker: broker)
        runner.confirmDelayNanoseconds = 0
        return runner
    }

    // MARK: - Ingresso: ordine simple frazionato + stop SEPARATO (no bracket)

    func testEntrySendsFractionalMarketThenSeparateStopLimit() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars],
                                      livePrices: ["BTC/USD": 130.5])
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        XCTAssertTrue(result.dataOK)
        XCTAssertEqual(result.livePrices["BTC/USD"] ?? 0, 130.5, accuracy: 0.001)
        XCTAssertEqual(result.orders.count, 1)
        XCTAssertEqual(result.signals["BTC/USD"]?.state, .entry)

        // Un solo ordine market di ACQUISTO, frazionato (1/5 di 5000 = 1000 USD),
        // calcolato sul prezzo LIVE (130,5), non sulla chiusura di ieri (130).
        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertEqual(snap.marketOrders.first?.side, "buy")
        XCTAssertEqual(snap.marketOrders.first?.symbol, "BTC/USD")
        XCTAssertEqual(snap.marketOrders.first?.clientOrderId, "qsc-buy-BTCUSD-2025-08-09")
        let expectedQty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130.5)!
        XCTAssertEqual(snap.marketOrders.first?.qty ?? -1, expectedQty, accuracy: 1e-12)
        XCTAssertTrue(expectedQty < 8) // frazionato, non intero

        // POI un ordine stop_limit GTC SEPARATO (niente bracket: 422 su crypto).
        XCTAssertEqual(snap.stopOrders.count, 1)
        let signal = result.signals["BTC/USD"]!
        let expectedStop = signal.close - CryptoStrategy.chandelierATR * signal.atr22
        XCTAssertEqual(snap.stopOrders.first?.stopPrice ?? -1, expectedStop, accuracy: 1e-9)
        XCTAssertLessThan(snap.stopOrders.first!.limitPrice, snap.stopOrders.first!.stopPrice)
        // Ordine delle chiamate: market PRIMA dello stop.
        let marketIdx = snap.events.firstIndex(of: "market:buy:mkt-1")
        let stopIdx = snap.events.firstIndex(of: "stopLimit:stp-2")
        XCTAssertEqual(marketIdx, 0)
        XCTAssertEqual(stopIdx, 1)

        // Registro aggiornato.
        let position = result.book.position("BTC/USD")
        XCTAssertNotNil(position)
        XCTAssertEqual(position!.qty, expectedQty, accuracy: 1e-12)
        XCTAssertEqual(position!.entryPrice, 130.5, accuracy: 0.001)
        // Il chandelier parte dalla CHIUSURA della barra di rottura, come nello studio.
        XCTAssertEqual(position!.highestClose, 130, accuracy: 0.001)
        XCTAssertEqual(position!.stopPrice ?? 0, expectedStop, accuracy: 1e-9)
        XCTAssertNotNil(position!.stopOrderId)
        XCTAssertNil(position!.exitedDay)
    }

    func testPartialFillKeepsOnlyFilledQuantity() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars], fillFactor: 0.5)
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        let expectedQty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
        XCTAssertEqual(result.book.position("BTC/USD")?.qty ?? 0, expectedQty * 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.orders.first?.quantity ?? 0, expectedQty * 0.5, accuracy: 1e-9)
        // Lo stop GTC copre la quantità realmente riempita, non di più.
        XCTAssertEqual(snap.stopOrders.first?.qty ?? 0, expectedQty * 0.5, accuracy: 1e-9)
    }

    // MARK: - Uscita: prima si annulla lo stop, poi si vende

    func testExitCancelsStopBeforeMarketSell() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": flatBars], // chiusura 100 < chandelier
                                      brokerQty: ["BTC/USD": 0.1])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 150,
                          stopOrderId: "stp-99", stopPrice: 144))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.canceled, ["stp-99"])
        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertEqual(snap.marketOrders.first?.side, "sell")
        XCTAssertEqual(snap.marketOrders.first?.qty ?? 0, 0.1, accuracy: 1e-12)
        // ORDINE delle chiamate: cancel PRIMA della vendita (mai doppia vendita).
        let cancelIdx = snap.events.firstIndex(of: "cancel:stp-99")
        let sellIdx = snap.events.firstIndex(of: "market:sell:mkt-1")
        XCTAssertNotNil(cancelIdx)
        XCTAssertNotNil(sellIdx)
        XCTAssertLessThan(cancelIdx!, sellIdx!)
        // Posizione tolta dal registro e uscita registrata.
        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertEqual(result.exits.count, 1)
        XCTAssertEqual(result.exits.first?.symbol, "BTC/USD")
    }

    // MARK: - Chandelier: lo stop sale, mai scende

    func testHoldRaisesStopOnlyUpward() async {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 105, high: 106, low: 104)) // chandelier sale
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": bars], brokerQty: ["BTC/USD": 0.1])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-7", stopPrice: 96))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertEqual(result.signals["BTC/USD"]?.state, .hold)
        let position = result.book.position("BTC/USD")
        XCTAssertNotNil(position)
        XCTAssertEqual(position!.highestClose, 105, accuracy: 0.001)
        // Stop sostituito SOLO verso l'alto.
        XCTAssertEqual(snap.canceled, ["stp-7"])
        XCTAssertEqual(snap.stopOrders.count, 1)
        let signal = result.signals["BTC/USD"]!
        let expectedStop = 105 - CryptoStrategy.chandelierATR * signal.atr22
        XCTAssertEqual(position!.stopPrice ?? 0, expectedStop, accuracy: 1e-9)
        XCTAssertGreaterThan(position!.stopPrice!, 96)
        XCTAssertNotEqual(position!.stopOrderId, "stp-7")
    }

    func testHoldDoesNotLowerStop() async {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 105, high: 106, low: 104))
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": bars], brokerQty: ["BTC/USD": 0.1])
        var book = CryptoBook()
        // Stop già alto (100): il nuovo chandelier (≈98,4) NON lo abbassa.
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-7", stopPrice: 100))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertEqual(result.signals["BTC/USD"]?.state, .hold)
        let position = result.book.position("BTC/USD")
        XCTAssertEqual(position?.stopOrderId, "stp-7") // invariato
        XCTAssertEqual(position?.stopPrice ?? 0, 100, accuracy: 1e-9)
        XCTAssertTrue(snap.stopOrders.isEmpty)
        XCTAssertTrue(snap.canceled.isEmpty)
        // Il massimo chiusura comunque registrato per il chandelier futuro.
        XCTAssertEqual(position?.highestClose ?? 0, 105, accuracy: 0.001)
    }

    // MARK: - Riconciliazione: lo stop scattato ad app chiusa

    func testReconciliationRemovesPositionClosedByBrokerStop() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars]) // nessuna posizione sul broker
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-1", stopPrice: 96))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertEqual(snap.canceled, ["stp-1"]) // stop residuo pulito
        XCTAssertTrue(snap.marketOrders.isEmpty)  // nessuna vendita: già venduta dal broker
    }

    // MARK: - Blocco drawdown e fallback dati

    func testDrawdownBlockPreventsNewEntries() async {
        let broker = FakeCryptoBroker(equity: 85, cash: 85, // −15% dal picco: blocco ferreo
                                      bars: ["BTC/USD": entryBars])
        var book = CryptoBook()
        book.cashPeak = 100
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertTrue(result.orders.isEmpty)
        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertTrue(snap.marketOrders.isEmpty)
    }

    func testSilentFallbackWhenOnePairHasNoData() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars, "ETH/USD": flatBars])
        // SOL/USD senza dati (rate-limit simulato): le altre coppie continuano.
        let result = await run(broker, book: CryptoBook(),
                               pairs: ["BTC/USD", "ETH/USD", "SOL/USD"])
        let snap = await broker.snapshot()

        XCTAssertFalse(result.dataOK) // non tutti i dati: badge LIVE spento
        // Il motore NON si ferma: BTC ha comunque operato.
        XCTAssertEqual(result.orders.count, 1)
        XCTAssertEqual(result.orders.first?.symbol, "BTC/USD")
        // ETH non dava segnali: nessun ordine.
        XCTAssertNil(result.book.position("ETH/USD"))
        XCTAssertTrue(snap.marketOrders.allSatisfy { $0.symbol == "BTC/USD" })
    }

    func testNoDataAtAllSkipsCycle() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000)
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()
        XCTAssertFalse(result.dataOK)
        XCTAssertTrue(result.orders.isEmpty)
        XCTAssertTrue(snap.marketOrders.isEmpty)
    }

    // MARK: - Stessa barra: non si firma due volte

    func testSameBarDoesNotSignalTwice() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars])
        var book = CryptoBook()
        // Barra già valutata: nessun nuovo ingresso sulla stessa barra.
        book.evaluatedBars["BTC/USD"] = CryptoCycleRunner.barDay(entryBars.last!)
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()
        XCTAssertTrue(result.orders.isEmpty)
        XCTAssertTrue(snap.marketOrders.isEmpty)
        // Il segnale è comunque visibile nel pannello.
        XCTAssertEqual(result.signals["BTC/USD"]?.state, .entry)
    }

    // MARK: - Riepilogo SCOUT del ciclo: il log dice PERCHÉ le coppie sono fuori

    func testCycleLogsSummaryExplainingFlatBelowSMA200() async {
        // 219 barre a 100 + chiusura a 90: sotto la SMA200, regime ribassista.
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 90, high: 91, low: 89))
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": bars])
        let sink = LogSink()
        let input = CryptoCycleInput(book: CryptoBook(), today: "2026-11-13", pairs: ["BTC/USD"])
        _ = await runner(broker).run(input) { event in
            if let message = event.log { await sink.add(message) }
        }
        let logs = await sink.all()
        let summary = logs.first { $0.hasPrefix("CRYPTO ciclo:") }
        XCTAssertNotNil(summary, "il ciclo silenzioso ora lascia una riga: \(logs)")
        XCTAssertTrue(summary!.contains("BTC fuori sotto SMA200"), summary!)
        XCTAssertTrue(summary!.contains("posizioni 0/1"), summary!)
        // Il budget per coppia è 1/5 del totale anche in un test con una
        // sola coppia: il paniere di riferimento è sempre quello di 5.
        XCTAssertTrue(summary!.contains("budget 1000 USD/coppia"), summary!)
        XCTAssertTrue(summary!.contains("drawdown ok"), summary!)
    }

    func testStopDuringCycleIsNotLoggedAsBrokerError() async {
        // STOP del motore mentre il ciclo gira: CancellationError, NON un
        // errore del broker (nel log dell'utente comparivano righe false di
        // "broker non raggiungibile" alla chiusura della sessione).
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars], cancelOnAccount: true)
        let sink = LogSink()
        let input = CryptoCycleInput(book: CryptoBook(), today: "2026-11-13", pairs: ["BTC/USD"])
        let result = await runner(broker).run(input) { event in
            if let message = event.log { await sink.add(message) }
        }
        let logs = await sink.all()
        XCTAssertTrue(logs.isEmpty, "lo STOP non va loggato come errore: \(logs)")
        XCTAssertFalse(result.dataOK)
        XCTAssertTrue(result.orders.isEmpty)
    }

    // MARK: - SELF-HEALING dello stop: la posizione viva non resta mai scoperta

    /// Ingresso riuscito ma stop GTC rifiutato: il log dice la VERITÀ
    /// (prima diceva "stop sul broker" anche quando non c'era) e il ciclo
    /// successivo ri-copre la posizione.
    func testEntryWithoutStopLogsTruthfullyAndNextCycleRepairs() async {
        let qty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars],
                                      brokerQty: ["BTC/USD": qty],
                                      failStopLimit: true)
        let book = CryptoBook()
        let sink1 = LogSink()
        var input = CryptoCycleInput(book: book, today: "2026-11-13", pairs: ["BTC/USD"])
        let result1 = await runner(broker).run(input) { event in
            if let message = event.log { await sink1.add(message) }
        }

        // Ingresso avvenuto, stop NO: il registro lo dice e il log non mente.
        let position1 = result1.book.position("BTC/USD")
        XCTAssertNotNil(position1)
        XCTAssertNil(position1?.stopOrderId)
        XCTAssertNotNil(position1?.stopPrice)
        let logs1 = await sink1.all()
        XCTAssertTrue(logs1.contains { $0.contains("NON è stato accettato dal broker") },
                      "il log deve dire che lo stop manca: \(logs1)")

        // Ciclo 2 (stessa barra: nessun nuovo segnale, solo riconciliazione):
        // la posizione è sul broker, lo stop manca → RIPRISTINATO. Il broker
        // del ciclo 2 ACCETTA gli stop: il ripristino deve riuscire qui.
        let broker2 = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars],
                                      brokerQty: ["BTC/USD": qty])
        let sink2 = LogSink()
        input = CryptoCycleInput(book: result1.book, today: "2026-11-13", pairs: ["BTC/USD"])
        let result2 = await runner(broker2).run(input) { event in
            if let message = event.log { await sink2.add(message) }
        }
        let logs2 = await sink2.all()
        XCTAssertTrue(logs2.contains { $0.contains("RIPRISTINATO") }, "il ciclo deve riparare lo stop: \(logs2)")

        let snap = await broker2.snapshot()
        XCTAssertEqual(snap.stopOrders.count, 1, "un solo stop: quello di ripristino")
        guard let repair = snap.stopOrders.first, let registeredStop = position1?.stopPrice else {
            return XCTFail("riparazione dello stop mancante: \(snap)")
        }
        XCTAssertTrue(repair.clientOrderId.hasPrefix("qsc-stopfix-BTCUSD-2026-11-13-"), repair.clientOrderId)
        XCTAssertEqual(repair.stopPrice, registeredStop, accuracy: 1e-9)
        XCTAssertEqual(repair.qty, qty, accuracy: 1e-12)
        let position2 = result2.book.position("BTC/USD")
        XCTAssertNotNil(position2?.stopOrderId, "registro aggiornato con l'id dello stop riparato")
    }

    /// Posizione viva senza stop nel registro (es. crash tra ingresso e stop):
    /// il ciclo la ri-copre al livello chandelier registrato.
    func testMissingStopIsRepairedAtRegisteredLevel() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars],
                                      brokerQty: ["BTC/USD": 0.1])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: nil, stopPrice: 100))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.stopOrders.count, 1)
        let repair = snap.stopOrders.first!
        XCTAssertEqual(repair.stopPrice, 100, accuracy: 1e-9)
        XCTAssertEqual(repair.qty, 0.1, accuracy: 1e-12)
        XCTAssertEqual(repair.limitPrice, 100 * (1 - 0.002), accuracy: 1e-9)
        let position = result.book.position("BTC/USD")
        XCTAssertEqual(position?.stopOrderId, repair.id)
        XCTAssertEqual(position?.stopPrice ?? 0, 100, accuracy: 1e-9)
    }

    /// Stop cancellato a mano sul broker (stato "canceled"): il ciclo lo
    /// rimpiazza senza cancellare un ordine già terminato.
    func testStopCanceledOnBrokerIsReplaced() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars],
                                      brokerQty: ["BTC/USD": 0.1],
                                      statuses: ["stp-7": "canceled"])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-7", stopPrice: 100))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.canceled.isEmpty, "un ordine già terminato non si cancella")
        XCTAssertEqual(snap.stopOrders.count, 1)
        XCTAssertEqual(snap.stopOrders.first?.stopPrice ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, snap.stopOrders.first?.id)
    }

    /// Quantità cambiata sul broker (fill parziale dello stop): il registro si
    /// riallinea E la nuova quantità viene ri-coperta da uno stop giusto.
    func testQtyRealignmentCoversNewQuantity() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars],
                                      brokerQty: ["BTC/USD": 0.2])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-7", stopPrice: 100))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.canceled, ["stp-7"], "lo stop vecchio copriva la quantità sbagliata")
        XCTAssertEqual(snap.stopOrders.count, 1)
        XCTAssertEqual(snap.stopOrders.first?.qty ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(snap.stopOrders.first?.stopPrice ?? 0, 100, accuracy: 1e-9)
        let position = result.book.position("BTC/USD")
        XCTAssertEqual(position?.qty ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(position?.stopOrderId, snap.stopOrders.first?.id)
    }

    /// Errore di rete sullo stato dello stop: NON si duplica alla cieca, si
    /// considera vivo e si riprova al prossimo tick.
    func testStatusNetworkErrorDoesNotDuplicateStop() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars],
                                      brokerQty: ["BTC/USD": 0.1],
                                      statusErrorIds: ["stp-7"])
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: 100,
                          stopOrderId: "stp-7", stopPrice: 100))
        let result = await run(broker, book: book)
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.stopOrders.isEmpty, "mai doppi stop quando lo stato non si sa")
        XCTAssertTrue(snap.canceled.isEmpty)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, "stp-7")
    }

    // MARK: - Ordini senza doppioni (client_order_id cercato prima di rinviare)

    private let entryDay = "2025-08-09" // giorno UTC dell'ultima barra di entryBars
    private let flatDay = "2025-08-08"  // giorno UTC dell'ultima barra di flatBars

    private func heldBook(stopId: String? = "stp-99", stopPrice: Double = 144,
                          highest: Double = 150) -> CryptoBook {
        var book = CryptoBook()
        book.upsert(.init(symbol: "BTC/USD", entryDay: "2026-11-01", entryPrice: 100,
                          qty: 0.1, highestClose: highest,
                          stopOrderId: stopId, stopPrice: stopPrice))
        return book
    }

    /// App chiusa a metà: l'acquisto era partito ma il registro non era stato
    /// salvato. Al riavvio il broker rifiuta l'id doppio: l'ordine si ritrova
    /// e si adotta, niente secondo acquisto e la posizione riceve il suo stop.
    func testEntryAdoptsOrderAlreadyOnBrokerInsteadOfBuyingTwice() async {
        let qty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars],
                                      brokerQty: ["BTC/USD": qty],
                                      statuses: ["old-1": "filled"],
                                      marketFailure: .duplicate,
                                      knownOrders: ["qsc-buy-BTCUSD-\(entryDay)": BrokerOrderRef(id: "old-1", status: "filled")],
                                      knownFilledQty: ["old-1": qty])
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.marketOrders.isEmpty, "nessun secondo acquisto")
        XCTAssertEqual(result.book.position("BTC/USD")?.qty ?? 0, qty, accuracy: 1e-12)
        XCTAssertEqual(snap.stopOrders.count, 1, "la posizione ritrovata riceve lo stop")
        XCTAssertEqual(snap.stopOrders.first?.qty ?? 0, qty, accuracy: 1e-12)
        XCTAssertNotNil(result.book.position("BTC/USD")?.stopOrderId)
    }

    /// Risposta persa: il broker ha registrato l'ordine ma l'app non l'ha
    /// saputo. Lo si ritrova, un solo acquisto.
    func testEntryLostResponseIsRecoveredNotDuplicated() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars], marketFailure: .lostResponse)
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertNotNil(result.book.position("BTC/USD"))
        XCTAssertEqual(snap.stopOrders.count, 1)
    }

    /// Rete caduta e ordine mai arrivato: niente in registro, la barra resta
    /// da valutare e il tick successivo compra, una volta sola.
    func testEntryNetworkFailureLeavesBarOpenForRetry() async {
        let offline = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                       bars: ["BTC/USD": entryBars], marketFailure: .network)
        let first = await run(offline, book: CryptoBook())
        XCTAssertNil(first.book.position("BTC/USD"))
        XCTAssertNil(first.book.evaluatedBars["BTC/USD"], "la barra non è stata consumata")

        let online = FakeCryptoBroker(equity: 5_000, cash: 5_000, bars: ["BTC/USD": entryBars])
        let second = await run(online, book: first.book)
        let snap = await online.snapshot()
        XCTAssertNotNil(second.book.position("BTC/USD"))
        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertEqual(second.book.evaluatedBars["BTC/USD"], entryDay)
    }

    /// No esplicito del broker (403): niente posizione e niente insistenza
    /// sulla stessa barra (fail-closed).
    func testEntryRefusedByBrokerDoesNotRetrySameBar() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars], marketFailure: .refusal)
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertTrue(snap.stopOrders.isEmpty)
        XCTAssertEqual(result.book.evaluatedBars["BTC/USD"], entryDay)
    }

    /// Invio fallito e nemmeno la ricerca dell'ordine risponde: non si sa
    /// com'è finita, quindi niente in registro e la barra resta da valutare.
    func testEntryStaysOpenWhenTheLookupItselfFails() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars],
                                      marketFailure: .refusal, failOrderLookup: true)
        let result = await run(broker, book: CryptoBook())

        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertNil(result.book.evaluatedBars["BTC/USD"])
    }

    func testBrokerRefusalIsOnlyAnExplicitNo() {
        XCTAssertTrue(CryptoCycleRunner.isBrokerRefusal(QuantSwarmError.httpStatus(403, "saldo")))
        XCTAssertTrue(CryptoCycleRunner.isBrokerRefusal(QuantSwarmError.httpStatus(422, "non valido")))
        XCTAssertFalse(CryptoCycleRunner.isBrokerRefusal(QuantSwarmError.httpStatus(429, "troppe richieste")))
        XCTAssertFalse(CryptoCycleRunner.isBrokerRefusal(QuantSwarmError.httpStatus(503, "server")))
        XCTAssertFalse(CryptoCycleRunner.isBrokerRefusal(URLError(.timedOut)))
    }

    // MARK: - Ingresso: quantità reale, prezzo di adesso, contante che scala

    /// La commissione crypto si paga nella moneta comprata: il conto ne ha un
    /// po' meno dell'eseguito e lo stop deve coprire quella quantità, non di più
    /// (uno stop più grande della posizione il broker lo rifiuta).
    func testEntryStopCoversQuantityNetOfFee() async {
        let qty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
        let held = qty * 0.9975
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars], brokerQty: ["BTC/USD": held])
        let result = await run(broker, book: CryptoBook())
        let snap = await broker.snapshot()

        XCTAssertEqual(result.book.position("BTC/USD")?.qty ?? 0, held, accuracy: 1e-12)
        XCTAssertEqual(snap.stopOrders.first?.qty ?? 0, held, accuracy: 1e-12)
    }

    /// App aperta ore dopo la barra, con il prezzo già sotto lo stop della
    /// rottura: non si compra (lo stop scatterebbe subito o verrebbe rifiutato).
    func testEntrySkippedWhenLivePriceAlreadyBelowStop() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": entryBars], livePrices: ["BTC/USD": 115])
        let sink = LogSink()
        let input = CryptoCycleInput(book: CryptoBook(), today: "2026-11-13", pairs: ["BTC/USD"])
        let result = await runner(broker).run(input) { event in
            if let message = event.log { await sink.add(message) }
        }
        let snap = await broker.snapshot()
        let logs = await sink.all()

        XCTAssertTrue(snap.marketOrders.isEmpty)
        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertTrue(logs.contains { $0.contains("ingresso saltato") }, "\(logs)")
    }

    /// Due rotture nello stesso tick con contante per una sola posizione
    /// piena: la seconda usa solo quello che resta (meno il margine).
    func testTwoEntriesInOneTickDoNotSpendTheSameCashTwice() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_200,
                                      bars: ["BTC/USD": entryBars, "ETH/USD": entryBars])
        let result = await run(broker, book: CryptoBook(), pairs: ["BTC/USD", "ETH/USD"])
        let snap = await broker.snapshot()

        XCTAssertEqual(result.orders.count, 2)
        let first = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
        let left = 1_200 - first * 130
        let second = CryptoStrategy.fractionalQty(
            budget: CryptoStrategy.positionBudget(total: 5_000, cash: left), price: 130)!
        XCTAssertEqual(snap.marketOrders.first?.qty ?? 0, first, accuracy: 1e-12)
        XCTAssertEqual(snap.marketOrders.last?.qty ?? 0, second, accuracy: 1e-12)
        XCTAssertLessThan((first + second) * 130, 1_200, "mai più del contante")
    }

    /// Blocco passeggero (app in background): il segnale non si perde, parte
    /// quando il blocco cade.
    func testBlockedEntryStaysPendingUntilBlockLifts() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000, bars: ["BTC/USD": entryBars])
        let blocked = await run(broker, book: CryptoBook(), entryBlock: "app in background")
        let snapBlocked = await broker.snapshot()
        XCTAssertTrue(snapBlocked.marketOrders.isEmpty)
        XCTAssertNil(blocked.book.evaluatedBars["BTC/USD"])

        let free = await run(broker, book: blocked.book)
        let snapFree = await broker.snapshot()
        XCTAssertEqual(snapFree.marketOrders.count, 1)
        XCTAssertNotNil(free.book.position("BTC/USD"))
    }

    // MARK: - Uscita: si riprova, non si vende due volte

    /// Vendita non partita (rete): la posizione resta e la barra torna da
    /// valutare; al tick dopo lo stop viene rimesso, poi si esce davvero.
    func testExitSellFailureRetriesNextTick() async {
        let offline = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                       bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                       marketFailure: .network)
        let first = await run(offline, book: heldBook())
        XCTAssertNotNil(first.book.position("BTC/USD"), "non venduta: resta in registro")
        XCTAssertNil(first.book.evaluatedBars["BTC/USD"], "l'uscita si riprova al tick dopo, non domani")
        XCTAssertTrue(first.exits.isEmpty)

        let online = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      statuses: ["stp-99": "canceled"])
        let second = await run(online, book: first.book)
        let snap = await online.snapshot()
        XCTAssertNil(second.book.position("BTC/USD"))
        XCTAssertEqual(snap.marketOrders.map(\.side), ["sell"])
        XCTAssertEqual(snap.marketOrders.first?.clientOrderId, "qsc-sell-BTCUSD-\(flatDay)")
        XCTAssertEqual(second.exits.count, 1)
    }

    /// Risposta della vendita persa: l'ordine è sul broker, lo si ritrova.
    /// Una sola vendita e la posizione esce dal registro.
    func testExitLostResponseDoesNotSellTwice() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      marketFailure: .lostResponse)
        let result = await run(broker, book: heldBook())
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertNil(result.book.position("BTC/USD"))
        XCTAssertEqual(result.exits.count, 1)
    }

    /// Annullo dello stop non confermato: la quantità è ancora impegnata,
    /// quindi niente vendita (verrebbe rifiutata); lo stop resta a protezione.
    func testExitWaitsWhenStopCancelIsNotConfirmed() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      stuckCancelIds: ["stp-99"])
        let result = await run(broker, book: heldBook())
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.marketOrders.isEmpty)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, "stp-99")
        XCTAssertNil(result.book.evaluatedBars["BTC/USD"])
    }

    // MARK: - Stop: si adotta quello che c'è, un avviso al giorno

    /// Lo stop è già sul broker ma il registro non lo sa (risposta persa
    /// all'invio): lo si adotta, nessun secondo stop.
    func testMissingStopAdoptsLiveStopAlreadyOnBroker() async {
        let live = CryptoOpenStop(id: "stp-live", quantity: 0.1, stopPrice: 100)
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      liveStops: ["BTC/USD": [live]])
        let result = await run(broker, book: heldBook(stopId: nil, stopPrice: 100, highest: 100))
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.stopOrders.isEmpty, "nessun doppio stop")
        XCTAssertTrue(snap.canceled.isEmpty)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, "stp-live")
    }

    /// Stop vivo ma della misura sbagliata: via quello, poi uno giusto.
    func testLiveStopOfWrongSizeIsReplaced() async {
        let live = CryptoOpenStop(id: "stp-live", quantity: 0.05, stopPrice: 100)
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      liveStops: ["BTC/USD": [live]])
        let result = await run(broker, book: heldBook(stopId: nil, stopPrice: 100, highest: 100))
        let snap = await broker.snapshot()

        XCTAssertEqual(snap.canceled, ["stp-live"])
        XCTAssertEqual(snap.stopOrders.count, 1)
        XCTAssertEqual(snap.stopOrders.first?.qty ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, snap.stopOrders.first?.id)
    }

    /// Ripristino che continua a fallire: il tentativo si ripete a ogni ciclo,
    /// l'avviso "senza stop" parte una volta al giorno (non ogni 60 secondi).
    func testUncoveredPositionAlertsOncePerDay() async {
        let broker = FakeCryptoBroker(equity: 5_000, cash: 5_000,
                                      bars: ["BTC/USD": flatBars], brokerQty: ["BTC/USD": 0.1],
                                      failStopLimit: true)
        let sink = LogSink()
        var book = heldBook(stopId: nil, stopPrice: 100, highest: 100)
        for day in ["2026-11-13", "2026-11-13", "2026-11-14"] {
            let input = CryptoCycleInput(book: book, today: day, pairs: ["BTC/USD"])
            let result = await runner(broker).run(input) { event in
                if let notice = event.notify { await sink.add("\(day) \(notice.title)") }
            }
            book = result.book
        }
        let notices = await sink.all()
        XCTAssertEqual(notices, ["2026-11-13 CRYPTO: BTC/USD senza stop",
                                 "2026-11-14 CRYPTO: BTC/USD senza stop"])
    }

    /// Chandelier salito ma prezzo di adesso già sotto il nuovo livello: lo
    /// stop vecchio non si tocca (annullarlo lascerebbe la posizione scoperta).
    func testHoldKeepsOldStopWhenLivePriceIsBelowNewLevel() async {
        var bars = (0..<219).map { bar($0, close: 100) }
        bars.append(bar(219, close: 105, high: 106, low: 104))
        let broker = FakeCryptoBroker(equity: 5_000, cash: 1_000,
                                      bars: ["BTC/USD": bars], livePrices: ["BTC/USD": 97],
                                      brokerQty: ["BTC/USD": 0.1])
        let result = await run(broker, book: heldBook(stopId: "stp-7", stopPrice: 96, highest: 100))
        let snap = await broker.snapshot()

        XCTAssertTrue(snap.canceled.isEmpty)
        XCTAssertTrue(snap.stopOrders.isEmpty)
        XCTAssertEqual(result.book.position("BTC/USD")?.stopOrderId, "stp-7")
        XCTAssertEqual(result.book.position("BTC/USD")?.stopPrice ?? 0, 96, accuracy: 1e-9)
    }
}
