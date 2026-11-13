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
    var isTakeProfit: Bool { side == "sell" && type == "limit" }
}

/// Riferimento a un ordine ritrovato per client_order_id dopo un invio
/// fallito. Lo stato conta: un ordine rifiutato o annullato NON è un invio
/// riuscito, riprovarlo non è un duplicato (gli stati "morti" sono quelli
/// da cui un ordine non può più eseguirsi; lista da
/// docs.alpaca.markets/reference/postorder).
struct BrokerOrderRef: Sendable, Equatable {
    let id: String
    let status: String

    /// Stati vivi di Alpaca (un ordine si può annullare finché non è
    /// filled/canceled/expired) più "filled": l'ordine esiste sul broker e
    /// può eseguirsi o si è già eseguito.
    var countsAsPlaced: Bool {
        ["new", "partially_filled", "accepted", "pending_new", "pending_replace",
         "pending_cancel", "held", "done_for_day", "filled"].contains(status)
    }
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
    /// Ingresso limite con stop (e take-profit, se indicato) sul broker, GTC.
    func submitEntryWithStop(symbol: String, quantity: Double, limitPrice: Double,
                             stopPrice: Double, takeProfitPrice: Double?, clientOrderId: String) async throws -> String
    func submitStop(symbol: String, quantity: Double, stopPrice: Double) async throws -> String
    /// Recupero dopo un invio fallito: ritorna l'ordine solo se esiste sul
    /// broker E può ancora eseguirsi (o è già eseguito); nil o stato morto
    /// (rejected/canceled/expired) = da trattare come non inviato.
    func orderRef(byClientOrderId: String) async throws -> BrokerOrderRef?
    func filledAveragePrice(orderId: String) async throws -> Double?
    /// Titoli delle notizie recenti (Benzinga via Alpaca) per i simboli dati.
    func news(symbols: [String], hours: Int) async throws -> [NewsHeadline]
}

extension BrokerClient {
    /// Di base nessuna notizia (es. broker finti nei test).
    func news(symbols: [String], hours: Int) async throws -> [NewsHeadline] { [] }
}

/// Una notizia: titolo, quando, a quali simboli si riferisce.
struct NewsHeadline: Sendable, Equatable, Identifiable {
    let id: Int
    let headline: String
    let createdAt: Date
    let symbols: [String]
    let source: String
    let url: String?

    /// Riga compatta per Kimi: "11/11 14:05 · titolo".
    var compact: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "MM/dd HH:mm"
        return "\(f.string(from: createdAt)) ET · \(headline)"
    }

    /// Fino a `limit` notizie per un candidato: prima quelle sul suo simbolo,
    /// poi quelle sul mercato (SPY, QQQ), senza doppioni, le più recenti prima.
    static func pick(for symbol: String, from all: [NewsHeadline], market: Set<String> = ["SPY", "QQQ"],
                     limit: Int = 8) -> [NewsHeadline] {
        let sorted = all.sorted { $0.createdAt > $1.createdAt }
        let own = sorted.filter { $0.symbols.contains(symbol) }
        let general = sorted.filter { !$0.symbols.contains(symbol) && !market.isDisjoint(with: $0.symbols) }
        var seen = Set<Int>()
        return (own + general).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
}

/// Brain e Reviewer della modalità giornaliera (Kimi).
protocol DailyBrain: Sendable {
    func decide(candidates: [DailyStrategy.Candidate], market: [String: DailyStrategy.Snapshot],
                openPositions: [String], slots: Int, feedback: String?,
                shadow: ShadowDigest?) async throws -> [DailyVerdict]
    func review(candidate: DailyStrategy.Candidate, verdict: DailyVerdict,
                market: [String: DailyStrategy.Snapshot], shadow: ShadowDigest?) async throws -> KimiReview
}

// MARK: - Ciclo giornaliero (logica pura + chiamate tramite interfacce)

struct DailyCycleInput: Sendable {
    var book: DailyBook
    let today: String
    let riskFraction: Double
    let maxOpenPositions: Int
    /// nil = si possono aprire nuove posizioni; altrimenti il motivo del blocco.
    let entryBlock: String?
    /// Capitale massimo che il bot può impegnare (USD). Rischio e tetto per
    /// posizione si calcolano su min(patrimonio, capitale); oltre, niente ingressi.
    var capitalCap: Double = .infinity
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
    let takeProfitPrice: Double
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
    /// Patrimonio letto dal broker a inizio ciclo (per la curva del capitale).
    var equity: Double?
    /// Ultima chiusura giornaliera di SPY (riferimento della curva).
    var benchmarkClose: Double?
    /// Valore impegnato dal bot (posizioni + ingressi pendenti) dopo le uscite.
    var botExposure: Double = 0
    /// Prezzo e volatilità di ogni ETF del paniere (per "ETF comprabili").
    var snapshots: [String: DailyStrategy.Snapshot] = [:]
    /// Barre giornaliere chiuse di ogni ETF (grafici della vista MERCATI).
    var bars: [String: [Candle]] = [:]
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
        } catch is CancellationError {
            // STOP del motore durante il ciclo: non è un errore del broker.
            result.aborted = true
            return result
        } catch {
            await emit(.init(stage: .scout, state: .failed, detail: "broker non raggiungibile",
                             log: "Scout: broker non raggiungibile (\(error.localizedDescription)); ciclo annullato, nessun ordine.", agent: .scout))
            result.aborted = true
            return result
        }
        result.marketOpen = marketOpen
        result.equity = account.equity
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
        result.benchmarkClose = bars["SPY"]?.last?.close
        for (symbol, b) in bars {
            if let snap = DailyStrategy.snapshot(of: b) { result.snapshots[symbol] = snap }
        }
        result.bars = bars
        var market: [String: DailyStrategy.Snapshot] = [:]
        for symbol in ["SPY", "QQQ", "IWM", "TLT", "GLD"] {
            if let b = bars[symbol], let s = DailyStrategy.snapshot(of: b) { market[symbol] = s }
        }

        // 2. STRATEGIA: manutenzione, protezione, uscite.
        await emit(.init(stage: .strategy, state: .working, detail: "controllo stop, uscite e segnali"))
        // Registro ombra: chiude gli esiti ipotetici maturati.
        for index in book.shadow.indices where !book.shadow[index].resolved {
            let entry = book.shadow[index]
            if let b = bars[entry.symbol], let exit = ShadowEvaluator.resolve(entry, bars: b) {
                book.shadow[index].exitPrice = exit.price
                book.shadow[index].exitDay = exit.day
            }
        }
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
                if order.filledQuantity > 0 { book.partialEntries += 1 } else { book.unfilledEntries += 1 }
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
            // Un take-profit rimasto senza il suo stop gemello va annullato prima:
            // due vendite scollegate potrebbero scattare entrambe e aprire uno short.
            for orphan in orders where orphan.symbol.uppercased() == symbol && orphan.isTakeProfit {
                try? await broker.cancelOrder(id: orphan.id)
            }
            do {
                _ = try await broker.submitStop(symbol: symbol, quantity: missingQty, stopPrice: stop)
                book.stops[symbol] = stop
                await emit(.init(log: "\(symbol): mancava lo stop per \(Int(missingQty)) az.; stop GTC a \(fmt(stop)) rimesso sul broker.", agent: .risk,
                                 notify: ("STOP RIPRISTINATO", "\(symbol) a \(fmt(stop))")))
            } catch {
                if QuantSwarmError.isAccountFrozen(error) {
                    await emit(.init(log: "\(symbol): stop non ripristinato: il conto Alpaca ha il TRADING SOSPESO. Toglila con SISTEMA → RIATTIVA TRADING, poi ripremi START.", agent: .risk,
                                     notify: ("POSIZIONE SENZA STOP", "\(symbol): conto Alpaca sospeso, riattiva il trading")))
                } else {
                    await emit(.init(log: "\(symbol): ATTENZIONE stop non ripristinato (\(error.localizedDescription)).", agent: .risk,
                                     notify: ("POSIZIONE SENZA STOP", "\(symbol): controlla il broker")))
                }
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

        // CAPITALE DEL BOT: quanto è già impegnato (posizioni del bot al prezzo
        // dell'ultima chiusura + residuo degli ingressi pendenti).
        let exposure = book.entries.keys.reduce(0.0) { sum, symbol in
            let price = bars[symbol]?.last?.close ?? held[symbol]?.averageEntryPrice ?? 0
            let heldQty = held[symbol]?.quantity ?? 0
            let pendingQty = orders.filter { $0.isEntry && $0.symbol.uppercased() == symbol }
                .reduce(0) { $0 + max($1.quantity - $1.filledQuantity, 0) }
            return sum + max(heldQty + pendingQty, 0) * price
        }
        result.botExposure = exposure
        let botAccount = RiskRules.capped(
            RiskRules.Account(equity: account.equity, cash: account.cash, buyingPower: account.buyingPower),
            capital: input.capitalCap, exposure: exposure
        )

        // SEGNALI d'ingresso.
        let pendingNow = Set(orders.filter(\.isEntry).map { $0.symbol.uppercased() })
        let candidates = basket.compactMap { symbol -> DailyStrategy.Candidate? in
            guard held[symbol] == nil, !pendingNow.contains(symbol), !exited.contains(symbol),
                  let b = bars[symbol] else { return nil }
            return DailyStrategy.entryCandidate(symbol: symbol, bars: b)
        }
        result.candidates = candidates
        let undecided = candidates.filter { !book.alreadyDecided($0.symbol, day: today) }
        guard !undecided.isEmpty else {
            let text = candidates.isEmpty ? "nessun segnale oggi"
                : "segnali già valutati oggi: \(candidates.map(\.symbol).joined(separator: ", "))"
            await emit(.init(stage: .strategy, state: .done, detail: text, log: "Strategia: \(text). Kimi non chiamato.", agent: .scout))
            await skip(after: .strategy, "nessun segnale nuovo · 0 crediti", emit)
            result.book = book
            return result
        }
        let list = undecided.map { "\($0.symbol) (RSI2 \(String(format: "%.1f", $0.snapshot.rsi2)))" }.joined(separator: ", ")
        await emit(.init(stage: .strategy, state: .done, detail: "segnali: \(list)",
                         log: "Strategia: segnali Trend+Pullback su \(list).", agent: .scout))

        let slots = input.maxOpenPositions - held.count - pendingNow.count
        // Solo i candidati di cui il capitale del bot può comprare almeno 1 azione
        // (contante libero, tetto per posizione, rischio per trade) arrivano a
        // Kimi: niente crediti spesi per ordini che il Rischio boccerebbe.
        var fresh = undecided.filter { c in
            RiskRules.canBuyOneShare(price: c.snapshot.close, stopDistance: c.stopDistance,
                                     capital: botAccount.equity, freeCash: botAccount.cash,
                                     riskFraction: input.riskFraction)
        }
        // Notizie delle ultime 48 ore: candidati e mercato in due richieste
        // separate, così le tante notizie su SPY non coprono quelle dell'ETF.
        if !fresh.isEmpty {
            let own = (try? await broker.news(symbols: fresh.map(\.symbol).sorted(), hours: 48)) ?? []
            let market = (try? await broker.news(symbols: ["QQQ", "SPY"], hours: 48)) ?? []
            let headlines = own + market
            for index in fresh.indices {
                fresh[index].news = NewsHeadline.pick(for: fresh[index].symbol, from: headlines).map(\.compact)
            }
        }
        // Correlazioni con le posizioni aperte e tra i candidati (60 sedute).
        let others = Array(held.keys) + fresh.map(\.symbol)
        for index in fresh.indices {
            let symbol = fresh[index].symbol
            guard let mine = bars[symbol] else { continue }
            for other in Set(others) where other != symbol {
                if let theirs = bars[other], let rho = DailyStrategy.correlation(mine, theirs) {
                    fresh[index].correlations[other] = (rho * 100).rounded() / 100
                }
            }
        }
        let capitalBlock = fresh.isEmpty
            ? "capitale bot insufficiente per 1 azione (libero \(fmt(botAccount.cash)) su \(fmt(botAccount.equity)) USD, impegnati \(fmt(exposure)))"
            : nil
        if let block = input.entryBlock ?? (slots <= 0 ? "già \(input.maxOpenPositions) posizioni/ordini aperti" : nil) ?? capitalBlock {
            await emit(.init(stage: .analyst, state: .blocked, detail: block, log: "Segnali non operati: \(block).", agent: .risk))
            await skip(after: .analyst, block, emit)
            result.book = book
            return result
        }

        // 3. ANALYST: quadro di mercato calcolato in codice (zero crediti).
        let marketText = market.sorted { $0.key < $1.key }.map { key, snap in
            "\(key) \(snap.close > snap.sma200 ? "sopra" : "sotto") SMA200"
        }.joined(separator: " · ")
        await emit(.init(stage: .analyst, state: .done, detail: marketText.isEmpty ? "quadro non disponibile" : marketText))

        // 4. BRAIN
        await emit(.init(stage: .brain, state: .working, detail: "Kimi valuta \(fresh.count) candidati, \(slots) posti liberi"))
        // Digest del registro ombra (ultimi 10 esiti misurati) per l'auto-correzione
        // dei bias di Brain e Reviewer: leggero per costruzione.
        let shadowDigest = ShadowDigest.from(book.shadow)
        let verdicts: [DailyVerdict]
        do {
            result.kimiCalls += 1
            verdicts = try await brain.decide(candidates: fresh, market: market,
                                              openPositions: Array(held.keys).sorted(), slots: slots,
                                              feedback: ShadowSummary.from(book.shadow).feedbackText,
                                              shadow: shadowDigest)
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
        let ranked = verdicts.filter(\.wantsBuy).sorted { $0.confidence > $1.confidence }
        let buys = Array(ranked.prefix(slots))
        // Esito di ogni candidato per il registro ombra (default: scartato).
        var status = Dictionary(fresh.map { ($0.symbol, ShadowEntry.brainSkip) }, uniquingKeysWith: { a, _ in a })
        for extra in ranked.dropFirst(slots) { status[extra.symbol.uppercased()] = ShadowEntry.noSlot }
        func recordShadow(_ book: inout DailyBook) async {
            for candidate in fresh {
                let s = candidate.snapshot
                // Prova in ombra del filtro evento 48h (candidato PROPOSTE.md):
                // registra solo, non cambia nessuna decisione né ordine.
                let eventful = EventFilter48h.isEventful(candidate.news)
                if eventful, let words = EventFilter48h.matchedKeywords(in: candidate.news).first {
                    await emit(.init(log: "\(candidate.symbol): evento in giro (\"\(words)\" nelle notizie 48h): il filtro evento l'avrebbe saltato. Prova in ombra, nessun cambiamento.", agent: .system))
                }
                book.addShadow(ShadowEntry(
                    symbol: candidate.symbol, day: today, entry: s.close,
                    stop: s.close - DailyStrategy.stopATR * s.atr14,
                    outcome: status[candidate.symbol] ?? ShadowEntry.brainSkip,
                    eventFlag: eventful
                ))
            }
        }
        guard !buys.isEmpty else {
            await emit(.init(stage: .brain, state: .done, detail: "nessun acquisto scelto"))
            await skip(after: .brain, "Brain: nessun acquisto", emit)
            await recordShadow(&book)
            result.book = book
            return result
        }
        await emit(.init(stage: .brain, state: .done, detail: "sceglie \(buys.map(\.symbol).joined(separator: ", "))"))

        var equityLeft = botAccount
        for verdict in buys {
            if Task.isCancelled { break }
            let symbol = verdict.symbol.uppercased()
            guard let candidate = fresh.first(where: { $0.symbol == symbol }) else { continue }

            // 5. REVIEWER
            await emit(.init(stage: .reviewer, state: .working, detail: "contesta \(symbol)"))
            let review: KimiReview
            do {
                result.kimiCalls += 1
                review = try await brain.review(candidate: candidate, verdict: verdict, market: market,
                                                shadow: shadowDigest)
            } catch {
                status[symbol] = ShadowEntry.blocked
                await emit(.init(stage: .reviewer, state: .failed, detail: "\(symbol): revisore non raggiungibile",
                                 log: "\(symbol): reviewer fallito (\(error.localizedDescription)); ordine annullato.", agent: .brain))
                continue
            }
            guard review.approved else {
                status[symbol] = ShadowEntry.reviewerReject
                await emit(.init(stage: .reviewer, state: .done, detail: "\(symbol) bocciato: \(review.reason)",
                                 log: "\(symbol): REVIEWER respinge — \(review.reason)", agent: .brain))
                continue
            }
            await emit(.init(stage: .reviewer, state: .done, detail: "\(symbol) approvato",
                             log: "\(symbol): reviewer approva — \(review.reason)", agent: .brain))

            // 6. RISCHIO
            status[symbol] = ShadowEntry.blocked
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
                account: equityLeft,
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
            let takeProfit = RiskRules.roundDown(sizing.limitPrice + DailyStrategy.takeProfitATR * snap.atr14, tick: 0.01)
            var orderId: String?
            do {
                orderId = try await broker.submitEntryWithStop(symbol: symbol, quantity: sizing.quantity,
                                                               limitPrice: sizing.limitPrice, stopPrice: sizing.stopPrice,
                                                               takeProfitPrice: takeProfit,
                                                               clientOrderId: clientOrderId)
            } catch {
                // Timeout: l'ordine potrebbe essere comunque arrivato. Mai un secondo invio,
                // ma solo se l'ordine ritrovato è vivo: uno rifiutato non protegge nessuno.
                if let ref = try? await broker.orderRef(byClientOrderId: clientOrderId), ref.countsAsPlaced {
                    orderId = ref.id
                }
                if orderId == nil {
                    if QuantSwarmError.isAccountFrozen(error) {
                        await emit(.init(stage: .executor, state: .failed, detail: "\(symbol): conto sospeso",
                                         log: "\(symbol): ordine rifiutato: il conto Alpaca ha il TRADING SOSPESO (voce \"trades suspended\" del conto). Toglila con SISTEMA → RIATTIVA TRADING direttamente dall'app, poi ripremi START: finché è attiva il broker rifiuta TUTTI i nuovi ordini.", agent: .risk))
                    } else {
                        await emit(.init(stage: .executor, state: .failed, detail: "\(symbol): invio fallito",
                                         log: "\(symbol): invio ordine fallito: \(error.localizedDescription)", agent: .risk))
                    }
                    continue
                }
            }
            guard let orderId else { continue }
            status[symbol] = ShadowEntry.bought
            book.placedEntries += 1
            book.entries[symbol] = today
            book.stops[symbol] = sizing.stopPrice
            let notional = sizing.quantity * sizing.limitPrice
            equityLeft = RiskRules.Account(equity: botAccount.equity, cash: max(equityLeft.cash - notional, 0),
                                           buyingPower: max(equityLeft.buyingPower - notional, 0))
            result.orders.append(DailyPlacedOrder(symbol: symbol, orderId: orderId, quantity: sizing.quantity,
                                                  limitPrice: sizing.limitPrice, stopPrice: sizing.stopPrice,
                                                  takeProfitPrice: takeProfit, atr: snap.atr14, verdict: verdict))
            let text = "\(symbol) \(Int(sizing.quantity)) az. limite \(fmt(sizing.limitPrice)) · stop \(fmt(sizing.stopPrice)) · target \(fmt(takeProfit)) (GTC)"
            await emit(.init(stage: .executor, state: .done, detail: "inviato \(text)",
                             log: "ORDINE INVIATO: \(text)\(marketOpen ? "" : " · in coda per l'apertura").", agent: .risk,
                             notify: ("ORDINE INVIATO", text)))
        }
        if result.orders.isEmpty {
            await emit(.init(stage: .executor, state: .skipped, detail: "nessun ordine da inviare"))
        }
        await recordShadow(&book)
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
            // "0 crediti" solo sugli agenti Kimi (Rischio ed Esecutore sono codice).
            let text = stage.usesKimi ? detail : detail.replacingOccurrences(of: " · 0 crediti", with: "")
            await emit(.init(stage: stage, state: .skipped, detail: text))
        }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
