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
    /// Ordine che il broker ha già registrato con questo client_order_id
    /// (nil = non lo conosce). Si usa quando un invio fallisce: la risposta
    /// può essersi persa, o l'app può essersi chiusa a metà dell'operazione.
    func orderRef(byClientOrderId: String) async throws -> BrokerOrderRef?
    /// Stop di vendita ancora vivi sul broker per la coppia.
    func openSellStops(symbol: String) async throws -> [CryptoOpenStop]
}

/// Stop di vendita vivo sul broker (quantità ancora da eseguire).
struct CryptoOpenStop: Sendable, Equatable {
    let id: String
    let quantity: Double
    let stopPrice: Double?
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
///    tolta dal registro (il broker ha già venduto); se invece la posizione
///    è viva ma lo stop MANCA (invio fallito, cancellato, quantità cambiata)
///    viene ri-coperto qui: SELF-HEALING, stesso livello chandelier;
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
    /// Dopo un ordine a mercato o un annullo si aspetta la conferma del
    /// broker: su Alpaca sono asincroni (l'ordine nasce "pending_new",
    /// l'annullo passa da "pending_cancel") e finché non sono chiusi la
    /// quantità resta impegnata. Fino a `confirmAttempts` letture dello
    /// stato, una ogni `confirmDelayNanoseconds`.
    var confirmAttempts = 5
    var confirmDelayNanoseconds: UInt64 = 700_000_000
    /// Tolleranza sulle quantità crypto (8 decimali).
    static let qtyEpsilon = 0.00000001

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
        // Contante ancora libero in QUESTO ciclo: due ingressi nello stesso
        // tick non possono spendere due volte gli stessi dollari.
        var cashLeft = account.cash

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
        //    SELF-HEALING dello stop: sul crypto Alpaca non esistono ordini
        //    bracket (422), quindi se lo stop protettivo manca (invio fallito
        //    all'ingresso, stop cancellato a mano sul broker, quantità
        //    cambiata) la posizione resterebbe SCOPERTA finché il chandelier
        //    non sale. Ogni tick ogni posizione viva senza stop confermato
        //    viene ri-coperta allo stesso livello chandelier del registro.
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
                book.stopAlerts?[position.symbol] = nil
                continue
            }
            var updated = position
            var stopMissing = false
            if abs(brokerQty - position.qty) > Self.qtyEpsilon {
                await emit(.init(log: "\(position.symbol): quantità sul broker (\(brokerQty)) diversa dal registro (\(position.qty)); registro riallineato.", agent: .risk))
                // Lo stop vecchio copriva la quantità sbagliata: via quello,
                // poi la ricopertura qui sotto ne mette uno della misura giusta.
                if let stopId = position.stopOrderId { _ = await cancelAndConfirm(stopId) }
                updated.qty = brokerQty
                updated.stopOrderId = nil
                stopMissing = true
            } else if let stopId = position.stopOrderId {
                // Stop registrato: è ancora VIVO sul broker?
                if let status = try? await broker.orderStatus(orderId: stopId) {
                    stopMissing = Self.isStopTerminal(status)
                } // errore di rete sullo stato: NIENTE doppi stop alla cieca,
                  // si considera vivo e si riprova al prossimo tick.
            } else {
                stopMissing = true // stop mai arrivato (invio fallito all'ingresso)
            }
            if stopMissing, let stopPrice = updated.stopPrice, stopPrice > 0 {
                // Prima di rimetterlo si guarda il broker: lo stop può esserci
                // già (risposta persa all'invio, app chiusa a metà). Adottarlo
                // evita il doppio stop, che il broker rifiuterebbe a ogni tick.
                let liveStops = (try? await broker.openSellStops(symbol: position.symbol)) ?? []
                if let found = liveStops.first(where: { covers($0, qty: updated.qty, minStop: stopPrice) }) {
                    updated.stopOrderId = found.id
                    book.stopAlerts?[position.symbol] = nil
                    await emit(.init(log: "CRYPTO \(position.symbol): lo stop protettivo era già sul broker (ordine \(found.id)); registro riallineato, nessun doppio stop.", agent: .risk))
                } else {
                    // Stop vivi della misura sbagliata o più bassi del livello
                    // del registro: impegnano la quantità, vanno tolti prima.
                    for stale in liveStops { _ = await cancelAndConfirm(stale.id) }
                    let repairId = "qsc-stopfix-\(CryptoSymbol.key(position.symbol))-\(input.today)-\(Int(Date().timeIntervalSince1970))"
                    if let stopId = await placeStop(pair: position.symbol, qty: updated.qty,
                                                    stopPrice: stopPrice, clientOrderId: repairId) {
                        updated.stopOrderId = stopId
                        book.stopAlerts?[position.symbol] = nil
                        await emit(.init(log: "CRYPTO \(position.symbol): stop protettivo RIPRISTINATO sul broker (stop_limit GTC a \(String(format: "%.2f", stopPrice)) USD, quantità \(updated.qty)): era assente o non copriva la posizione.", agent: .risk,
                                         notify: (title: "CRYPTO: stop ripristinato \(position.symbol)",
                                                  body: "La posizione era senza stop: rimesso stop_limit GTC a \(String(format: "%.2f", stopPrice)) USD.")))
                    } else if book.stopAlerts?[position.symbol] != input.today {
                        // Un avviso al giorno per coppia: il tentativo si
                        // ripete a ogni ciclo, la notifica no.
                        var alerts = book.stopAlerts ?? [:]
                        alerts[position.symbol] = input.today
                        book.stopAlerts = alerts
                        await emit(.init(log: "CRYPTO \(position.symbol): stop assente e ripristino NON riuscito; posizione scoperta, nuovo tentativo a ogni ciclo (60 s). Se il prezzo è già sotto lo stop (\(String(format: "%.2f", stopPrice)) USD) il broker non lo accetta: l'uscita arriva alla prossima chiusura giornaliera.", agent: .risk,
                                         notify: (title: "CRYPTO: \(position.symbol) senza stop",
                                                  body: "Ripristino dello stop protettivo non riuscito: l'app riprova a ogni ciclo (60 s). Controlla il conto.")))
                    }
                }
            }
            book.upsert(updated)
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
            // La barra si segna come valutata; se l'operazione resta a metà
            // per un motivo passeggero (rete, blocco temporaneo, annullo non
            // confermato) il segno torna indietro e il prossimo tick riprova.
            let previousMark = book.evaluatedBars[pair]
            book.evaluatedBars[pair] = day
            let live = result.livePrices[pair] ?? 0
            let pairKey = CryptoSymbol.key(pair)

            switch signal.state {
            case .warmup, .flat:
                continue
            case .exit:
                guard let position = book.position(pair) else { continue }
                await emit(.init(stage: .executor, state: .working, detail: "esco da \(pair)",
                                 log: "CRYPTO \(pair): chiusura sotto chandelier o SMA200; uscita a mercato (stop annullato prima della vendita).", agent: .risk))
                // Prima lo stop (mai la doppia vendita), e si aspetta che il
                // broker lo dia per annullato: finché è "pending_cancel" la
                // quantità è impegnata e la vendita verrebbe rifiutata.
                if let stopId = position.stopOrderId, !(await cancelAndConfirm(stopId)) {
                    book.evaluatedBars[pair] = previousMark
                    if !Task.isCancelled {
                        await emit(.init(log: "CRYPTO \(pair): lo stop non risulta ancora annullato; vendita rimandata al prossimo tick (lo stop resta a protezione).", agent: .risk))
                    }
                    continue
                }
                // Stesso client_order_id a ogni tentativo: se il broker ha già
                // registrato la vendita (risposta persa) la si ritrova e non
                // si vende due volte. Un id "bruciato" da un ordine morto
                // passa al successivo, al massimo tre per barra.
                var soldId: String?
                var sellFrozen = false
                sellLoop: for suffix in ["", "-r2", "-r3"] {
                    switch await placeMarket(pair: pair, qty: position.qty, side: "sell",
                                             clientOrderId: "qsc-sell-\(pairKey)-\(day)\(suffix)") {
                    case .placed(let orderId, _):
                        soldId = orderId
                        break sellLoop
                    case .rejected(let frozen, let registered):
                        sellFrozen = frozen
                        if !registered { break sellLoop }
                    case .unknown:
                        break sellLoop
                    }
                }
                guard let orderId = soldId else {
                    // La vendita non è partita: la barra torna da valutare e
                    // il prossimo tick riprova (la riconciliazione rimette
                    // intanto lo stop appena annullato).
                    book.evaluatedBars[pair] = previousMark
                    if !Task.isCancelled {
                        await emit(.init(log: sellFrozen
                            ? "CRYPTO \(pair): vendita rifiutata: il conto Alpaca ha il TRADING SOSPESO (voce \"trades suspended\" del conto). Toglila con SISTEMA → RIATTIVA TRADING, poi ripremi START; la posizione resta in registro."
                            : "CRYPTO \(pair): vendita NON riuscita; la posizione resta in registro e si riprova al prossimo tick (60 s).", agent: .risk))
                    }
                    continue
                }
                await emit(.init(log: "CRYPTO \(pair): vendita inviata (ordine \(orderId)).", agent: .system))
                let exitPrice = live > 0 ? live : signal.close
                let estimated = position.entryPrice > 0 ? (exitPrice - position.entryPrice) * position.qty : nil
                result.exits.append(CryptoExit(symbol: pair, reason: "chandelier o SMA200", estimatedPnL: estimated))
                book.remove(symbol: pair)
                book.stopAlerts?[pair] = nil
            case .entry:
                guard book.position(pair) == nil else { continue }
                guard entryBlock == nil else {
                    // Blocco passeggero (app in background, drawdown): il
                    // segnale della barra resta valido e si rivaluta al
                    // prossimo tick, quando il blocco può essere caduto.
                    book.evaluatedBars[pair] = previousMark
                    continue
                }
                // Si compra al prezzo di ADESSO, non alla chiusura di ieri:
                // l'app può essere stata aperta ore dopo la barra.
                guard live > 0 else {
                    book.evaluatedBars[pair] = previousMark
                    await emit(.init(log: "CRYPTO \(pair): segnale d'ingresso ma prezzo live non disponibile; nessun ordine, si riprova al prossimo tick.", agent: .risk))
                    continue
                }
                let stop = signal.close - CryptoStrategy.chandelierATR * signal.atr22
                guard stop > 0, live > stop else {
                    await emit(.init(log: "CRYPTO \(pair): ingresso saltato: il prezzo live (\(String(format: "%.2f", live)) USD) è già sotto lo stop della barra di rottura (\(String(format: "%.2f", stop)) USD).", agent: .risk))
                    continue
                }
                let budget = CryptoStrategy.positionBudget(total: totalBudget, cash: cashLeft)
                guard let qty = CryptoStrategy.fractionalQty(budget: budget, price: live) else {
                    await emit(.init(log: "CRYPTO \(pair): budget \(Int(budget)) USD troppo piccolo per un ordine frazionato; ingresso saltato.", agent: .risk))
                    continue
                }
                let clientOrderId = "qsc-buy-\(pairKey)-\(day)"
                let orderId: String
                switch await placeMarket(pair: pair, qty: qty, side: "buy", clientOrderId: clientOrderId) {
                case .placed(let id, let recovered):
                    orderId = id
                    if recovered {
                        await emit(.init(log: "CRYPTO \(pair): l'ordine d'ingresso di questa barra era già sul broker (\(clientOrderId)); adottato, nessun doppio acquisto.", agent: .risk))
                    }
                case .rejected(let frozen, _):
                    await emit(.init(stage: .executor, state: .failed, detail: "\(pair): ordine rifiutato",
                                     log: frozen
                                        ? "CRYPTO \(pair): ordine rifiutato: il conto Alpaca ha il TRADING SOSPESO (voce \"trades suspended\" del conto). Toglila con SISTEMA → RIATTIVA TRADING, poi ripremi START: nessuna posizione aperta."
                                        : "CRYPTO \(pair): ordine d'ingresso rifiutato dal broker; nessuna posizione aperta.", agent: .risk))
                    continue
                case .unknown:
                    // Non si sa se l'ordine è arrivato: niente in registro, e
                    // al prossimo tick lo si cerca sul broker prima di rinviarlo.
                    book.evaluatedBars[pair] = previousMark
                    if !Task.isCancelled {
                        await emit(.init(stage: .executor, state: .failed, detail: "\(pair): invio non confermato",
                                         log: "CRYPTO \(pair): invio dell'ordine d'ingresso non confermato (rete o broker non raggiungibile); al prossimo tick si controlla sul broker prima di rinviarlo.", agent: .risk))
                    }
                    continue
                }
                // Si aspetta l'esecuzione: lo stop si può mettere solo su
                // quantità che il conto ha davvero.
                guard let filled = await settledBuyQuantity(orderId: orderId) else {
                    book.evaluatedBars[pair] = previousMark
                    if !Task.isCancelled {
                        await emit(.init(log: "CRYPTO \(pair): stato dell'ordine d'ingresso non leggibile; al prossimo tick si ricontrolla sul broker (nessun doppio acquisto: stesso identificativo).", agent: .risk))
                    }
                    continue
                }
                guard filled > Self.qtyEpsilon else {
                    await emit(.init(stage: .executor, state: .failed, detail: "\(pair): ordine non eseguito",
                                     log: "CRYPTO \(pair): l'ordine d'ingresso non si è eseguito ed è stato chiuso; nessuna posizione aperta.", agent: .risk))
                    continue
                }
                // Quantità REALE in portafoglio: su Alpaca la commissione
                // crypto si paga nella moneta comprata, quindi il conto ne ha
                // un po' meno dell'eseguito. Lo stop copre quella.
                var positionQty = filled
                if let held = try? await broker.positionQty(symbol: pair), held > Self.qtyEpsilon {
                    positionQty = min(held, filled)
                }
                if positionQty < qty - Self.qtyEpsilon {
                    await emit(.init(log: "CRYPTO \(pair): in portafoglio \(positionQty) su \(qty) ordinati (fill parziale o commissione pagata in moneta).", agent: .system))
                }
                cashLeft = max(cashLeft - positionQty * live, 0)
                // Appena eseguito: stop stop_limit GTC di protezione sul broker.
                let stopId = await placeStop(pair: pair, qty: positionQty, stopPrice: stop,
                                             clientOrderId: "qsc-stop-\(pairKey)-\(day)")
                let position = CryptoBook.Position(symbol: pair, entryDay: day,
                                                    entryPrice: live, qty: positionQty,
                                                    highestClose: signal.close,
                                                    stopOrderId: stopId, stopPrice: stop)
                book.upsert(position)
                result.orders.append(CryptoPlacedOrder(symbol: pair, orderId: orderId,
                                                       quantity: positionQty,
                                                       entryPrice: live, stopPrice: stop))
                if stopId != nil {
                    await emit(.init(stage: .executor, state: .done,
                                     detail: "\(pair): comprato \(position.qty) @ ~\(live), stop GTC \(stop)",
                                     log: "CRYPTO \(pair): ingresso \(position.qty) a ~\(String(format: "%.2f", live)) USD (rottura Donchian20 sopra SMA200); stop stop_limit GTC a \(String(format: "%.2f", stop)) sul broker.", agent: .system,
                                     notify: (title: "CRYPTO: ingresso \(pair)",
                                             body: "Rottura Donchian20 sopra SMA200: comprati \(position.qty) con stop GTC a \(String(format: "%.2f", stop)) USD.")))
                } else {
                    // Onestà nel log: senza questo ramo il ciclo diceva "stop
                    // sul broker" anche quando l'invio era fallito.
                    await emit(.init(stage: .executor, state: .done,
                                     detail: "\(pair): comprato \(position.qty) @ ~\(live), STOP MANCANTE (riparo al prossimo ciclo)",
                                     log: "CRYPTO \(pair): ingresso \(position.qty) a ~\(String(format: "%.2f", live)) USD (rottura Donchian20 sopra SMA200). ATTENZIONE: lo stop GTC NON è stato accettato dal broker; la posizione è scoperta e il prossimo ciclo la ri-copre (max 60 s).", agent: .risk,
                                     notify: (title: "CRYPTO: ingresso \(pair) senza stop",
                                             body: "Comprati \(position.qty); lo stop GTC non è stato accettato: ripristino automatico al prossimo ciclo (60 s).")))
                }
            case .hold:
                guard var position = book.position(pair) else { continue }
                let newHighest = max(position.highestClose, signal.close)
                let newStop = newHighest - CryptoStrategy.chandelierATR * signal.atr22
                position.highestClose = newHighest
                // Lo stop segue solo verso l'ALTO: il rischio non cresce mai.
                if let oldStop = position.stopPrice, newStop > oldStop * (1 + stopRaiseTolerance) {
                    if live > 0, newStop >= live {
                        // Il prezzo di adesso è già sotto il nuovo livello: il
                        // broker non accetterebbe lo stop. Quello vecchio non
                        // si tocca; se la chiusura di oggi resta sotto il
                        // chandelier, domani la regola fa uscire.
                        await emit(.init(log: "CRYPTO \(pair): chandelier salito a \(String(format: "%.2f", newStop)) USD ma il prezzo live (\(String(format: "%.2f", live))) è già sotto: resta lo stop a \(String(format: "%.2f", oldStop)) USD.", agent: .risk))
                    } else if let oldId = position.stopOrderId, !(await cancelAndConfirm(oldId)) {
                        // Annullo non confermato: lo stop vecchio resta dov'è
                        // e si riprova al prossimo tick, mai due stop insieme.
                        book.evaluatedBars[pair] = previousMark
                        if !Task.isCancelled {
                            await emit(.init(log: "CRYPTO \(pair): lo stop vecchio non risulta ancora annullato; l'aggiornamento a \(String(format: "%.2f", newStop)) USD si riprova al prossimo tick.", agent: .risk))
                        }
                    } else {
                        let stopId = await placeStop(pair: pair, qty: position.qty, stopPrice: newStop,
                                                     clientOrderId: "qsc-stop-\(pairKey)-\(day)")
                        position.stopOrderId = stopId
                        position.stopPrice = newStop
                        await emit(.init(log: stopId != nil
                            ? "CRYPTO \(pair): chandelier salito, stop aggiornato a \(String(format: "%.2f", newStop)) USD (GTC)."
                            : "CRYPTO \(pair): chandelier salito a \(String(format: "%.2f", newStop)) USD ma il nuovo stop NON è stato accettato; il prossimo ciclo lo rimette (60 s).", agent: .risk))
                    }
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

    // MARK: - Ordini senza doppioni

    private enum MarketOutcome: Sendable {
        /// L'ordine è sul broker. `recovered` = ritrovato per client_order_id
        /// dopo un invio che sembrava fallito.
        case placed(orderId: String, recovered: Bool)
        /// Il broker ha detto no. `registered` = l'ordine esiste ma è morto
        /// (rifiutato o annullato): quel client_order_id non è più riusabile.
        case rejected(frozen: Bool, registered: Bool)
        /// Non si sa se l'ordine è arrivato (rete caduta, ricerca fallita).
        case unknown
    }

    /// Invio di un ordine a mercato che non può raddoppiare: se l'invio
    /// fallisce, prima di concludere che l'ordine non c'è lo si cerca sul
    /// broker con lo stesso client_order_id.
    private func placeMarket(pair: String, qty: Double, side: String,
                             clientOrderId: String) async -> MarketOutcome {
        do {
            let id = try await broker.submitMarket(symbol: pair, quantity: qty, side: side,
                                                   clientOrderId: clientOrderId)
            return .placed(orderId: id, recovered: false)
        } catch {
            let frozen = QuantSwarmError.isAccountFrozen(error)
            do {
                if let ref = try await broker.orderRef(byClientOrderId: clientOrderId) {
                    return ref.countsAsPlaced ? .placed(orderId: ref.id, recovered: true)
                                              : .rejected(frozen: frozen, registered: true)
                }
            } catch {
                return .unknown
            }
            return Self.isBrokerRefusal(error) ? .rejected(frozen: frozen, registered: false) : .unknown
        }
    }

    /// true se l'errore è un no esplicito del broker (HTTP 4xx): l'ordine non
    /// esiste e rimandarlo uguale non serve. Rete caduta, timeout, troppe
    /// richieste (429) ed errori del server (5xx) non lo sono.
    static func isBrokerRefusal(_ error: Error) -> Bool {
        guard let known = error as? QuantSwarmError, case .httpStatus(let code, _) = known else {
            return false
        }
        return (400..<500).contains(code) && code != 408 && code != 429
    }

    private func pause() async {
        guard confirmDelayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: confirmDelayNanoseconds)
    }

    /// Annulla un ordine e aspetta che il broker lo dia per chiuso.
    /// true = l'ordine non impegna più la quantità (annullato, eseguito,
    /// scaduto o rifiutato).
    private func cancelAndConfirm(_ orderId: String) async -> Bool {
        _ = try? await broker.cancelOrder(id: orderId)
        let attempts = max(confirmAttempts, 1)
        for attempt in 0..<attempts {
            if let status = try? await broker.orderStatus(orderId: orderId), Self.isStopTerminal(status) {
                return true
            }
            if attempt + 1 < attempts { await pause() }
        }
        return false
    }

    /// Aspetta l'esecuzione dell'ordine d'ingresso e ritorna la quantità
    /// comprata. Se dopo l'attesa non è completo, il residuo si annulla: la
    /// posizione non deve crescere dopo che lo stop è stato messo.
    /// nil = lo stato non si riesce a leggere (non si sa cosa è successo).
    private func settledBuyQuantity(orderId: String) async -> Double? {
        var lastStatus: String?
        let attempts = max(confirmAttempts, 1)
        for attempt in 0..<attempts {
            lastStatus = try? await broker.orderStatus(orderId: orderId)
            if let seen = lastStatus, Self.isStopTerminal(seen) { break }
            if attempt + 1 < attempts { await pause() }
        }
        guard let finalStatus = lastStatus else { return nil }
        if !Self.isStopTerminal(finalStatus) {
            // Ancora aperto (in tutto o in parte): il residuo si annulla.
            guard await cancelAndConfirm(orderId) else { return nil }
        }
        return try? await broker.filledQuantity(orderId: orderId)
    }

    /// Lo stop vivo copre la quantità a un livello non più basso di `minStop`?
    private func covers(_ stop: CryptoOpenStop, qty: Double, minStop: Double) -> Bool {
        abs(stop.quantity - qty) <= Self.qtyEpsilon
            && (stop.stopPrice ?? 0) >= minStop * (1 - stopRaiseTolerance)
    }

    /// Mette lo stop protettivo. Se l'invio fallisce (o la risposta si perde)
    /// cerca sul broker uno stop vivo della stessa misura e lo adotta: mai
    /// uno stop creduto assente quando c'è.
    private func placeStop(pair: String, qty: Double, stopPrice: Double,
                           clientOrderId: String) async -> String? {
        if let id = try? await broker.submitStopLimit(symbol: pair, quantity: qty,
                                                      stopPrice: stopPrice,
                                                      limitPrice: stopPrice * (1 - stopLimitBuffer),
                                                      clientOrderId: clientOrderId) {
            return id
        }
        guard let liveStops = try? await broker.openSellStops(symbol: pair) else { return nil }
        return liveStops.first { covers($0, qty: qty, minStop: stopPrice) }?.id
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

    /// Stati terminali di un ordine Alpaca: per lo stop protettivo significano
    /// "non copre più la posizione" (eseguito, cancellato, scaduto, rifiutato).
    /// "filled" con la posizione ancora viva = fill parziale dello stop: resta
    /// una quantità da ri-coprire.
    static func isStopTerminal(_ status: String) -> Bool {
        ["filled", "canceled", "cancelled", "expired", "rejected"].contains(status.lowercased())
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
        // L'elenco posizioni scrive la coppia SENZA barra ("BTCUSD"), gli
        // ordini e i dati con la barra ("BTC/USD"): il confronto passa da
        // CryptoSymbol, altrimenti la posizione risulterebbe sempre assente.
        let all = try await service.positions()
        return CryptoSymbol.quantity(of: symbol, in: all.map { (symbol: $0.symbol, quantity: $0.quantityValue) })
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

    func orderRef(byClientOrderId clientOrderId: String) async throws -> BrokerOrderRef? {
        guard let order = try await service.order(byClientOrderId: clientOrderId) else { return nil }
        return BrokerOrderRef(id: order.id, status: order.status)
    }

    func openSellStops(symbol: String) async throws -> [CryptoOpenStop] {
        let wanted = CryptoSymbol.key(symbol)
        return try await service.openOrders()
            .filter { CryptoSymbol.key($0.symbol) == wanted && $0.side.lowercased() == "sell"
                && ["stop_limit", "stop"].contains($0.type.lowercased()) }
            .map { CryptoOpenStop(id: $0.id,
                                  quantity: max($0.quantityValue - $0.filledQuantityValue, 0),
                                  stopPrice: $0.stopPriceValue) }
    }
}
