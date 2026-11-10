import Foundation

// MARK: - Interfacce verso broker e Kimi (sostituibili nei test)

struct BrokerAccount: Sendable, Equatable {
    let equity: Double
    let cash: Double
    let buyingPower: Double
}

struct BrokerPosition: Sendable, Equatable {
    let symbol: String
    let quantity: Double
    let averageEntryPrice: Double?
    let unrealizedPL: Double
}

struct BrokerOrder: Sendable, Equatable {
    let id: String
    let symbol: String
    let side: String
    let type: String
    let status: String
    let quantity: Double
    let filledQuantity: Double
    let stopPrice: Double?
    let parentOrderId: String?
    let submittedAt: Date?

    var isEntry: Bool { parentOrderId == nil && side == "buy" }
    var isProtectiveStop: Bool { side == "sell" && (type == "stop" || type == "stop_limit") }
}

/// Tutto ciò che il ciclo giornaliero chiede al broker.
protocol BrokerClient: Sendable {
    func isMarketOpen() async throws -> Bool
    func account() async throws -> BrokerAccount
    func positions() async throws -> [BrokerPosition]
    func openOrders() async throws -> [BrokerOrder]
    func dailyBars(symbol: String) async throws -> [Candle]
    func latestPrice(symbol: String) async throws -> Double
    func cancelOrder(id: String) async throws
    /// Chiude a mercato; ritorna l'id dell'ordine di chiusura (nil se il broker
    /// non lo restituisce). Lancia solo se la chiusura è stata rifiutata.
    func closePosition(symbol: String) async throws -> String?
    func submitEntryWithStop(symbol: String, quantity: Double, limitPrice: Double,
                             stopPrice: Double, clientOrderId: String) async throws -> String
    func submitStop(symbol: String, quantity: Double, stopPrice: Double) async throws -> String
    func orderId(byClientOrderId: String) async throws -> String?
    func filledAveragePrice(orderId: String) async throws -> Double?
}

/// Brain e Reviewer della modalità giornaliera (Kimi).
protocol DailyBrain: Sendable {
    func decide(candidates: [DailyStrategy.Candidate], market: [String: DailyStrategy.Snapshot],
                openPositions: [String], slots: Int) async throws -> [DailyVerdict]
    func review(candidate: DailyStrategy.Candidate, verdict: DailyVerdict,
                market: [String: DailyStrategy.Snapshot]) async throws -> KimiReview
}

// MARK: - Ciclo giornaliero (logica pura + chiamate tramite interfacce)

struct DailyCycleInput: Sendable {
    var book: DailyBook
    let today: String
    let riskFraction: Double
    let maxOpenPositions: Int
    /// nil = si possono aprire nuove posizioni; altrimenti il motivo del blocco.
    let entryBlock: String?
}

struct DailyCycleEvent: Sendable {
    var stage: PipelineStageID?
    var state: PipelineState = .done
    var detail: String = ""
    var log: String?
    var agent: AgentKind = .system
    var notify: (title: String, body: String)?
}

struct DailyPlacedOrder: Sendable, Equatable {
    let symbol: String
    let orderId: String
    let quantity: Double
    let limitPrice: Double
    let stopPrice: Double
    let atr: Double
    let verdict: DailyVerdict
}

struct DailyExit: Sendable, Equatable {
    let symbol: String
    let reason: DailyStrategy.ExitReason
    /// P&L dal prezzo di esecuzione reale, se disponibile.
    let realizedPnL: Double?
}

struct DailyCycleResult: Sendable {
    var book: DailyBook
    var candidates: [DailyStrategy.Candidate] = []
    var verdicts: [DailyVerdict] = []
    var orders: [DailyPlacedOrder] = []
    var exits: [DailyExit] = []
    var kimiCalls = 0
    var marketOpen = false
    var aborted = false
}

struct DailyCycleRunner: Sendable {
    let broker: any BrokerClient
    let brain: any DailyBrain
    var basket: [String] = DailyStrategy.basket
    var exitFillWaitSeconds: Double = 2.0

    func run(_ input: DailyCycleInput, emit: @Sendable (DailyCycleEvent) async -> Void) async -> DailyCycleResult {
        var result = DailyCycleResult(book: input.book)
        var book = input.book
        let today = input.today

        // 1. SCOUT
        await emit(.init(stage: .scout, state: .working, detail: "leggo conto, posizioni e \(basket.count) ETF"))
        let marketOpen: Bool
        let account: BrokerAccount
        let positions: [BrokerPosition]
        var orders: [BrokerOrder]
        do {
            marketOpen = try await broker.isMarketOpen()
            account = try await broker.account()
            positions = try await broker.positions()
            orders = try await broker.openOrders()
        } catch {
            await emit(.init(stage: .scout, state: .failed, detail: "broker non raggiungibile",
                             log: "Scout: broker non raggiungibile (\(error.localizedDescription)); ciclo annullato, nessun ordine.", agent: .scout))
            result.aborted = true
            return result
        }
        result.marketOpen = marketOpen
        var bars: [String: [Candle]] = [:]
        var missing: [String] = []
        for symbol in basket {
            if Task.isCancelled { result.aborted = true; return result }
            if let raw = try? await broker.dailyBars(symbol: symbol) {
                bars[symbol] = DailyStrategy.closedBars(raw, marketOpen: marketOpen)
            } else {
                missing.append(symbol)
            }
        }
        guard !bars.isEmpty else {
            await emit(.init(stage: .scout, state: .failed, detail: "nessuna barra ricevuta",
                             log: "Scout: barre giornaliere non disponibili; ciclo annullato (nessun ordine).", agent: .scout))
            result.aborted = true
            return result
        }
        await emit(.init(stage: .scout, state: .done,
                         detail: "\(bars.count)/\(basket.count) ETF aggiornati"
                            + (missing.isEmpty ? "" : " · mancano \(missing.joined(separator: ", "))")
                            + " · mercato \(marketOpen ? "aperto" : "chiuso")"))
        var market: [String: DailyStrategy.Snapshot] = [:]
        for symbol in ["SPY", "QQQ", "IWM", "TLT", "GLD"] {
            if let b = bars[symbol], let s = DailyStrategy.snapshot(of: b) { market[symbol] = s }
        }

        // 2. STRATEGIA: manutenzione, protezione, uscite.
        await emit(.init(stage: .strategy, state: .working, detail: "controllo stop, uscite e segnali"))
        var held = Dictionary(positions.map { ($0.symbol.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })

        // Posizioni chiuse dal broker (stop eseguito o chiusura manuale).
        let pendingEntrySymbols = Set(orders.filter(\.isEntry).map { $0.symbol.uppercased() })
        for symbol in book.entries.keys.sorted() where held[symbol] == nil && !pendingEntrySymbols.contains(symbol) {
            book.remove(symbol)
            await emit(.init(log: "\(symbol): posizione non più presente sul broker (stop eseguito o chiusa a mano); registro aggiornato.", agent: .risk))
        }
        // Ingressi dei giorni precedenti: il residuo non eseguito si annulla
        // (anche se eseguiti in parte: si tiene solo la quantità già comprata).
        for order in orders where order.isEntry && basket.contains(order.symbol.uppercased()) {
            let symbol = order.symbol.uppercased()
            guard let day = book.entries[symbol], day < today else { continue }
            do {
                try await broker.cancelOrder(id: order.id)
                if held[symbol] == nil { book.remove(symbol) }
                let partial = order.filledQuantity > 0 ? " (eseguito in parte: \(Int(order.filledQuantity)) az. restano in portafoglio)" : ""
                await emit(.init(log: "\(symbol): residuo dell'ordine d'ingresso del \(day) annullato\(partial).", agent: .risk))
            } catch {
                await emit(.init(log: "\(symbol): annullo del residuo non riuscito (\(error.localizedDescription)).", agent: .risk))
            }
        }
        if let refreshed = try? await broker.openOrders() { orders = refreshed }

        // PROTEZIONE: ogni posizione della giornaliera deve avere uno stop sul broker.
        for symbol in book.entries.keys.sorted() {
            guard let position = held[symbol], position.quantity > 0 else { continue }
            let covered = orders.filter { $0.symbol.uppercased() == symbol && $0.isProtectiveStop }
                .reduce(0) { $0 + max($1.quantity - $1.filledQuantity, 0) }
            guard covered + 1e-9 < position.quantity else { continue }
            let missingQty = position.quantity - covered
            guard let stop = protectiveStopPrice(symbol: symbol, book: book, bars: bars[symbol]) else {
                await emit(.init(log: "\(symbol): ATTENZIONE posizione senza stop e prezzo di stop non calcolabile.", agent: .risk,
                                 notify: ("POSIZIONE SENZA STOP", "\(symbol): controlla il broker")))
                continue
            }
            do {
                _ = try await broker.submitStop(symbol: symbol, quantity: missingQty, stopPrice: stop)
                book.stops[symbol] = stop
                await emit(.init(log: "\(symbol): mancava lo stop per \(Int(missingQty)) az.; stop GTC a \(fmt(stop)) rimesso sul broker.", agent: .risk,
                                 notify: ("STOP RIPRISTINATO", "\(symbol) a \(fmt(stop))")))
            } catch {
                await emit(.init(log: "\(symbol): ATTENZIONE stop non ripristinato (\(error.localizedDescription)).", agent: .risk,
                                 notify: ("POSIZIONE SENZA STOP", "\(symbol): controlla il broker")))
            }
        }

        // USCITE a regole: solo a mercato aperto (a mercato chiuso lo stop resta).
        var exited: Set<String> = []
        for symbol in book.entries.keys.sorted() {
            guard let position = held[symbol], let b = bars[symbol], let day = book.entries[symbol],
                  let reason = DailyStrategy.exitReason(bars: b, entryDay: day) else { continue }
            guard marketOpen else {
                await emit(.init(log: "\(symbol): regola d'uscita (\(reason.rawValue)); mercato chiuso, lo stop resta e si esce alla prossima seduta con l'app aperta.", agent: .risk))
                continue
            }
            await emit(.init(stage: .executor, state: .working, detail: "chiudo \(symbol): \(reason.rawValue)"))
            switch await exit(symbol: symbol, position: position, book: book, bars: b) {
            case .closed(let fill):
                exited.insert(symbol)
                let pnl = fill.flatMap { price in position.averageEntryPrice.map { (price - $0) * position.quantity } }
                    ?? position.unrealizedPL
                result.exits.append(DailyExit(symbol: symbol, reason: reason, realizedPnL: pnl))
                book.remove(symbol)
                held[symbol] = nil
                await emit(.init(stage: .executor, state: .done, detail: "chiuso \(symbol)",
                                 log: "\(symbol): USCITA — \(reason.rawValue). P&L \(fmt(pnl)) USD.", agent: .risk,
                                 notify: ("USCITA \(symbol)", "\(reason.rawValue) · P&L \(fmt(pnl)) USD")))
            case .failedStopRestored(let message):
                await emit(.init(stage: .executor, state: .failed, detail: "\(symbol): uscita fallita, stop rimesso",
                                 log: "\(symbol): uscita non riuscita (\(message)); stop rimesso sul broker, riprovo al prossimo ciclo.", agent: .risk,
                                 notify: ("USCITA NON RIUSCITA", "\(symbol): stop rimesso")))
            case .failedUnprotected(let message):
                await emit(.init(stage: .executor, state: .failed, detail: "\(symbol): SENZA STOP",
                                 log: "\(symbol): ATTENZIONE uscita fallita e stop non ripristinato (\(message)). Controlla subito il broker.", agent: .risk,
                                 notify: ("POSIZIONE SENZA STOP", "\(symbol): controlla subito il broker")))
            }
        }

        // SEGNALI d'ingresso.
        let pendingNow = Set(orders.filter(\.isEntry).map { $0.symbol.uppercased() })
        let candidates = basket.compactMap { symbol -> DailyStrategy.Candidate? in
            guard held[symbol] == nil, !pendingNow.contains(symbol), !exited.contains(symbol),
                  let b = bars[symbol] else { return nil }
            return DailyStrategy.entryCandidate(symbol: symbol, bars: b)
        }
        result.candidates = candidates
        let fresh = candidates.filter { !book.alreadyDecided($0.symbol, day: today) }
        guard !fresh.isEmpty else {
            let text = candidates.isEmpty ? "nessun segnale oggi"
                : "segnali già valutati oggi: \(candidates.map(\.symbol).joined(separator: ", "))"
            await emit(.init(stage: .strategy, state: .done, detail: text, log: "Strategia: \(text). Kimi non chiamato.", agent: .scout))
            await skip(after: .strategy, "nessun segnale nuovo · 0 crediti", emit)
            result.book = book
            return result
        }
        let list = fresh.map { "\($0.symbol) (RSI2 \(String(format: "%.1f", $0.snapshot.rsi2)))" }.joined(separator: ", ")
        await emit(.init(stage: .strategy, state: .done, detail: "segnali: \(list)",
                         log: "Strategia: segnali Trend+Pullback su \(list).", agent: .scout))

        let slots = input.maxOpenPositions - held.count - pendingNow.count
        if let block = input.entryBlock ?? (slots <= 0 ? "già \(input.maxOpenPositions) posizioni/ordini aperti" : nil) {
            await emit(.init(stage: .analyst, state: .blocked, detail: block, log: "Segnali non operati: \(block).", agent: .risk))
            await skip(after: .analyst, block, emit)
            result.book = book
            return result
        }

        // 3. ANALYST: quadro di mercato calcolato in codice (zero crediti).
        let marketText = market.keys.sorted().map { key in
            "\(key) \(market[key]!.close > market[key]!.sma200 ? "sopra" : "sotto") SMA200"
        }.joined(separator: " · ")
        await emit(.init(stage: .analyst, state: .done, detail: marketText.isEmpty ? "quadro non disponibile" : marketText))

        // 4. BRAIN
        await emit(.init(stage: .brain, state: .working, detail: "Kimi valuta \(fresh.count) candidati, \(slots) posti liberi"))
        let verdicts: [DailyVerdict]
        do {
            result.kimiCalls += 1
            verdicts = try await brain.decide(candidates: fresh, market: market,
                                              openPositions: Array(held.keys).sorted(), slots: slots)
        } catch {
            await emit(.init(stage: .brain, state: .failed, detail: "Kimi non ha risposto: nessun ordine",
                             log: "Brain Kimi fallito (\(error.localizedDescription)): nessun ordine.", agent: .brain))
            await skip(after: .brain, "Brain fallito", emit)
            result.book = book
            return result
        }
        for c in fresh { book.markDecided(c.symbol, day: today) }
        result.verdicts = verdicts
        for v in verdicts {
            await emit(.init(log: "\(v.symbol): \(v.wantsBuy ? "BUY" : "SKIP") \(Int(v.confidence * 100))% — \(v.rationale)", agent: .brain))
        }
        let buys = Array(verdicts.filter(\.wantsBuy).sorted { $0.confidence > $1.confidence }.prefix(slots))
        guard !buys.isEmpty else {
            await emit(.init(stage: .brain, state: .done, detail: "nessun acquisto scelto"))
            await skip(after: .brain, "Brain: nessun acquisto", emit)
            result.book = book
            return result
        }
        await emit(.init(stage: .brain, state: .done, detail: "sceglie \(buys.map(\.symbol).joined(separator: ", "))"))

        var equityLeft = account
        for verdict in buys {
            if Task.isCancelled { break }
            let symbol = verdict.symbol.uppercased()
            guard let candidate = fresh.first(where: { $0.symbol == symbol }) else { continue }

            // 5. REVIEWER
            await emit(.init(stage: .reviewer, state: .working, detail: "contesta \(symbol)"))
            let review: KimiReview
            do {
                result.kimiCalls += 1
                review = try await brain.review(candidate: candidate, verdict: verdict, market: market)
            } catch {
                await emit(.init(stage: .reviewer, state: .failed, detail: "\(symbol): revisore non raggiungibile",
                                 log: "\(symbol): reviewer fallito (\(error.localizedDescription)); ordine annullato.", agent: .brain))
                continue
            }
            guard review.approved else {
                await emit(.init(stage: .reviewer, state: .done, detail: "\(symbol) bocciato: \(review.reason)",
                                 log: "\(symbol): REVIEWER respinge — \(review.reason)", agent: .brain))
                continue
            }
            await emit(.init(stage: .reviewer, state: .done, detail: "\(symbol) approvato",
                             log: "\(symbol): reviewer approva — \(review.reason)", agent: .brain))

            // 6. RISCHIO
            await emit(.init(stage: .risk, state: .working, detail: "dimensiono \(symbol)"))
            guard let price = try? await broker.latestPrice(symbol: symbol), price > 0 else {
                await emit(.init(stage: .risk, state: .failed, detail: "\(symbol): prezzo non disponibile",
                                 log: "\(symbol): prezzo attuale non disponibile; ordine annullato.", agent: .risk))
                continue
            }
            let snap = candidate.snapshot
            guard abs(price - snap.close) <= 3 * snap.atr14 else {
                await emit(.init(stage: .risk, state: .blocked, detail: "\(symbol): prezzo lontano dal segnale",
                                 log: "\(symbol): prezzo \(fmt(price)) a oltre 3 ATR dalla chiusura del segnale; ordine annullato.", agent: .risk))
                continue
            }
            let sizing: RiskRules.StopSizing
            switch RiskRules.sizeStopOnly(
                currentPrice: price, stopDistance: candidate.stopDistance,
                account: RiskRules.Account(equity: account.equity, cash: equityLeft.cash, buyingPower: equityLeft.buyingPower),
                riskFraction: input.riskFraction, constraints: .alpacaStock
            ) {
            case .success(let value): sizing = value
            case .failure(let rejection):
                await emit(.init(stage: .risk, state: .blocked, detail: "\(symbol): \(rejection.reason)",
                                 log: "\(symbol): ordine bloccato dal rischio — \(rejection.reason).", agent: .risk))
                continue
            }
            await emit(.init(stage: .risk, state: .done,
                             detail: "\(symbol): \(Int(sizing.quantity)) az. · rischio \(fmt(sizing.riskAmount)) USD · stop \(fmt(sizing.stopPrice))"))

            // 7. ESECUTORE
            await emit(.init(stage: .executor, state: .working, detail: "invio \(symbol)"))
            let clientOrderId = "qsd-\(symbol)-\(today)"
            var orderId: String?
            do {
                orderId = try await broker.submitEntryWithStop(symbol: symbol, quantity: sizing.quantity,
                                                               limitPrice: sizing.limitPrice, stopPrice: sizing.stopPrice,
                                                               clientOrderId: clientOrderId)
            } catch {
                // Timeout: l'ordine potrebbe essere comunque arrivato. Mai un secondo invio.
                orderId = try? await broker.orderId(byClientOrderId: clientOrderId)
                if orderId == nil {
                    await emit(.init(stage: .executor, state: .failed, detail: "\(symbol): invio fallito",
                                     log: "\(symbol): invio ordine fallito: \(error.localizedDescription)", agent: .risk))
                    continue
                }
            }
            guard let orderId else { continue }
            book.entries[symbol] = today
            book.stops[symbol] = sizing.stopPrice
            let notional = sizing.quantity * sizing.limitPrice
            equityLeft = BrokerAccount(equity: account.equity, cash: equityLeft.cash - notional,
                                       buyingPower: equityLeft.buyingPower - notional)
            result.orders.append(DailyPlacedOrder(symbol: symbol, orderId: orderId, quantity: sizing.quantity,
                                                  limitPrice: sizing.limitPrice, stopPrice: sizing.stopPrice,
                                                  atr: snap.atr14, verdict: verdict))
            let text = "\(symbol) \(Int(sizing.quantity)) az. limite \(fmt(sizing.limitPrice)) · stop \(fmt(sizing.stopPrice)) (GTC)"
            await emit(.init(stage: .executor, state: .done, detail: "inviato \(text)",
                             log: "ORDINE INVIATO: \(text)\(marketOpen ? "" : " · in coda per l'apertura").", agent: .risk,
                             notify: ("ORDINE INVIATO", text)))
        }
        if result.orders.isEmpty {
            await emit(.init(stage: .executor, state: .skipped, detail: "nessun ordine da inviare"))
        }
        result.book = book
        return result
    }

    // MARK: - Uscita sicura

    enum ExitOutcome: Equatable {
        case closed(fillPrice: Double?)
        case failedStopRestored(String)
        case failedUnprotected(String)
    }

    /// Annulla lo stop, chiude a mercato; se la chiusura fallisce rimette
    /// subito uno stop equivalente. Mai una posizione lasciata senza stop.
    func exit(symbol: String, position: BrokerPosition, book: DailyBook, bars: [Candle]) async -> ExitOutcome {
        let open = (try? await broker.openOrders()) ?? []
        let mine = open.filter { $0.symbol.uppercased() == symbol }
        let existingStop = mine.first(where: \.isProtectiveStop)?.stopPrice
        for order in mine { try? await broker.cancelOrder(id: order.id) }
        do {
            let closeId = try await broker.closePosition(symbol: symbol)
            var fill: Double?
            if let closeId {
                let deadline = Date().addingTimeInterval(exitFillWaitSeconds)
                repeat {
                    fill = try? await broker.filledAveragePrice(orderId: closeId)
                    if fill != nil { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                } while Date() < deadline
            }
            return .closed(fillPrice: fill)
        } catch {
            // Prima di rimettere lo stop si verifica che la posizione esista
            // ancora: uno stop su una posizione già chiusa aprirebbe uno short.
            guard let current = try? await broker.positions() else {
                return .failedUnprotected("posizione non verificabile: \(error.localizedDescription)")
            }
            guard let still = current.first(where: { $0.symbol.uppercased() == symbol }), still.quantity > 0 else {
                return .closed(fillPrice: nil)
            }
            let stop = existingStop ?? protectiveStopPrice(symbol: symbol, book: book, bars: bars)
            guard let stop else { return .failedUnprotected(error.localizedDescription) }
            do {
                _ = try await broker.submitStop(symbol: symbol, quantity: still.quantity, stopPrice: stop)
                return .failedStopRestored(error.localizedDescription)
            } catch {
                return .failedUnprotected(error.localizedDescription)
            }
        }
    }

    /// Stop di riferimento: quello salvato all'ingresso, altrimenti
    /// ultima chiusura − 2,5 ATR.
    func protectiveStopPrice(symbol: String, book: DailyBook, bars: [Candle]?) -> Double? {
        if let saved = book.stops[symbol], saved > 0 { return saved }
        guard let bars, let s = DailyStrategy.snapshot(of: bars) else { return nil }
        let stop = RiskRules.roundDown(s.close - DailyStrategy.stopATR * s.atr14, tick: 0.01)
        return stop > 0 ? stop : nil
    }

    private func skip(after id: PipelineStageID, _ detail: String, _ emit: @Sendable (DailyCycleEvent) async -> Void) async {
        guard let start = PipelineStageID.allCases.firstIndex(of: id) else { return }
        for stage in PipelineStageID.allCases.dropFirst(start + 1) {
            await emit(.init(stage: stage, state: .skipped, detail: detail))
        }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
