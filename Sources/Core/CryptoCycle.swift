import Foundation

/// Broker crypto per il ciclo (interfaccia sottoposta a test con finti broker).
protocol CryptoBrokerClient: Sendable {
    func account() async throws -> BrokerAccount
    /// Barre 1D CHIUSE della coppia (l'ultima barra in formazione esclusa).
    func cryptoBars(symbol: String) async throws -> [Candle]
    /// Prezzo live (mid quote) per il badge LIVE e i controlli.
    func latestPrice(symbol: String) async throws -> Double
    /// Quantità della coppia a carico del broker (0 = chiusa dallo stop).
    /// Non optional: 0 significa "non c'è più", un errore è un errore.
    func positionQty(symbol: String) async throws -> Double
    /// Ordine crypto `simple` frazionato (qty decimale). Ritorna l'id.
    func submitMarket(symbol: String, quantity: Double, side: String,
                      clientOrderId: String) async throws -> String
    /// Stop protettivo: vendita stop_limit GTC. Ritorna l'id.
    func submitStopLimit(symbol: String, quantity: Double, stopPrice: Double,
                         limitPrice: Double, clientOrderId: String) async throws -> String
    func cancelOrder(id: String) async throws
    /// Stato dell'ordine: "filled", "canceled", "rejected", "new"...
    func orderStatus(orderId: String) async throws -> String
    /// Quantità eseguita finora dell'ordine.
    func filledQuantity(orderId: String) async throws -> Double
}

struct CryptoCycleInput: Sendable {
    var book: CryptoBook
    let today: String
    /// Tetto capitale (min(equity, cap) è il budget del bot).
    var capitalCap: Double = .infinity
    /// nil = ingressi consentiti; altrimenti il motivo del blocco
    /// (app in background, stop drawdown...).
    var entryBlock: String?
    /// Coppie da seguire (default il paniere dello studio).
    var pairs: [String] = CryptoStrategy.pairs
}

struct CryptoCycleEvent: Sendable {
    var stage: PipelineStageID?
    var state: PipelineState = .done
    var detail: String = ""
    var log: String?
    var agent: AgentKind = .system
    var notify: (title: String, body: String)?
}

struct CryptoPlacedOrder: Sendable, Equatable {
    let symbol: String
    let orderId: String
    let quantity: Double
    let entryPrice: Double
    let stopPrice: Double
}

struct CryptoExit: Sendable, Equatable {
    let symbol: String
    let reason: String
    /// P&L non realizzato stimato alla chiusura (se noto).
    let estimatedPnL: Double?
}

struct CryptoCycleResult: Sendable, Equatable {
    var book: CryptoBook
    var orders: [CryptoPlacedOrder] = []
    var exits: [CryptoExit] = []
    /// Segnale corrente per coppia (per il pannello e i test).
    var signals: [String: CryptoStrategy.Signal] = [:]
    /// Prezzi live letti nel ciclo (badge LIVE).
    var livePrices: [String: Double] = [:]
    /// Equity letta a inizio ciclo.
    var equity: Double?
    /// Budget per coppia effettivo.
    var budgetPerPair: Double = 0
    /// true se il ciclo ha girato fino in fondo (dati compresi).
    var dataOK = false
}

/// Un ciclo live della modalità CRYPTO (gira ogni 60 secondi a app aperta).
///
/// Ordine delle operazioni, ogni tick:
/// 1. conto: equity e cassa; il picco dell'equity si aggiorna (per il blocco
///    drawdown al 10%, ferreo e calcolato in codice);
/// 2. barre 1D chiuse di ogni coppia + prezzo live (badge LIVE);
/// 3. riconciliazione: le posizioni del registro ancora vive sul broker?
///    Se lo stop stop_limit GTC è scattato ad app chiusa, la posizione va
///    tolta dal registro (il broker ha già venduto);
/// 4. solo se c'è una barra NUOVA (nuovo giorno): segnale V4 ->
///    uscita (prima si annulla lo stop, poi vendita a mercato),
///    ingresso (ordine `simple` frazionato, poi stop_limit di protezione),
///    aggiornamento chandelier (stop alzato solo se sale davvero).
struct CryptoCycleRunner: Sendable {
    let broker: any CryptoBrokerClient
    /// Quanto deve salire il chandelier perché lo stop venga sostituito.
    var stopRaiseTolerance = 0.002
    /// Buffer del limit sotto lo stop (garanzia di esecuzione).
    var stopLimitBuffer = 0.002

    func run(_ input: CryptoCycleInput,
             emit: @Sendable (CryptoCycleEvent) async -> Void) async -> CryptoCycleResult {
        var book = input.book
        var result = CryptoCycleResult(book: book)

        // 1. Conto e blocco drawdown (ferreo, in codice: nessun LLM).
        // Se il motore si sta fermando (STOP manuale) il task viene cancellato:
        // NON è un errore del broker e non va loggato come tale.
        let account: BrokerAccount
        do {
            account = try await broker.account()
        } catch is CancellationError {
            result.book = book
            return result
        } catch {
            await emit(.init(stage: .scout, state: .failed, detail: "conto non raggiungibile",
                             log: "CRYPTO: conto Alpaca non raggiungibile (\(error.localizedDescription)); ciclo saltato.", agent: .scout))
            result.book = book
            return result
        }
        result.equity = account.equity
        let totalBudget = min(account.equity, input.capitalCap)
        result.budgetPerPair = CryptoStrategy.positionBudget(total: totalBudget, cash: account.cash)
        if book.cashPeak == nil || account.equity > (book.cashPeak ?? 0) {
            book.cashPeak = account.equity
        }
        let ddBlocked = CryptoStrategy.drawdownBlocked(equity: account.equity, peak: book.cashPeak)
        var entryBlock = input.entryBlock
        if ddBlocked { entryBlock = "stop drawdown 10% crypto" }

        // 2. Barre chiuse + prezzi live. La CancellationError (STOP del motore
        // durante il ciclo) esce in silenzio; un errore di dati per una coppia
        // è il fallback noto: quella coppia salta il tick, le altre continuano.
        var bars: [String: [Candle]] = [:]
        for pair in input.pairs {
            do {
                bars[pair] = try await broker.cryptoBars(symbol: pair)
            } catch is CancellationError {
                result.book = book
                return result
            } catch {
                bars[pair] = []
            }
            do {
                result.livePrices[pair] = try await broker.latestPrice(symbol: pair)
            } catch is CancellationError {
                result.book = book
                return result
            } catch {
                result.livePrices[pair] = 0
            }
        }
        let pairsWithData = input.pairs.filter { (bars[$0]?.count ?? 0) >= CryptoStrategy.smaPeriod }
        if pairsWithData.isEmpty {
            await emit(.init(stage: .scout, state: .failed,
                             detail: "storico insufficiente (servono \(CryptoStrategy.smaPeriod) barre)",
                             log: "CRYPTO: nessuna coppia con \(CryptoStrategy.smaPeriod) barre chiuse (rate-limit o disservizio dati); il motore riprova al prossimo tick.", agent: .scout))
            result.book = book
            return result
        }
        // Fallback silenzioso: una coppia senza dati non blocca le altre.
        let missingPairs = input.pairs.filter { !pairsWithData.contains($0) }
        if !missingPairs.isEmpty {
            await emit(.init(stage: .scout, state: .done,
                             detail: "\(missingPairs.count) coppie senza dati: si riprova al prossimo tick",
                             log: "CRYPTO: senza dati in questo tick: \(missingPairs.joined(separator: ", ")); le altre coppie continuano.", agent: .scout))
        }
        result.dataOK = pairsWithData.count == input.pairs.count

        // 3. Riconciliazione con le posizioni reali sul broker.
        for position in book.positions {
            guard let brokerQty = try? await broker.positionQty(symbol: position.symbol) else {
                continue // errore di rete: si riprova al prossimo tick
            }
            if brokerQty <= 0.00000001 {
                await emit(.init(log: "\(position.symbol): la posizione non è più sul broker (stop eseguito o chiusura manuale); tolta dal registro.", agent: .risk,
                                 notify: (title: "CRYPTO: \(position.symbol) chiusa",
                                          body: "La posizione non risulta più sul broker (stop stop_limit o chiusura manuale).")))
                if let stopId = position.stopOrderId { try? await broker.cancelOrder(id: stopId) }
                book.remove(symbol: position.symbol)
            } else if abs(brokerQty - position.qty) > 0.00000001 {
                await emit(.init(log: "\(position.symbol): quantità sul broker (\(brokerQty)) diversa dal registro (\(position.qty)); registro riallineato.", agent: .risk))
                var updated = position
                updated.qty = brokerQty
                if let stopId = position.stopOrderId { try? await broker.cancelOrder(id: stopId) }
                updated.stopOrderId = nil
                book.upsert(updated)
            }
        }

        // 4. Segnali: SOLO su barra nuova (lo stesso giorno non firma due volte).
        for pair in pairsWithData {
            guard let closedBars = bars[pair], let last = closedBars.last else { continue }
            let day = Self.barDay(last)
            let isNewBar = book.evaluatedBars[pair] != day
            let heldHighest = book.position(pair)?.highestClose
            guard let signal = CryptoStrategy.evaluate(symbol: pair, closedBars: closedBars,
                                                       heldHighestClose: heldHighest) else { continue }
            result.signals[pair] = signal
            guard isNewBar else { continue }
            book.evaluatedBars[pair] = day

            switch signal.state {
            case .warmup, .flat:
                continue
            case .exit:
                guard let position = book.position(pair) else { continue }
                await emit(.init(stage: .executor, state: .working, detail: "esco da \(pair)",
                                 log: "CRYPTO \(pair): chiusura sotto chandelier o SMA200; uscita a mercato (stop annullato prima della vendita).", agent: .risk))
                if let stopId = position.stopOrderId {
                    _ = try? await broker.cancelOrder(id: stopId) // prima lo stop: mai la doppia vendita
                }
                if let orderId = try? await broker.submitMarket(symbol: pair, quantity: position.qty,
                                                                side: "sell",
                                                                clientOrderId: "qsc-sell-\(pair)-\(day)"),
                   let status = try? await broker.orderStatus(orderId: orderId) {
                    await emit(.init(log: "CRYPTO \(pair): vendita inviata (ordine \(orderId), stato \(status)).", agent: .system))
                } else {
                    await emit(.init(log: "CRYPTO \(pair): vendita NON riuscita; la posizione resta in registro e si riprova al prossimo tick.", agent: .risk))
                    continue
                }
                let estimated = position.entryPrice > 0 ? (signal.close / position.entryPrice - 1) * position.qty * position.entryPrice : nil
                result.exits.append(CryptoExit(symbol: pair, reason: "chandelier o SMA200", estimatedPnL: estimated))
                book.remove(symbol: pair)
            case .entry:
                guard book.position(pair) == nil, entryBlock == nil else { continue }
                guard let qty = CryptoStrategy.fractionalQty(budget: result.budgetPerPair,
                                                             price: signal.close) else {
                    await emit(.init(log: "CRYPTO \(pair): budget \(Int(result.budgetPerPair)) USD troppo piccolo per un ordine frazionato; ingresso saltato.", agent: .risk))
                    continue
                }
                let clientOrderId = "qsc-buy-\(pair)-\(day)"
                guard let orderId = try? await broker.submitMarket(symbol: pair, quantity: qty,
                                                                   side: "buy", clientOrderId: clientOrderId) else {
                    await emit(.init(stage: .executor, state: .failed, detail: "\(pair): ordine rifiutato",
                                     log: "CRYPTO \(pair): ordine d'ingresso rifiutato dal broker; nessuna posizione aperta.", agent: .risk))
                    continue
                }
                // Quantità realmente riempita (fill parziale: si tiene quella):
                // lo stop GTC copre esattamente la quantità in portafoglio.
                var positionQty = qty
                if let filled = try? await broker.filledQuantity(orderId: orderId), filled > 0, filled < qty {
                    positionQty = filled
                    await emit(.init(log: "CRYPTO \(pair): fill parziale (\(filled) su \(qty)).", agent: .system))
                }
                // Appena filled: stop stop_limit GTC di protezione sul broker.
                let stop = signal.close - CryptoStrategy.chandelierATR * signal.atr22
                let stopId = (try? await broker.submitStopLimit(symbol: pair, quantity: positionQty,
                                                                 stopPrice: stop,
                                                                 limitPrice: stop * (1 - stopLimitBuffer),
                                                                 clientOrderId: "qsc-stop-\(pair)-\(day)"))
                var position = CryptoBook.Position(symbol: pair, entryDay: day,
                                                    entryPrice: signal.close, qty: positionQty,
                                                    highestClose: signal.close,
                                                    stopOrderId: stopId, stopPrice: stop)
                book.upsert(position)
                result.orders.append(CryptoPlacedOrder(symbol: pair, orderId: orderId,
                                                       quantity: positionQty,
                                                       entryPrice: signal.close, stopPrice: stop))
                await emit(.init(stage: .executor, state: .done,
                                 detail: "\(pair): comprato \(position.qty) @ ~\(signal.close), stop GTC \(stop)",
                                 log: "CRYPTO \(pair): ingresso \(position.qty) a ~\(String(format: "%.2f", signal.close)) USD (rottura Donchian20 sopra SMA200); stop stop_limit GTC a \(String(format: "%.2f", stop)) sul broker.", agent: .system,
                                 notify: (title: "CRYPTO: ingresso \(pair)",
                                         body: "Rottura Donchian20 sopra SMA200: comprati \(position.qty) con stop GTC a \(String(format: "%.2f", stop)) USD.")))
            case .hold:
                guard var position = book.position(pair) else { continue }
                let newHighest = max(position.highestClose, signal.close)
                let newStop = newHighest - CryptoStrategy.chandelierATR * signal.atr22
                position.highestClose = newHighest
                // Lo stop segue solo verso l'ALTO: il rischio non cresce mai.
                if let oldStop = position.stopPrice, newStop > oldStop * (1 + stopRaiseTolerance) {
                    if let oldId = position.stopOrderId { _ = try? await broker.cancelOrder(id: oldId) }
                    let stopId = try? await broker.submitStopLimit(symbol: pair, quantity: position.qty,
                                                                    stopPrice: newStop,
                                                                    limitPrice: newStop * (1 - stopLimitBuffer),
                                                                    clientOrderId: "qsc-stop-\(pair)-\(day)")
                    position.stopOrderId = stopId
                    position.stopPrice = newStop
                    await emit(.init(log: "CRYPTO \(pair): chandelier salito, stop aggiornato a \(String(format: "%.2f", newStop)) USD (GTC).", agent: .risk))
                }
                book.upsert(position)
            }
        }

        // 5. Riepilogo SCOUT del ciclo: UNA riga sola a tick, e il motore la
        // ripete solo se cambia (deduplica in applyCrypto). Prima il log
        // taceva quando non c'era nulla da fare e non si capiva perché tutte
        // le coppie fossero FUORI; ora il ciclo dice sempre stato e motivo:
        // sotto SMA200 (regime ribassista, non si opera) o in attesa di
        // rottura, con il livello Donchian20 da superare.
        var summaryParts: [String] = []
        for pair in input.pairs {
            let short = Self.shortName(pair)
            guard let signal = result.signals[pair] else {
                summaryParts.append("\(short) senza dati")
                continue
            }
            switch signal.state {
            case .warmup: summaryParts.append("\(short) dati insufficienti")
            case .flat: summaryParts.append("\(short) \(signal.flatShortText)")
            case .entry: summaryParts.append("\(short) ingresso")
            case .hold: summaryParts.append("\(short) in posizione")
            case .exit: summaryParts.append("\(short) uscita")
            }
        }
        let drawdownText = ddBlocked ? "drawdown FERMO (−10%)" : "drawdown ok"
        let blockText = (entryBlock != nil && !ddBlocked) ? " · ingressi bloccati" : ""
        await emit(.init(log: "CRYPTO ciclo: \(summaryParts.joined(separator: " · ")) · posizioni \(book.positions.count)/\(input.pairs.count) · budget \(Int(result.budgetPerPair.rounded())) USD/coppia · \(drawdownText)\(blockText)",
                         agent: .scout))

        result.book = book
        return result
    }

    /// Nome breve della coppia per i log: "BTC/USD" -> "BTC".
    static func shortName(_ pair: String) -> String {
        pair.hasSuffix("/USD") ? String(pair.dropLast(4)) : pair
    }

    /// Chiave barra: giorno UTC della chiusura (YYYY-MM-DD).
    static func barDay(_ candle: Candle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: candle.timestamp)
    }
}

/// Alpaca come broker crypto del ciclo.
struct AlpacaCryptoBroker: CryptoBrokerClient {
    let service: AlpacaService

    func account() async throws -> BrokerAccount {
        let snapshot = try await service.account()
        return BrokerAccount(equity: snapshot.equityValue, cash: snapshot.cashValue,
                              buyingPower: snapshot.buyingPowerValue)
    }

    func cryptoBars(symbol: String) async throws -> [Candle] {
        try await service.cryptoDailyBars(symbols: [symbol], barsPerSymbol: CryptoStrategy.smaPeriod + 20)
            .values.first ?? []
    }

    func latestPrice(symbol: String) async throws -> Double {
        let quotes = try await service.latestCryptoQuotes(symbols: [symbol])
        guard let mid = quotes[symbol], mid > 0 else {
            throw QuantSwarmError.invalidServerResponse("Quotazione crypto non disponibile")
        }
        return mid
    }

    func positionQty(symbol: String) async throws -> Double {
        // Le posizioni crypto usano lo stesso simbolo della coppia ("BTC/USD").
        let all = try await service.positions()
        return all.first { $0.symbol == symbol }?.quantityValue ?? 0
    }

    func submitMarket(symbol: String, quantity: Double, side: String,
                      clientOrderId: String) async throws -> String {
        try await service.submitCryptoMarket(symbol: symbol, quantity: quantity,
                                             side: side, clientOrderId: clientOrderId).id
    }

    func submitStopLimit(symbol: String, quantity: Double, stopPrice: Double,
                         limitPrice: Double, clientOrderId: String) async throws -> String {
        try await service.submitCryptoStopLimit(symbol: symbol, quantity: quantity,
                                                stopPrice: stopPrice, limitPrice: limitPrice,
                                                clientOrderId: clientOrderId).id
    }

    func cancelOrder(id: String) async throws {
        try await service.cancelOrder(id: id)
    }

    func orderStatus(orderId: String) async throws -> String {
        try await service.order(id: orderId).status
    }

    func filledQuantity(orderId: String) async throws -> Double {
        try await service.order(id: orderId).filledQuantityValue
    }
}
