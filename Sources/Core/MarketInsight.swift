import Foundation

/// Lettura di un ETF secondo le regole della modalità giornaliera, in parole:
/// cosa sta facendo il prezzo e perché il bot compra o non compra.
/// Logica pura (Tests/MarketInsightTests): la UI la mostra e basta.
struct MarketInsight: Sendable, Equatable {
    enum State: String, Sendable {
        case held = "IN POSIZIONE"
        case signal = "SEGNALE"
        case unaffordable = "FUORI CAPITALE"
        case trendUp = "TREND SU"
        case trendDown = "TREND GIÙ"
        case noData = "DATI"
    }

    let symbol: String
    let state: State
    let close: Double?
    let dayChange: Double?
    let snapshot: DailyStrategy.Snapshot?
    /// Spiegazione in una frase.
    let reason: String

    /// `capital` nil = saldo del conto non ancora letto: non si giudica la
    /// comprabilità (meglio nessun giudizio che "fuori capitale" sbagliato).
    static func evaluate(symbol: String, bars: [Candle], held: Bool,
                         capital: Double?, riskFraction: Double) -> MarketInsight {
        let close = bars.last?.close
        let change: Double? = bars.count >= 2 ? bars[bars.count - 1].close / bars[bars.count - 2].close - 1 : nil
        guard let snap = DailyStrategy.snapshot(of: bars) else {
            return MarketInsight(symbol: symbol, state: .noData, close: close, dayChange: change, snapshot: nil,
                                 reason: "Servono almeno \(DailyStrategy.minimumBars) sedute di storico.")
        }
        let rsi = String(format: "%.1f", snap.rsi2)
        if held {
            return MarketInsight(symbol: symbol, state: .held, close: close, dayChange: change, snapshot: snap,
                                 reason: "Posizione aperta: esce quando chiude sopra la media a 5 giorni o dopo \(DailyStrategy.maxHoldingDays) sedute; stop sul broker.")
        }
        let affordable = capital.map {
            RiskRules.canBuyOneShare(price: snap.close, stopDistance: DailyStrategy.stopATR * snap.atr14,
                                     capital: $0, freeCash: $0, riskFraction: riskFraction)
        } ?? true
        if snap.close <= snap.sma200 {
            return MarketInsight(symbol: symbol, state: .trendDown, close: close, dayChange: change, snapshot: snap,
                                 reason: "Sotto la media a 200 giorni: trend in calo, il bot non compra.")
        }
        if DailyStrategy.entryCandidate(symbol: symbol, bars: bars) != nil {
            return affordable
                ? MarketInsight(symbol: symbol, state: .signal, close: close, dayChange: change, snapshot: snap,
                                reason: "Trend su e ribasso forte (RSI2 \(rsi) < 10): candidato all'acquisto, decide Kimi.")
                : MarketInsight(symbol: symbol, state: .unaffordable, close: close, dayChange: change, snapshot: snap,
                                reason: "Segnale (RSI2 \(rsi)) ma il capitale non compra 1 azione entro i limiti.")
        }
        if !affordable {
            return MarketInsight(symbol: symbol, state: .unaffordable, close: close, dayChange: change, snapshot: snap,
                                 reason: "Con questo capitale 1 azione supera il 25% o il rischio dell'1%.")
        }
        return MarketInsight(symbol: symbol, state: .trendUp, close: close, dayChange: change, snapshot: snap,
                             reason: "Trend su; si compra solo dopo un ribasso forte (RSI2 sotto 10, ora \(rsi)).")
    }

    /// Media mobile semplice punto per punto (nil finché non ci sono `period` valori).
    static func movingAverage(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return values.map { _ in nil } }
        var result: [Double?] = []
        result.reserveCapacity(values.count)
        var sum = 0.0
        for (index, value) in values.enumerated() {
            sum += value
            if index >= period { sum -= values[index - period] }
            result.append(index >= period - 1 ? sum / Double(period) : nil)
        }
        return result
    }
}

extension MarketInsight {
    /// Casella di MERCATI per una coppia crypto, letta dalla regola V4 che
    /// l'app applica davvero (`CryptoStrategy.Signal`): stesse parole degli
    /// ETF. `livePrice` = prezzo di adesso; la variazione è rispetto
    /// all'ultima chiusura giornaliera. Funzione pura, sotto test.
    static func crypto(pair: String, signal: CryptoStrategy.Signal?, livePrice: Double?, held: Bool) -> MarketInsight {
        let live = (livePrice ?? 0) > 0 ? livePrice : nil
        guard let signal, signal.state != .warmup, signal.close > 0 else {
            return MarketInsight(symbol: pair, state: held ? .held : .noData, close: live, dayChange: nil, snapshot: nil,
                                 reason: "Dati non ancora disponibili: servono 200 chiusure giornaliere e il primo controllo dell'app.")
        }
        let price = live ?? signal.close
        let change = price / signal.close - 1
        let state: State
        let reason: String
        if held || signal.state == .hold || signal.state == .exit {
            state = .held
            reason = signal.state == .exit
                ? "In posizione, ma la chiusura è scesa sotto il chandelier o la media a 200 giorni: l'app esce."
                : "In posizione: esce se la chiusura giornaliera scende sotto il chandelier (massimo dall'ingresso meno 3 ATR) o sotto la media a 200 giorni. Stop sul broker."
        } else if signal.state == .entry {
            state = .signal
            reason = "Chiusura sopra il massimo dei 20 giorni e sopra la media a 200: segnale d'ingresso."
        } else if signal.close < signal.sma200 {
            state = .trendDown
            reason = "Sotto la media a 200 giorni (\(CryptoStrategy.priceText(signal.sma200))): la regola non compra."
        } else {
            state = .trendUp
            reason = "Sopra la media a 200 giorni: compra se chiude sopra \(CryptoStrategy.priceText(signal.donchianHigh)), il massimo dei 20 giorni."
        }
        return MarketInsight(symbol: pair, state: state, close: price, dayChange: change, snapshot: nil, reason: reason)
    }
}

