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

    /// Minuti dalla mezzanotte di New York del giorno di borsa (yyyy-MM-dd, fuso ET).
    static func dayStampET(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

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

    /// Giorno della settimana in ora di New York (1 = domenica, 7 = sabato).
    static func weekdayET(_ date: Date) -> Int {
        Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "America/New_York")!, from: date).weekday ?? 0
    }

    /// Regole di Alpaca: le OPG si accettano FUORI da 9:28–19:00 ET (anche il
    /// sabato e la domenica, per l'apertura di lunedì), le MOC fino alle 15:50
    /// (qui con 10 minuti di margine sulla chiusura).
    /// `calendar` (GET /v2/calendar) dà la chiusura esatta del giorno — anche
    /// nelle mezze giornate — e i festivi infrasettimanali: niente ordini d'asta
    /// in un giorno di festa. Nel FINE SETTIMANA invece la vendita OPG va messa in
    /// coda fuori da 9:28–19:00 ET, perché lunedì si apre. Se il calendario non
    /// risponde (nil) ci si comporta come prima (solo clock e regole orarie).
    static func phase(now: Date, isOpen: Bool, nextClose: Date?, calendar: [TradingDay]?, today: String) -> Phase {
        let m = minutesET(now)
        let weekday = weekdayET(now)
        let isWeekend = weekday == 1 || weekday == 7
        let todayDay = calendar?.first { $0.date == today }
        if let calendar, !isWeekend, todayDay == nil, !isOpen {
            return .wait("oggi la borsa USA è chiusa (festivo): nessuna asta")
        }
        if isOpen {
            let close = todayDay?.close ?? nextClose
            if let close, close.timeIntervalSince(now) > closeCutoffMinutes * 60 {
                return .buyWindow
            }
            return .wait("troppo vicino alla chiusura per l'asta: si compra domani")
        }
        // Mercato chiuso: l'OPG va in coda solo FUORI da 9:28–19:00 ET. Dentro
        // questa finestra (mattina, o pomeriggio dopo una chiusura anticipata come
        // le 13:00 ET delle mezze giornate) Alpaca rifiuterebbe l'ordine: si aspetta.
        if m >= 9 * 60 + 28 && m < 19 * 60 {
            return .wait("le vendite all'apertura si accettano solo fuori da 9:28–19:00 di New York (ora ET)")
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

/// Giorno di borsa dal calendario Alpaca (GET /v2/calendar): `close` è la
/// chiusura esatta del giorno (fuso New York), incluse le mezze giornate.
struct TradingDay: Sendable, Equatable {
    /// yyyy-MM-dd del giorno di borsa, fuso America/New_York.
    let date: String
    let close: Date
}

/// Quale asta misura il prezzo reale.
enum AuctionKind: String, Sendable {
    case open = "open"    // asta di apertura (OPG)
    case close = "close"  // asta di chiusura (MOC)
}

/// Confronto eseguito-vs-asta registrato nel report dopo un ordine d'asta della notte.
struct AuctionDiff: Sendable, Equatable {
    let symbol: String
    let side: String
    let executed: Double
    let auction: Double
    let diff: Double
    let diffPct: Double
}

/// Ordine d'asta della notte in attesa di misura: al ciclo dopo si confronta il
/// prezzo eseguito (filled_avg_price) con il prezzo reale dell'asta
/// (GET /v2/stocks/{symbol}/auctions). Solo report: mai un ordine cambia.
struct NightFillCheck: Codable, Sendable, Equatable {
    var symbol: String
    var side: String      // "buy" (MOC) o "sell" (OPG)
    var orderId: String
    var queueDay: String  // giorno in cui l'ordine è stato messo in coda
    var refPrice: Double  // ultimo prezzo noto al momento dell'invio
}

/// Posizione della modalità notte nel registro locale.
/// quantity nil = registro scritto da una versione precedente del bug B1:
/// quantità ignota, si vende tutto il detenuto del simbolo (vedi
/// nightQuantity). I nuovi acquisti registrano sempre la quantità esatta.
struct NightPosition: Codable, Sendable, Equatable {
    var day: String
    var quantity: Double?
    /// Giorno in cui la vendita all'apertura (OPG) è stata messa in coda. La
    /// posizione resta nel registro finché il detenuto non scende di almeno
    /// `quantity`: se l'asta annulla l'ordine, le azioni restano sul conto e
    /// il ciclo le chiude come residuo invece di perderle di vista.
    var sellQueuedDay: String? = nil
    /// Detenuto del simbolo quando la vendita è stata messa in coda: con la
    /// giornaliera sullo stesso simbolo il totale non torna a zero, questa è
    /// la base per capire quanto è sceso.
    var sellQueuedHeld: Double? = nil
    /// client_order_id dell'OPG in coda: la conferma dell'esecuzione arriva dallo
    /// STATO dell'ordine sul broker (filled = venduto, canceled/rejected/expired =
    /// residuo), non dal calo del detenuto, che con la giornaliera sullo stesso
    /// simbolo non è affidabile.
    var sellQueuedOrderId: String? = nil
}

/// Posizioni della modalità notte, separate da quelle della giornaliera.
/// La quantità è FONDAMENTALE: sul conto può esserci lo stesso simbolo
/// comprato anche dalla modalità giornaliera (SPY/QQQ/IWM/GLD sono in
/// entrambi i panieri), quindi la notte deve vendere solo le SU azioni.
struct NightBook: Codable, Sendable, Equatable {
    /// simbolo → giorno di borsa (New York) dell'acquisto e azioni comprate.
    var positions: [String: NightPosition] = [:]
    var nights = 0
    /// Ordini d'asta in attesa di misura executed-vs-asta (solo report).
    var fillChecks: [NightFillCheck] = []

    init() {}

    /// Retrocompatibilità: il formato vecchio era simbolo → giorno (stringa).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nights = try container.decodeIfPresent(Int.self, forKey: .nights) ?? 0
        fillChecks = try container.decodeIfPresent([NightFillCheck].self, forKey: .fillChecks) ?? []
        if let modern = try? container.decode([String: NightPosition].self, forKey: .positions) {
            positions = modern
        } else if let legacy = try? container.decode([String: String].self, forKey: .positions) {
            positions = legacy.mapValues { NightPosition(day: $0, quantity: nil) }
        }
    }

    /// Azioni della notte per un simbolo; nil = quantità ignota (registro vecchio).
    func nightQuantity(_ symbol: String) -> Double? {
        positions[symbol]?.quantity
    }
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
    /// Chiude a mercato TUTTA la posizione del simbolo: usare solo quando la
    /// notte possiede tutto il detenuto del simbolo.
    func closePosition(symbol: String) async throws -> String?
    /// Vendita a mercato di una quantità precisa (per chiudere solo le azioni
    /// della notte quando la giornaliera ha lo stesso simbolo).
    func submitMarket(symbol: String, quantity: Int, side: String,
                      clientOrderId: String) async throws -> String
    /// Ordine a mercato in asta: "cls" (chiusura) o "opg" (apertura).
    func submitAuction(symbol: String, quantity: Int, side: String, timeInForce: String,
                       clientOrderId: String) async throws -> String
    /// Calendario di borsa (GET /v2/calendar) per la finestra: chiusura esatta
    /// del giorno e festivi. L'errore = calendario non disponibile: il ciclo
    /// si comporta come prima, solo con l'orologio del broker.
    func tradingDays(from: Date, to: Date) async throws -> [TradingDay]
    /// Recupero per client_order_id: conta solo se l'ordine è vivo (non
    /// rifiutato/annullato/scaduto).
    func orderRef(byClientOrderId: String) async throws -> BrokerOrderRef?
    /// Prezzo medio di esecuzione di un ordine (filled_avg_price): solo misura.
    func orderFillPrice(orderId: String) async throws -> Double?
    /// Prezzo reale dell'asta di un giorno (GET /v2/stocks/{symbol}/auctions):
    /// solo misura. Errore = dato non disponibile, l'app va avanti come prima.
    func auctionPrice(symbol: String, day: String, kind: AuctionKind) async throws -> Double?
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
    /// Misure executed-vs-asta degli ordini della notte (solo report).
    var auctionDiffs: [AuctionDiff] = []
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

        // Misura aste (SOLO report): per ogni ordine d'asta della notte già chiuso,
        // confronta il prezzo eseguito con il prezzo reale dell'asta
        // (GET /v2/stocks/{symbol}/auctions). Mai obbligatoria: se l'API non
        // risponde non si registra nulla e nessun ordine cambia.
        for check in book.fillChecks {
            let stillOpen = orders.contains { $0.id == check.orderId }
            let fill = try? await broker.orderFillPrice(orderId: check.orderId)
            let kind: AuctionKind = check.side == "buy" ? .close : .open
            let auctionDay = check.side == "buy" ? check.queueDay : input.today
            let auction = try? await broker.auctionPrice(symbol: check.symbol, day: auctionDay, kind: kind)
            if let fill, let auction, fill > 0, auction > 0 {
                let diff = fill - auction
                let pct = diff / auction * 100
                result.auctionDiffs.append(AuctionDiff(symbol: check.symbol, side: check.side,
                                                      executed: fill, auction: auction, diff: diff, diffPct: pct))
                let asta = check.side == "buy" ? "chiusura" : "apertura"
                await emit(.init(log: "\(check.symbol): asta di \(asta) — eseguito \(fmt(fill)) vs asta reale \(fmt(auction)): diff \(fmt(diff)) USD (\(String(format: "%+.3f", pct))%).", agent: .risk))
            }
            if !stillOpen { book.fillChecks.removeAll { $0.orderId == check.orderId } }
        }

        // Registro: via ciò che non c'è più sul broker (venduto o mai eseguito).
        func heldQty(_ s: String) -> Double { positions.first { $0.symbol.uppercased() == s }?.quantity ?? 0 }
        func pending(_ s: String, side: String) -> Bool {
            orders.contains { $0.symbol.uppercased() == s && $0.side == side }
        }
        /// Azioni della notte da vendere per un simbolo: quelle del registro
        /// (mai oltre il detenuto), meno quelle già vendute dalla coda in asta
        /// (calo del detenuto rispetto a quando la vendita è stata messa in
        /// coda). Registro vecchio senza quantità (nil): si vende tutto il
        /// detenuto del simbolo, come prima del fix B1.
        func ownedQty(_ s: String, held: Int, book: NightBook) -> Int {
            guard held > 0, let p = book.positions[s] else { return 0 }
            guard let recorded = p.quantity else { return held }
            var remaining = recorded
            if p.sellQueuedDay != nil, let baseline = p.sellQueuedHeld {
                remaining -= max(0, baseline - heldQty(s))
            }
            return min(Int(max(remaining, 0).rounded(.down)), held)
        }
        // Registro: via ciò che non c'è più sul broker (venduto o mai eseguito) e
        // le vendite in coda andate in porto (detenuto sceso di almeno la quantità
        // della notte). Gli acquisti di oggi a mercato aperto restano: si eseguono
        // in chiusura.
        for symbol in book.positions.keys.sorted() {
            let held = heldQty(symbol)
            if held <= 0 && !pending(symbol, side: "buy") {
                if clock.isOpen, book.positions[symbol]?.day == input.today { continue }
                book.positions[symbol] = nil
                continue
            }
            if let p = book.positions[symbol], p.sellQueuedDay != nil {
                // La vendita in coda si conferma dallo STATO dell'ordine OPG sul
                // broker (client_order_id salvato nel registro): filled = tolta,
                // canceled/rejected/expired = residuo (resta e verrà chiusa come
                // leftover). Il calo del detenuto non basta: con la giornaliera
                // sullo stesso simbolo il totale può risalire.
                if let orderId = p.sellQueuedOrderId, let ref = try? await broker.orderRef(byClientOrderId: orderId) {
                    if ref.status == "filled" {
                        book.positions[symbol] = nil
                        continue
                    }
                    if ["canceled", "rejected", "expired"].contains(ref.status) {
                        // Residuo: resta nel registro, marcata in coda.
                    } else {
                        continue // ordine ancora vivo in coda d'asta
                    }
                } else if let q = p.quantity {
                    // Fallback per registro senza orderId: calo del detenuto.
                    let baseline = p.sellQueuedHeld ?? held
                    if baseline - held >= q - 1e-6 { book.positions[symbol] = nil; continue }
                }
            }
        }

        // Calendario di borsa (mai obbligatorio: se non risponde, nil e si usa solo clock).
        let calendar: [TradingDay]? = try? await broker.tradingDays(
            from: input.now.addingTimeInterval(-3 * 86_400),
            to: input.now.addingTimeInterval(3 * 86_400))
        let phase = NightStrategy.phase(now: input.now, isOpen: clock.isOpen, nextClose: clock.nextClose,
                                        calendar: calendar, today: input.today)
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
                let held = Int(heldQty(symbol).rounded(.down))
                let own = ownedQty(symbol, held: held, book: book)
                guard own > 0 else { continue }
                let id = "qsn-s-\(symbol)-\(input.today)-\(Int(input.now.timeIntervalSince1970 / 3600))"
                if let orderId = await submit(symbol: symbol, qty: own, side: "sell", tif: "opg", id: id, emit: emit) {
                    result.sells.append(symbol)
                    book.fillChecks.append(NightFillCheck(symbol: symbol, side: "sell", orderId: orderId,
                                                          queueDay: input.today,
                                                          refPrice: positions.first { $0.symbol.uppercased() == symbol }?.averageEntryPrice ?? 0))
                    if var p = book.positions[symbol], let q = p.quantity, q > 0 {
                        // La posizione RESTA nel registro, marcata "in coda": se l'OPG
                        // non si esegue (rifiutata dopo l'accettazione o annullata
                        // all'asta) le azioni restano sul conto e il ciclo le chiude
                        // come residuo; viene tolta solo quando il detenuto scende di
                        // almeno la quantità (controllo all'inizio del ciclo). La
                        // quantità limita sempre la vendita alle sole azioni della
                        // notte (fix B1).
                        p.sellQueuedDay = input.today
                        p.sellQueuedHeld = heldQty(symbol)
                        p.sellQueuedOrderId = orderId
                        book.positions[symbol] = p
                    } else {
                        // Registro vecchio senza quantità: la vendita copre tutto il
                        // detenuto e va fatta UNA sola volta. La voce esce subito:
                        // se la giornaliera ha lo stesso simbolo il detenuto non
                        // torna mai a zero e la voce resterebbe viva per sempre,
                        // ri-mettendo in coda ogni sera la vendita di TUTTO il
                        // detenuto (anche le azioni della giornaliera).
                        book.positions[symbol] = nil
                    }
                }
            }
            await emit(.init(stage: .executor, state: .done, detail: "vendite all'apertura in coda: \(result.sells.joined(separator: ", "))",
                             log: result.sells.isEmpty ? nil : "ORDINI NOTTE: vendita all'apertura (OPG) di \(result.sells.joined(separator: ", ")).",
                             agent: .risk,
                             notify: result.sells.isEmpty ? nil : ("VENDITA ALL'APERTURA", result.sells.joined(separator: ", "))))

        case .buyWindow:
            // Posizioni rimaste dalla notte prima (app non aperta la mattina, o
            // OPG annullata all'asta e non eseguita): si chiudono ora a mercato,
            // così il bot resta solo "di notte" e non compra due volte sopra.
            let leftovers = book.positions
                .filter { $0.value.day < input.today && heldQty($0.key) > 0 }
                .map(\.key)
                .sorted()
            for symbol in leftovers where !pending(symbol, side: "sell") {
                let held = Int(heldQty(symbol).rounded(.down))
                let own = ownedQty(symbol, held: held, book: book)
                guard own > 0 else { continue }
                do {
                    if own >= held {
                        // La notte possiede tutto il detenuto: chiusura intera.
                        _ = try await broker.closePosition(symbol: symbol)
                    } else {
                        // Sul conto c'è anche la giornaliera con lo stesso
                        // simbolo: chiudo SOLO le azioni della notte.
                        let id = "qsn-l-\(symbol)-\(input.today)-\(Int(input.now.timeIntervalSince1970 / 3600))"
                        _ = try await broker.submitMarket(symbol: symbol, quantity: own, side: "sell", clientOrderId: id)
                    }
                    book.positions[symbol] = nil
                    result.sells.append(symbol)
                    await emit(.init(log: "\(symbol): non venduta all'apertura (app non aperta la mattina); chiuse ora a mercato \(own) az. della notte.", agent: .risk))
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
            let already = book.positions.keys.filter { book.positions[$0]?.day == input.today }
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
            // Niente acquisti sopra un residuo non chiuso: i simboli ancora in
            // registro (giorno precedente) restano fuori dal paniere di stasera.
            // A livello di FAMIGLIA: con un residuo su SPYM non si compra SPY
            // (stesso indice S&P 500, stesso rischio raddoppiato).
            let blocked = Set(book.positions.keys.map { $0.uppercased() })
            let picks = NightStrategy.allocate(budget: budget, prices: prices)
                .filter { pick in
                    guard book.positions[pick.symbol] == nil else { return false }
                    let family = NightStrategy.families.first(where: { $0.symbols.contains(pick.symbol) })
                    else { return true }
                    return family.symbols.allSatisfy { !blocked.contains($0.uppercased()) }
                }
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
            var failedPicks: [NightStrategy.Pick] = []
            var spent = 0.0
            for pick in picks {
                let id = "qsn-b-\(pick.symbol)-\(input.today)"
                if let orderId = await submit(symbol: pick.symbol, qty: pick.quantity, side: "buy", tif: "cls", id: id, emit: emit) {
                    book.positions[pick.symbol] = NightPosition(day: input.today, quantity: Double(pick.quantity))
                    book.fillChecks.append(NightFillCheck(symbol: pick.symbol, side: "buy", orderId: orderId,
                                                          queueDay: input.today, refPrice: pick.price))
                    result.buys.append(pick)
                    spent += Double(pick.quantity) * pick.price
                } else {
                    failedPicks.append(pick)
                }
            }
            // MOC parziali: se alcune sono rifiutate si ritenta SOLO le famiglie
            // mancanti, col gemello economico se l'originale non basta più.
            for pick in failedPicks {
                guard let family = NightStrategy.families.first(where: { $0.symbols.contains(pick.symbol) }) else { continue }
                let alt = family.symbols.first { s in
                    s != pick.symbol
                        && book.positions[s] == nil
                        && !result.buys.contains { $0.symbol == s }
                        && (prices[s] ?? 0) > 0
                }
                guard let alt, let price = prices[alt], price > 0 else { continue }
                let qty = Int(min(Double(pick.quantity), max(budget - spent, 0) / price))
                guard qty > 0 else { continue }
                let id = "qsn-b-\(alt)-\(input.today)"
                if let orderId = await submit(symbol: alt, qty: qty, side: "buy", tif: "cls", id: id, emit: emit) {
                    book.positions[alt] = NightPosition(day: input.today, quantity: Double(qty))
                    book.fillChecks.append(NightFillCheck(symbol: alt, side: "buy", orderId: orderId,
                                                          queueDay: input.today, refPrice: price))
                    result.buys.append(NightStrategy.Pick(symbol: alt, quantity: qty, price: price))
                    spent += Double(qty) * price
                    await emit(.init(log: "\(pick.symbol): MOC rifiutata, riprovato con \(alt) x\(qty) (stessa famiglia).", agent: .risk))
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
    /// rinviarlo. Mai due ordini uguali. Ma l'ordine ritrovato conta solo se è
    /// VIVO: uno stato rejected/canceled/expired non è un invio riuscito, e
    /// NON va bloccato il retry (è il bug B4: la vendita OPG rifiutata dal
    /// broker veniva dichiarata riuscita e la posizione restava in conto).
    private func submit(symbol: String, qty: Int, side: String, tif: String, id: String,
                        emit: @Sendable (DailyCycleEvent) async -> Void) async -> String? {
        if let ref = try? await broker.orderRef(byClientOrderId: id), ref.countsAsPlaced { return ref.id }
        do {
            return try await broker.submitAuction(symbol: symbol, quantity: qty, side: side, timeInForce: tif, clientOrderId: id)
        } catch {
            if let ref = try? await broker.orderRef(byClientOrderId: id), ref.countsAsPlaced { return ref.id }
            await emit(.init(log: "\(symbol): ordine \(tif.uppercased()) rifiutato (\(error.localizedDescription)).", agent: .risk))
            return nil
        }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
