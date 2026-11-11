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
                         capital: Double?, riskFraction: Double,
                         twin: (symbol: String, bars: [Candle])? = nil) -> MarketInsight {
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
        func fits(_ s: DailyStrategy.Snapshot) -> Bool {
            capital.map {
                RiskRules.canBuyOneShare(price: s.close, stopDistance: DailyStrategy.stopATR * s.atr14,
                                         capital: $0, freeCash: $0, riskFraction: riskFraction)
            } ?? true
        }
        // Se l'originale è troppo caro ma il gemello economico entra, si compra quello.
        let twinFits = !fits(snap) && (twin.flatMap { DailyStrategy.snapshot(of: $0.bars) }.map(fits) ?? false)
        let affordable = fits(snap) || twinFits
        let via = twinFits ? " Si compra il gemello \(twin!.symbol) (stesso indice, quota più piccola)." : ""
        if snap.close <= snap.sma200 {
            return MarketInsight(symbol: symbol, state: .trendDown, close: close, dayChange: change, snapshot: snap,
                                 reason: "Sotto la media a 200 giorni: trend in calo, il bot non compra.")
        }
        if DailyStrategy.entryCandidate(symbol: symbol, bars: bars) != nil {
            return affordable
                ? MarketInsight(symbol: symbol, state: .signal, close: close, dayChange: change, snapshot: snap,
                                reason: "Trend su e ribasso forte (RSI2 \(rsi) < 10): candidato all'acquisto, decide Kimi.\(via)")
                : MarketInsight(symbol: symbol, state: .unaffordable, close: close, dayChange: change, snapshot: snap,
                                reason: "Segnale (RSI2 \(rsi)) ma il capitale non compra 1 azione entro i limiti.")
        }
        if !affordable {
            return MarketInsight(symbol: symbol, state: .unaffordable, close: close, dayChange: change, snapshot: snap,
                                 reason: "Con questo capitale 1 azione supera il 25% o il rischio dell'1%.")
        }
        return MarketInsight(symbol: symbol, state: .trendUp, close: close, dayChange: change, snapshot: snap,
                             reason: "Trend su; si compra solo dopo un ribasso forte (RSI2 sotto 10, ora \(rsi)).\(via)")
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
