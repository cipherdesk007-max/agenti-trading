import Foundation

/// Modalità GIORNALIERA: Trend + Pullback sul paniere di ETF.
///
/// Validata dal backtest 2006–oggi (tools/backtest_daily.py): è l'unica
/// strategia che batte ingressi casuali con le stesse uscite (Sharpe 0,61
/// con stop 2,5 ATR contro 0,20–0,48 del caso), stabile in 2006–2015 e
/// 2016–oggi. Regole tutte in codice, nessuna stima del modello:
/// - INGRESSO: ultima chiusura giornaliera > SMA200 (trend) e RSI(2) < 10 (pullback)
/// - STOP sul broker (GTC, resta attivo ad app chiusa): ingresso − 2,5 × ATR14
/// - USCITA: chiusura > SMA5, oppure 10 giorni di borsa dall'ingresso
/// Kimi sceglie fra i candidati (Brain) e il Reviewer li contesta; i livelli
/// e la quantità restano del codice.
enum DailyStrategy {
    static let basket = ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV",
                         "XLY", "XLP", "XLI", "XLU", "XLB", "GLD", "TLT"]
    static let stopATR = 2.5
    /// Take-profit sul broker (bracket GTC): nel backtest con le regole
    /// dell'app non cambia rendimento né drawdown, ma fa uscire la posizione
    /// anche ad app chiusa.
    static let takeProfitATR = 2.0
    static let maxHoldingDays = 10
    static let rsiEntryThreshold = 10.0
    /// Barre giornaliere minime: SMA200 + margine per RSI/ATR.
    static let minimumBars = 205

    struct Snapshot: Sendable, Equatable {
        let close: Double
        let sma200: Double
        let sma5: Double
        let rsi2: Double
        let atr14: Double
    }

    struct Candidate: Sendable, Equatable {
        let symbol: String
        let snapshot: Snapshot
        /// Ultime 20 chiusure, per il contesto del Brain.
        var recentCloses: [Double] = []
        /// Stop teorico sulla chiusura (quello reale si ricalcola sul prezzo d'ingresso).
        var stopDistance: Double { DailyStrategy.stopATR * snapshot.atr14 }
    }

    enum ExitReason: String, Sendable, Equatable {
        case aboveSMA5 = "chiusura sopra la SMA5"
        case timeLimit = "10 giorni di borsa raggiunti"
    }

    static func snapshot(of bars: [Candle]) -> Snapshot? {
        guard bars.count >= minimumBars else { return nil }
        let closes = bars.map(\.close)
        guard let close = closes.last,
              let sma200 = Indicators.sma(closes, period: 200),
              let sma5 = Indicators.sma(closes, period: 5),
              let rsi2 = Indicators.rsi(closes, period: 2),
              let atr = Indicators.atr(bars, period: 14),
              [close, sma200, sma5, rsi2, atr].allSatisfy({ $0.isFinite }), atr > 0 else {
            return nil
        }
        return Snapshot(close: close, sma200: sma200, sma5: sma5, rsi2: rsi2, atr14: atr)
    }

    /// Candidato all'ingresso se trend rialzista e pullback profondo.
    static func entryCandidate(symbol: String, bars: [Candle]) -> Candidate? {
        guard let s = snapshot(of: bars), s.close > s.sma200, s.rsi2 < rsiEntryThreshold else {
            return nil
        }
        return Candidate(symbol: symbol, snapshot: s, recentCloses: bars.suffix(20).map(\.close))
    }

    /// Motivo di uscita per una posizione aperta il giorno `entryDay`
    /// (stringa yyyy-MM-dd, giorno di borsa New York). nil = resta dentro.
    static func exitReason(bars: [Candle], entryDay: String) -> ExitReason? {
        guard let s = snapshot(of: bars) else { return nil }
        if s.close > s.sma5 { return .aboveSMA5 }
        let held = bars.filter { tradingDay($0.timestamp) >= entryDay }.count
        if held >= maxHoldingDays { return .timeLimit }
        return nil
    }

    /// Solo barre giornaliere CHIUSE: durante la seduta Alpaca restituisce
    /// anche la barra di oggi in formazione, che va scartata.
    static func closedBars(_ bars: [Candle], now: Date = Date(), marketOpen: Bool) -> [Candle] {
        guard marketOpen, let last = bars.last, tradingDay(last.timestamp) == tradingDay(now) else {
            return bars
        }
        return Array(bars.dropLast())
    }

    static func tradingDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Registro persistente delle posizioni aperte dalla modalità giornaliera:
/// simbolo → giorno di borsa d'ingresso. Serve per l'uscita a tempo e per non
/// toccare posizioni aperte a mano o da altre modalità.
struct DailyBook: Codable, Sendable, Equatable {
    var entries: [String: String] = [:]
    /// Stop d'ingresso per simbolo: serve a ripristinare la protezione se lo
    /// stop sul broker sparisce (uscita fallita, ordine eseguito in parte).
    var stops: [String: Double] = [:]
    /// Simboli già sottoposti a Kimi oggi (giorno di borsa → simboli): evita di
    /// ripagare la stessa decisione a ogni ciclo.
    var decidedDay: String = ""
    var decidedSymbols: [String] = []
    /// Registro ombra: ogni candidato valutato da Kimi con l'esito ipotetico
    /// secondo le stesse regole, per misurare se Kimi aggiunge valore.
    var shadow: [ShadowEntry] = []
    /// Ordini d'ingresso inviati / mai eseguiti / eseguiti in parte.
    var placedEntries = 0
    var unfilledEntries = 0
    var partialEntries = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: String].self, forKey: .entries) ?? [:]
        stops = try c.decodeIfPresent([String: Double].self, forKey: .stops) ?? [:]
        decidedDay = try c.decodeIfPresent(String.self, forKey: .decidedDay) ?? ""
        decidedSymbols = try c.decodeIfPresent([String].self, forKey: .decidedSymbols) ?? []
        shadow = try c.decodeIfPresent([ShadowEntry].self, forKey: .shadow) ?? []
        placedEntries = try c.decodeIfPresent(Int.self, forKey: .placedEntries) ?? 0
        unfilledEntries = try c.decodeIfPresent(Int.self, forKey: .unfilledEntries) ?? 0
        partialEntries = try c.decodeIfPresent(Int.self, forKey: .partialEntries) ?? 0
    }

    mutating func addShadow(_ entry: ShadowEntry) {
        shadow.append(entry)
        if shadow.count > 300 { shadow.removeFirst(shadow.count - 300) }
    }

    mutating func remove(_ symbol: String) {
        entries.removeValue(forKey: symbol)
        stops.removeValue(forKey: symbol)
    }

    mutating func markDecided(_ symbol: String, day: String) {
        if decidedDay != day {
            decidedDay = day
            decidedSymbols = []
        }
        if !decidedSymbols.contains(symbol) { decidedSymbols.append(symbol) }
    }

    func alreadyDecided(_ symbol: String, day: String) -> Bool {
        decidedDay == day && decidedSymbols.contains(symbol)
    }
}

enum DailyBookStore {
    private static let key = "com.quantswarm.alphazero.dailyBook"

    static func load() -> DailyBook {
        guard let data = UserDefaults.standard.data(forKey: key),
              let book = try? JSONDecoder().decode(DailyBook.self, from: data) else { return DailyBook() }
        return book
    }

    static func save(_ book: DailyBook) {
        guard let data = try? JSONEncoder().encode(book) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Registro ombra (valore di Kimi)

struct ShadowEntry: Codable, Sendable, Equatable {
    static let bought = "comprato"
    static let brainSkip = "scartato dal Brain"
    static let reviewerReject = "bocciato dal Reviewer"
    static let noSlot = "senza posti liberi"
    static let blocked = "bloccato dal rischio"

    let symbol: String
    /// Giorno di borsa del segnale.
    let day: String
    /// Chiusura del giorno del segnale (prezzo d'ingresso ipotetico).
    let entry: Double
    let stop: Double
    let outcome: String
    var exitPrice: Double?
    var exitDay: String?

    var resolved: Bool { exitPrice != nil }
    var ret: Double? { exitPrice.map { $0 / entry - 1 } }
    var chosen: Bool { outcome == Self.bought }
}

enum ShadowEvaluator {
    /// Esito ipotetico con le regole dell'app: stop toccato (al prezzo di stop
    /// o all'apertura se c'è gap), oppure chiusura > SMA5 o 10 giorni.
    static func resolve(_ entry: ShadowEntry, bars: [Candle]) -> (price: Double, day: String)? {
        let closes = bars.map(\.close)
        var held = 0
        for (index, bar) in bars.enumerated() {
            let day = DailyStrategy.tradingDay(bar.timestamp)
            guard day > entry.day else { continue }
            held += 1
            if bar.low <= entry.stop { return (min(entry.stop, bar.open), day) }
            if index >= 4 {
                let sma5 = closes[(index - 4)...index].reduce(0, +) / 5
                if bar.close > sma5 { return (bar.close, day) }
            }
            if held >= DailyStrategy.maxHoldingDays { return (bar.close, day) }
        }
        return nil
    }
}

struct ShadowSummary: Sendable, Equatable {
    var chosenCount = 0
    var chosenAverage: Double?
    var skippedCount = 0
    var skippedAverage: Double?
    var pending = 0

    static func from(_ entries: [ShadowEntry]) -> ShadowSummary {
        var summary = ShadowSummary()
        let resolved = entries.filter(\.resolved)
        summary.pending = entries.count - resolved.count
        let chosen = resolved.filter(\.chosen).compactMap(\.ret)
        let skipped = resolved.filter { $0.outcome == ShadowEntry.brainSkip || $0.outcome == ShadowEntry.reviewerReject }
            .compactMap(\.ret)
        summary.chosenCount = chosen.count
        summary.skippedCount = skipped.count
        summary.chosenAverage = chosen.isEmpty ? nil : chosen.reduce(0, +) / Double(chosen.count)
        summary.skippedAverage = skipped.isEmpty ? nil : skipped.reduce(0, +) / Double(skipped.count)
        return summary
    }

    /// Testo per il Brain: com'è andata finora (solo se ci sono dati).
    var feedbackText: String? {
        guard chosenCount + skippedCount >= 3 else { return nil }
        func pct(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0 * 100) } ?? "n/d" }
        return "Esiti misurati finora: scelti da te \(chosenCount) (medio \(pct(chosenAverage))), "
            + "scartati \(skippedCount) (medio \(pct(skippedAverage)))."
    }
}
