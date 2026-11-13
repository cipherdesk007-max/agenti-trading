import XCTest
@testable import QuantSwarmAlphaZero

// MARK: - Broker crypto finto (Swift 6 strict concurrency: stato solo via await)

/// Registra ordini, cancellazioni e sequenza delle chiamate, così i test
/// verificano l'ordine ESATTO delle operazioni (stop annullato PRIMA della
/// vendita, market PRIMA dello stop GTC).
actor FakeCryptoBroker: CryptoBrokerClient {
    let equity: Double
    let cash: Double
    /// Barre per coppia; una coppia assente simula errore/rate-limit.
    let bars: [String: [Candle]]
    let livePrices: [String: Double]
    /// Quantità a carico del broker per coppia (assente = posizione chiusa).
    let brokerQty: [String: Double]
    /// Fattore di fill degli ordini market (1 = pieno, 0.5 = parziale).
    let fillFactor: Double

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
         fillFactor: Double = 1.0) {
        self.equity = equity
        self.cash = cash
        self.bars = bars
        self.livePrices = livePrices
        self.brokerQty = brokerQty
        self.fillFactor = fillFactor
    }

    func snapshot() -> Snapshot {
        Snapshot(events: events, marketOrders: marketOrders,
                  stopOrders: stopOrders, canceled: canceled)
    }

    func account() async throws -> BrokerAccount {
        BrokerAccount(equity: equity, cash: cash, buyingPower: cash)
    }

    func cryptoBars(symbol: String) async throws -> [Candle] {
        guard let bars = bars[symbol] else {
            throw QuantSwarmError.invalidServerResponse("nessun dato per \(symbol)")
        }
        return bars
    }

    func latestPrice(symbol: String) async throws -> Double {
        livePrices[symbol] ?? 100
    }

    func positionQty(symbol: String) async throws -> Double {
        brokerQty[symbol] ?? 0
    }

    func submitMarket(symbol: String, quantity: Double, side: String,
                      clientOrderId: String) async throws -> String {
        nextId += 1
        let id = "mkt-\(nextId)"
        events.append("market:\(side):\(id)")
        marketOrders.append(MarketCall(symbol: symbol, qty: quantity, side: side,
                                       clientOrderId: clientOrderId, id: id))
        marketQtyById[id] = quantity
        return id
    }

    func submitStopLimit(symbol: String, quantity: Double, stopPrice: Double,
                         limitPrice: Double, clientOrderId: String) async throws -> String {
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

    func orderStatus(orderId: String) async throws -> String { "filled" }

    func filledQuantity(orderId: String) async throws -> Double {
        (marketQtyById[orderId] ?? 0) * fillFactor
    }
}

// MARK: - Test del ciclo

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
        return await CryptoCycleRunner(broker: broker).run(input) { _ in }
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

        // Un solo ordine market di ACQUISTO, frazionato (1/5 di 5000 = 1000 USD).
        XCTAssertEqual(snap.marketOrders.count, 1)
        XCTAssertEqual(snap.marketOrders.first?.side, "buy")
        XCTAssertEqual(snap.marketOrders.first?.symbol, "BTC/USD")
        let expectedQty = CryptoStrategy.fractionalQty(budget: 1_000, price: 130)!
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
        XCTAssertEqual(position!.entryPrice, 130, accuracy: 0.001)
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
}
