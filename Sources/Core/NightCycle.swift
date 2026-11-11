import Foundation

/// Modalità NOTTE: compra in chiusura (asta MOC), vende all'apertura del giorno
/// dopo (asta OPG). Studio tools/backtest_overnight.py, 2006–oggi, costi 0,003%
/// per lato: CAGR circa +8%, max drawdown circa −22%, Sharpe 0,81; positivo
/// anche sui gemelli economici. Solo regole, nessuna chiamata a Kimi: è un
/// effetto statistico, non c'è niente da giudicare caso per caso.
///
/// Paniere: S&P 500, Nasdaq-100, Russell 2000 e oro a peso uguale. Per ogni
/// indice si compra l'ETF originale se il capitale lo permette, altrimenti il
/// gemello economico: segue sempre il saldo del conto.
enum NightStrategy {
    struct Family: Sendable, Equatable {
        let index: String
        /// Dal più grande (originale) al più economico.
        let symbols: [String]
    }

    static let families: [Family] = [
        Family(index: "S&P 500", symbols: ["SPY", "SPYM"]),
        Family(index: "Nasdaq-100", symbols: ["QQQ", "QQQM"]),
        Family(index: "Russell 2000", symbols: ["IWM", "VTWO"]),
        Family(index: "Oro", symbols: ["GLD", "GLDM"])
    ]
    static let universe: [String] = families.flatMap(\.symbols)
    /// Parte del capitale tenuta libera: l'asta di chiusura si esegue a un
    /// prezzo che non si conosce prima.
    static let cashBuffer = 0.03
    /// Ultimo invio utile prima della chiusura (Alpaca rifiuta le MOC dopo le 15:50).
    static let closeCutoffMinutes = 10.0

    enum Phase: Equatable, Sendable {
        /// Mercato chiuso: si può mettere la vendita all'apertura (OPG).
        case sellWindow
        /// Mercato aperto, prima del limite: si può comprare in chiusura (MOC).
        case buyWindow
        /// Finestra in cui Alpaca rifiuta le aste: si aspetta.
        case wait(String)
    }

    /// Minuti dalla mezzanotte di New York.
    static func minutesET(_ date: Date) -> Int {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "America/New_York")!, from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Regole di Alpaca: le OPG si accettano dalle 19:00 alle 9:28 di New York,
    /// le MOC fino alle 15:50 (qui con 10 minuti di margine sulla chiusura,
    /// così vale anche nei giorni a orario ridotto).
    static func phase(now: Date, isOpen: Bool, nextClose: Date?) -> Phase {
        if isOpen {
            if let close = nextClose, close.timeIntervalSince(now) > closeCutoffMinutes * 60 {
                return .buyWindow
            }
            return .wait("troppo vicino alla chiusura per l'asta: si compra domani")
        }
        let m = minutesET(now)
        if m >= 9 * 60 + 28 && m < 9 * 60 + 30 {
            return .wait("apertura fra pochi minuti: vendita all'apertura non più accettata")
        }
        if m >= 16 * 60 && m < 19 * 60 {
            return .wait("le vendite all'apertura si accettano dalle 19:00 di New York (01:00 in Italia)")
        }
        return .sellWindow
    }

    struct Pick: Sendable, Equatable {
        let symbol: String
        let quantity: Int
        let price: Double
    }

    /// Divide il budget a peso uguale fra i 4 indici in azioni intere.
    /// Per ogni indice: l'originale se costa al massimo un quarto del budget,
    /// altrimenti il gemello. Poi si aggiunge un'azione alla volta all'indice
    /// che pesa meno, finché il budget lo permette.
    static func allocate(budget: Double, prices: [String: Double]) -> [Pick] {
        guard budget > 0 else { return [] }
        let slot = budget / Double(families.count)
        var chosen: [(symbol: String, price: Double)] = []
        for family in families {
            let available = family.symbols.compactMap { s in prices[s].flatMap { $0 > 0 ? (s, $0) : nil } }
            guard !available.isEmpty else { continue }
            let pick = available.first { $0.1 <= slot } ?? available.min { $0.1 < $1.1 }!
            chosen.append((pick.0, pick.1))
        }
        var qty = Array(repeating: 0, count: chosen.count)
        var left = budget
        while true {
            let options = chosen.indices.filter { chosen[$0].price <= left }
            guard let next = options.min(by: {
                Double(qty[$0]) * chosen[$0].price < Double(qty[$1]) * chosen[$1].price
            }) else { break }
            qty[next] += 1
            left -= chosen[next].price
        }
        return chosen.indices.compactMap { i in
            qty[i] > 0 ? Pick(symbol: chosen[i].symbol, quantity: qty[i], price: chosen[i].price) : nil
        }
    }
}

/// Posizioni della modalità notte, separate da quelle della giornaliera.
struct NightBook: Codable, Sendable, Equatable {
    /// simbolo → giorno di borsa (New York) dell'acquisto.
    var positions: [String: String] = [:]
    var nights = 0
}

enum NightBookStore {
    private static let base = "quantswarm.night.book"

    static func load(account: String?, defaults: UserDefaults = .standard) -> NightBook {
        guard let data = defaults.data(forKey: key(account)),
              let book = try? JSONDecoder().decode(NightBook.self, from: data) else { return NightBook() }
        return book
    }

    static func save(_ book: NightBook, account: String?, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(book) { defaults.set(data, forKey: key(account)) }
    }

    private static func key(_ account: String?) -> String {
        guard let account, !account.isEmpty else { return base }
        return "\(base).\(account)"
    }
}

/// Quello che la modalità notte chiede al broker.
protocol NightBroker: Sendable {
    func nightClock() async throws -> (isOpen: Bool, nextClose: Date?)
    func account() async throws -> BrokerAccount
    func positions() async throws -> [BrokerPosition]
    func openOrders() async throws -> [BrokerOrder]
    func latestPrice(symbol: String) async throws -> Double
    func closePosition(symbol: String) async throws -> String?
    /// Ordine a mercato in asta: "cls" (chiusura) o "opg" (apertura).
    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> String
    func orderId(byClientOrderId: String) async throws -> String?
}

struct NightCycleInput: Sendable {
    var book: NightBook
    let today: String
    let now: Date
    var capitalCap: Double = .infinity
    /// nil = si può comprare; altrimenti il motivo (le vendite restano sempre permesse).
    var entryBlock: String?
}

struct NightCycleResult: Sendable {
    var book: NightBook
    var aborted = false
    var marketOpen = false
    var equity: Double?
    var sells: [String] = []
    var buys: [NightStrategy.Pick] = []
    var exposure: Double = 0
}

struct NightCycleRunner: Sendable {
    let broker: any NightBroker
    var settleWaitSeconds: Double = 2.0

    func run(_ input: NightCycleInput, emit: @Sendable (DailyCycleEvent) async -> Void) async -> NightCycleResult {
        var result = NightCycleResult(book: input.book)
        var book = input.book
        await emit(.init(stage: .scout, state: .working, detail: "leggo conto, posizioni e orologio di borsa"))
        let clock: (isOpen: Bool, nextClose: Date?)
        var account: BrokerAccount
        var positions: [BrokerPosition]
        var orders: [BrokerOrder]
        do {
            clock = try await broker.nightClock()
            account = try await broker.account()
            positions = try await broker.positions()
            orders = try await broker.openOrders()
        } catch {
            await emit(.init(stage: .scout, state: .failed, detail: "broker non raggiungibile",
                             log: "Notte: broker non raggiungibile (\(error.localizedDescription)); nessun ordine.", agent: .scout))
            result.aborted = true
            return result
        }
        result.marketOpen = clock.isOpen
        result.equity = account.equity
        await emit(.init(stage: .scout, state: .done, detail: "mercato \(clock.isOpen ? "aperto" : "chiuso") · \(book.positions.count) posizioni notte"))

        // Registro: via ciò che non c'è più sul broker (venduto o mai eseguito).
        func heldQty(_ s: String) -> Double { positions.first { $0.symbol.uppercased() == s }?.quantity ?? 0 }
        func pending(_ s: String, side: String) -> Bool {
            orders.contains { $0.symbol.uppercased() == s && $0.side == side }
        }
        for symbol in book.positions.keys.sorted() where heldQty(symbol) <= 0 && !pending(symbol, side: "buy") {
            book.positions[symbol] = nil
        }

        let phase = NightStrategy.phase(now: input.now, isOpen: clock.isOpen, nextClose: clock.nextClose)
        await emit(.init(stage: .analyst, state: .done, detail: "solo regole · 0 crediti"))
        await emit(.init(stage: .brain, state: .skipped, detail: "Kimi non serve di notte · 0 crediti"))
        await emit(.init(stage: .reviewer, state: .skipped, detail: "Kimi non serve di notte · 0 crediti"))

        switch phase {
        case .wait(let why):
            await emit(.init(stage: .strategy, state: .done, detail: why, log: "Notte: \(why).", agent: .scout))
            await emit(.init(stage: .risk, state: .skipped, detail: "nessuna azione ora"))
            await emit(.init(stage: .executor, state: .skipped, detail: "nessuna azione ora"))

        case .sellWindow:
            let toSell = book.positions.keys.sorted().filter { heldQty($0) > 0 && !pending($0, side: "sell") }
            guard !toSell.isEmpty else {
                let text = book.positions.isEmpty ? "nessuna posizione da vendere; si compra in chiusura a mercato aperto"
                    : "vendita all'apertura già in coda"
                await emit(.init(stage: .strategy, state: .done, detail: text, log: "Notte: \(text).", agent: .scout))
                await emit(.init(stage: .risk, state: .skipped, detail: "nessuna azione ora"))
                await emit(.init(stage: .executor, state: .skipped, detail: "nessuna azione ora"))
                break
            }
            await emit(.init(stage: .strategy, state: .done, detail: "vendo all'apertura \(toSell.joined(separator: ", "))"))
            await emit(.init(stage: .risk, state: .done, detail: "vendite: rischio solo in calo"))
            await emit(.init(stage: .executor, state: .working, detail: "metto in coda le vendite all'apertura"))
            for symbol in toSell {
                let qty = Int(heldQty(symbol).rounded(.down))
                guard qty > 0 else { continue }
                let id = "qsn-s-\(symbol)-\(input.today)-\(Int(input.now.timeIntervalSince1970 / 3600))"
                if await submit(symbol: symbol, qty: qty, side: "sell", tif: "opg", id: id, emit: emit) {
                    result.sells.append(symbol)
                }
            }
            await emit(.init(stage: .executor, state: .done, detail: "vendite all'apertura in coda: \(result.sells.joined(separator: ", "))",
                             log: result.sells.isEmpty ? nil : "ORDINI NOTTE: vendita all'apertura (OPG) di \(result.sells.joined(separator: ", ")).",
                             agent: .risk,
                             notify: result.sells.isEmpty ? nil : ("VENDITA ALL'APERTURA", result.sells.joined(separator: ", "))))

        case .buyWindow:
            // Posizioni rimaste dalla notte prima (app non aperta la mattina):
            // si chiudono ora a mercato, così il bot resta solo "di notte".
            let leftovers = book.positions.keys.sorted().filter { heldQty($0) > 0 && book.positions[$0]! < input.today }
            for symbol in leftovers where !pending(symbol, side: "sell") {
                do {
                    _ = try await broker.closePosition(symbol: symbol)
                    book.positions[symbol] = nil
                    result.sells.append(symbol)
                    await emit(.init(log: "\(symbol): non venduta all'apertura (app non aperta la mattina); chiusa ora a mercato.", agent: .risk))
                } catch {
                    await emit(.init(log: "\(symbol): chiusura non riuscita (\(error.localizedDescription)).", agent: .risk))
                }
            }
            if !leftovers.isEmpty {
                try? await Task.sleep(nanoseconds: UInt64(settleWaitSeconds * 1_000_000_000))
                if let a = try? await broker.account() { account = a }
                if let p = try? await broker.positions() { positions = p }
                if let o = try? await broker.openOrders() { orders = o }
            }
            let already = book.positions.keys.filter { book.positions[$0] == input.today }
            if !already.isEmpty {
                let text = "acquisti in chiusura di oggi già in coda: \(already.sorted().joined(separator: ", "))"
                await emit(.init(stage: .strategy, state: .done, detail: text, log: "Notte: \(text).", agent: .scout))
                await emit(.init(stage: .risk, state: .skipped, detail: "nessuna azione ora"))
                await emit(.init(stage: .executor, state: .skipped, detail: "nessuna azione ora"))
                break
            }
            if let block = input.entryBlock {
                await emit(.init(stage: .strategy, state: .blocked, detail: block, log: "Notte: acquisti fermi — \(block).", agent: .risk))
                await emit(.init(stage: .risk, state: .skipped, detail: block))
                await emit(.init(stage: .executor, state: .skipped, detail: block))
                break
            }
            let botAccount = RiskRules.capped(
                RiskRules.Account(equity: account.equity, cash: account.cash, buyingPower: account.buyingPower),
                capital: input.capitalCap, exposure: 0
            )
            let budget = max(min(botAccount.equity, botAccount.cash, botAccount.buyingPower), 0) * (1 - NightStrategy.cashBuffer)
            var prices: [String: Double] = [:]
            for symbol in NightStrategy.universe {
                if let p = try? await broker.latestPrice(symbol: symbol), p > 0 { prices[symbol] = p }
            }
            let picks = NightStrategy.allocate(budget: budget, prices: prices)
            guard !picks.isEmpty else {
                let text = "capitale insufficiente per 1 azione (budget \(fmt(budget)) USD)"
                await emit(.init(stage: .strategy, state: .blocked, detail: text, log: "Notte: \(text).", agent: .risk))
                await emit(.init(stage: .risk, state: .skipped, detail: text))
                await emit(.init(stage: .executor, state: .skipped, detail: text))
                break
            }
            let plan = picks.map { "\($0.symbol) \($0.quantity)" }.joined(separator: " · ")
            await emit(.init(stage: .strategy, state: .done, detail: "compro in chiusura: \(plan)"))
            await emit(.init(stage: .risk, state: .done, detail: "budget \(fmt(budget)) USD a peso uguale, azioni intere"))
            await emit(.init(stage: .executor, state: .working, detail: "metto in coda gli acquisti in chiusura"))
            for pick in picks {
                let id = "qsn-b-\(pick.symbol)-\(input.today)"
                if await submit(symbol: pick.symbol, qty: pick.quantity, side: "buy", tif: "cls", id: id, emit: emit) {
                    book.positions[pick.symbol] = input.today
                    result.buys.append(pick)
                }
            }
            if !result.buys.isEmpty { book.nights += 1 }
            let text = result.buys.map { "\($0.symbol) \($0.quantity) az." }.joined(separator: ", ")
            await emit(.init(stage: .executor, state: result.buys.isEmpty ? .failed : .done,
                             detail: result.buys.isEmpty ? "nessun acquisto accettato" : "in coda per la chiusura: \(text)",
                             log: result.buys.isEmpty ? nil : "ORDINI NOTTE: acquisto in chiusura (MOC) di \(text); si vende all'apertura di domani.",
                             agent: .risk,
                             notify: result.buys.isEmpty ? nil : ("ACQUISTO IN CHIUSURA", text)))
        }
        result.exposure = book.positions.keys.reduce(0.0) { sum, s in
            sum + (positions.first { $0.symbol.uppercased() == s }.map { $0.quantity * ($0.averageEntryPrice ?? 0) } ?? 0)
        }
        result.book = book
        return result
    }

    /// Invio con recupero: se la rete cade, si cerca l'ordine per id prima di
    /// rinviarlo. Mai due ordini uguali.
    private func submit(symbol: String, qty: Int, side: String, tif: String, id: String,
                        emit: @Sendable (DailyCycleEvent) async -> Void) async -> Bool {
        if let found = try? await broker.orderId(byClientOrderId: id), found != nil { return true }
        do {
            _ = try await broker.submitAuction(symbol: symbol, quantity: qty, side: side, timeInForce: tif, clientOrderId: id)
            return true
        } catch {
            if let found = try? await broker.orderId(byClientOrderId: id), found != nil { return true }
            await emit(.init(log: "\(symbol): ordine \(tif.uppercased()) rifiutato (\(error.localizedDescription)).", agent: .risk))
            return false
        }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
