import Foundation

/// CRYPTO · 24/7 — regole V4 dello studio `tools/backtest_trend_crypto.py`
/// (proposta 20, docs/PROPOSTE.md). Trend-following a regime, long-only,
/// paniere equal-weight: NON è la mean-reversion della proposta 18 (bocciata).
///
/// Griglia pre-registrata e criteri (stampati dallo studio, decisi PRIMA di
/// vedere i numeri): A CAGR ≥ +3% | B maxDD ≤ −20%... solo V3 e V4 passano
/// tutto; V4 (Donchian20 + chandelier) è scelta perché la sua perdita max
/// (−9%) è compatibile col blocco drawdown al 10% dell'app.
///
/// CORREZIONE 14/11/2026: quei numeri valgono per ingressi da 1/36 del
/// capitale (lo studio divideva due volte per il numero di monete). Con la
/// dimensione usata QUI (1/5 del conto per coppia) lo studio rifatto
/// (tools/studio_universo.py, run 43572591958) dà perdita massima −41%: il
/// criterio B non è rispettato e il blocco al 10% scatterebbe spesso. Le
/// regole non sono state cambiate: la decisione è del proprietario.
///
/// Regole V4 per ogni coppia (barre 1D CHIUSE di Alpaca crypto):
/// - regime: chiusura > SMA200;
/// - ingresso: chiusura sopra il massimo degli HIGH delle 20 barre PRECEDENTI;
/// - uscita: chiusura < chandelier (massimo delle chiusure da ingresso − 3×ATR22)
///   oppure chiusura < SMA200;
/// - sizing: ogni coppia 1/5 del budget crypto (equal-weight), ordine `simple`
///   frazionato (qty decimale): sulle crypto Alpaca NON esistono bracket/oto
///   (422) e lo stop protettivo è un ordine `stop_limit` GTC separato,
///   aggiornato a ogni chiusura di barra (chandelier mobile).
enum CryptoStrategy {
    /// Coppie Alpaca del paniere richiesto dal proprietario. Lo studio ha
    /// validato l'equal-weight su 6 monete (incl. DOGE); il paniere in-app è
    /// quello richiesto: la differenza è dichiarata in docs/STATO.md.
    static let pairs = ["BTC/USD", "ETH/USD", "SOL/USD", "AVAX/USD", "LINK/USD"]

    static let smaPeriod = 200
    static let donchianPeriod = 20
    static let atrPeriod = 22
    static let chandelierATR = 3.0
    /// Blocco drawdown ferreo: nessun nuovo ingresso sotto il −10% dal picco.
    static let maxDrawdown = 0.10

    /// Valutazione di una coppia sulle barre 1D CHIUSE (la più recente è
    /// l'ultima barra completata). Pura: stesso input, stesso output.
    struct Signal: Sendable, Equatable {
        enum State: String, Sendable, Equatable {
            /// Regime ok e rottura Donchian20: nuovo ingresso consentito.
            case entry
            /// Posizione aperta: chandelier da tenere d'occhio.
            case hold
            /// Chiusura sotto chandelier o sotto SMA200: uscita.
            case exit
            /// Regime ribassista e nessuna posizione: non si opera.
            case flat
            /// Dati insufficienti (servono ≥ 201 barre per SMA200 + Donchian).
            case warmup
        }

        let symbol: String
        let state: State
        let close: Double
        let sma200: Double
        let donchianHigh: Double
        let atr22: Double
        /// Livello chandelier corrente (uscita se la chiusura gli va sotto).
        let chandelier: Double?
    }

    /// ATR di Wilder a 22 barre, la STESSA formula dello studio
    /// (tools/backtest_trend_crypto.py: `tr.ewm(alpha=1/22, adjust=False)`),
    /// calcolata su tutte le barre ricevute: il primo true range è massimo
    /// meno minimo, poi ogni barra pesa 1/22. Con le ~260 barre che l'app
    /// scarica il valore coincide con quello dello studio (il peso della
    /// barra di partenza è sotto lo 0,01%).
    static func atr22(_ bars: [Candle]) -> Double? {
        guard bars.count >= atrPeriod + 1 else { return nil }
        let alpha = 1.0 / Double(atrPeriod)
        var atr = bars[0].high - bars[0].low
        for i in 1..<bars.count {
            let tr = max(bars[i].high - bars[i].low,
                         abs(bars[i].high - bars[i - 1].close),
                         abs(bars[i].low - bars[i - 1].close))
            atr += alpha * (tr - atr)
        }
        return atr
    }

    /// SMA200 sulle chiusure delle ultime 200 barre chiuse.
    static func sma200(_ bars: [Candle]) -> Double? {
        guard bars.count >= smaPeriod else { return nil }
        let window = bars.suffix(smaPeriod)
        return window.map(\.close).reduce(0, +) / Double(smaPeriod)
    }

    /// Massimo degli HIGH delle 20 barre PRECEDENTI l'ultima (la rottura
    /// deve superare il massimo già visto, non includerlo).
    static func donchianHigh(_ bars: [Candle]) -> Double? {
        guard bars.count >= donchianPeriod + 1 else { return nil }
        let window = bars.dropLast().suffix(donchianPeriod)
        return window.map(\.high).max()
    }

    /// Valuta la coppia. `heldHighestClose` = massimo delle chiusure da
    /// ingresso (per il chandelier); nil se non c'è posizione.
    static func evaluate(symbol: String, closedBars: [Candle], heldHighestClose: Double?) -> Signal? {
        guard let sma = sma200(closedBars), let don = donchianHigh(closedBars), let atr = atr22(closedBars) else {
            return Signal(symbol: symbol, state: .warmup, close: closedBars.last?.close ?? 0,
                          sma200: 0, donchianHigh: 0, atr22: 0, chandelier: nil)
        }
        guard closedBars.count >= smaPeriod else {
            return Signal(symbol: symbol, state: .warmup, close: closedBars.last?.close ?? 0,
                          sma200: sma, donchianHigh: don, atr22: atr, chandelier: nil)
        }
        guard let last = closedBars.last else {
            return Signal(symbol: symbol, state: .warmup, close: 0,
                          sma200: sma, donchianHigh: don, atr22: atr, chandelier: nil)
        }
        let chandelier = heldHighestClose.map { $0 - chandelierATR * atr }
        if heldHighestClose != nil {
            if last.close < sma || (chandelier.map { last.close < $0 } ?? false) {
                return Signal(symbol: symbol, state: .exit, close: last.close, sma200: sma,
                              donchianHigh: don, atr22: atr, chandelier: chandelier)
            }
            return Signal(symbol: symbol, state: .hold, close: last.close, sma200: sma,
                          donchianHigh: don, atr22: atr, chandelier: chandelier)
        }
        if last.close > sma, last.close > don {
            return Signal(symbol: symbol, state: .entry, close: last.close, sma200: sma,
                          donchianHigh: don, atr22: atr, chandelier: nil)
        }
        return Signal(symbol: symbol, state: .flat, close: last.close, sma200: sma,
                      donchianHigh: don, atr22: atr, chandelier: nil)
    }

    /// Margine tenuto sul contante: un ordine a mercato si esegue un po' sopra
    /// la quotazione e senza margine l'ultima posizione (quella limitata dal
    /// contante) verrebbe rifiutata per saldo insufficiente.
    static let cashBuffer = 0.02

    /// Budget per coppia: 1/5 del budget crypto (equal-weight, come lo studio),
    /// mai più del contante libero meno il margine.
    static func positionBudget(total: Double, cash: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(total / Double(pairs.count), max(cash, 0) * (1 - cashBuffer))
    }

    /// Quantità frazionata: Alpaca crypto accetta fino a 9 decimali, qui 8
    /// per stare larghi; mai sotto il minimo di ordine (scarta → nil).
    static func fractionalQty(budget: Double, price: Double) -> Double? {
        guard price > 0, budget > 0 else { return nil }
        let qty = (budget / price * 1e8).rounded(.down) / 1e8
        return qty > 0 ? qty : nil
    }

    /// Blocco drawdown: equity corrente contro il picco registrato.
    /// true = FERMO, nessun nuovo ingresso.
    static func drawdownBlocked(equity: Double, peak: Double?) -> Bool {
        guard let peak, peak > 0 else { return false }
        return equity / peak - 1 < -maxDrawdown
    }

    /// Prezzo crypto compatto per chip e log: le migliaia senza decimali,
    /// sotto 10 USD fino a 4 decimali (BTC e AVAX con la stessa regola).
    static func priceText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 1000 ? 0 : (value >= 10 ? 2 : 4)
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

extension CryptoStrategy.Signal {
    /// Etichetta del chip nel pannello e nei log: "FUORI" da solo non dice se
    /// la coppia è in regime ribassista (sotto SMA200: non si opera, regola
    /// V4) o se sta invece aspettando la rottura Donchian20 sopra la media.
    var chipLabel: String {
        switch state {
        case .entry: return "ENTRATA"
        case .hold: return "IN POSIZIONE"
        case .exit: return "USCITA"
        case .warmup: return "DATI…"
        case .flat:
            guard close > 0, sma200 > 0 else { return "FUORI" }
            return close < sma200
                ? "FUORI · sotto SMA200"
                : "FUORI · attende rottura \(CryptoStrategy.priceText(donchianHigh))"
        }
    }

    /// Perché la coppia è fuori, in una parola per il riepilogo del ciclo.
    var flatShortText: String {
        guard state == .flat, close > 0, sma200 > 0 else { return "fuori" }
        return close < sma200 ? "fuori sotto SMA200" : "fuori, attende rottura"
    }
}

/// Su Alpaca la stessa coppia ha due scritture: "BTC/USD" negli ordini e nei
/// dati di mercato, "BTCUSD" (senza barra) nell'elenco delle posizioni
/// (alpaca.markets/support/symbology-positions-list). Ogni confronto fra le
/// due passa da qui: confrontarle così come sono dà sempre "non c'è".
enum CryptoSymbol {
    /// Chiave di confronto: maiuscolo, senza barra ("BTC/USD" e "btcusd" -> "BTCUSD").
    static func key(_ symbol: String) -> String {
        symbol.uppercased().replacingOccurrences(of: "/", with: "")
    }

    /// Quantità della coppia nell'elenco posizioni del broker (0 = assente).
    static func quantity(of pair: String, in positions: [(symbol: String, quantity: Double)]) -> Double {
        let wanted = key(pair)
        return positions.first { key($0.symbol) == wanted }?.quantity ?? 0
    }
}

/// Registro della modalità CRYPTO (posizioni, picco equity, barre già
/// valutate): Codable leggero in UserDefaults, come DailyBook. Le quantità
/// sono frazionate (0.000123 BTC), mai azioni intere.
struct CryptoBook: Codable, Sendable, Equatable {
    struct Position: Codable, Sendable, Equatable {
        let symbol: String
        /// Barra (giorno ISO) dell'ingresso: la chiusura che ha rotto il Donchian.
        let entryDay: String
        let entryPrice: Double
        var qty: Double
        /// Massimo delle chiusure da ingresso: base del chandelier.
        var highestClose: Double
        /// Stop stop_limit GTC sul broker (protezione ad app chiusa).
        var stopOrderId: String?
        var stopPrice: Double?
        /// Alza di nuovo l'ingresso (nuovo ingresso dopo un'uscita) solo su
        /// barra NUOVA: la stessa barra non firma due volte.
        var exitedDay: String?
    }

    var positions: [Position] = []
    var cashPeak: Double?
    /// Barra già valutata per simbolo (ultima barra chiusa processata).
    var evaluatedBars: [String: String] = [:]
    /// Giorno dell'ultimo avviso "posizione senza stop" per coppia: l'avviso
    /// parte una volta al giorno, non a ogni ciclo da 60 secondi. Opzionale:
    /// i registri salvati dalle versioni precedenti non hanno il campo.
    var stopAlerts: [String: String]?

    func position(_ symbol: String) -> Position? {
        positions.first { $0.symbol == symbol }
    }

    mutating func upsert(_ position: Position) {
        if let i = positions.firstIndex(where: { $0.symbol == position.symbol }) {
            positions[i] = position
        } else {
            positions.append(position)
        }
    }

    mutating func remove(symbol: String) {
        positions.removeAll { $0.symbol == symbol }
    }
}

enum CryptoBookStore {
    private static func key(_ account: String?) -> String {
        "quantswarm.crypto.book" + (account.map { "." + $0 } ?? "")
    }

    static func load(account: String?, defaults: UserDefaults = .standard) -> CryptoBook {
        guard let data = defaults.data(forKey: key(account)) else { return CryptoBook() }
        return (try? JSONDecoder().decode(CryptoBook.self, from: data)) ?? CryptoBook()
    }

    static func save(_ book: CryptoBook, account: String?, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: key(account))
        }
    }
}
