import Foundation

/// Storico candele per simbolo. Le candele 1m arrivano dallo stream (Alpaca
/// invia la barra a minuto concluso) o dal backfill REST all'avvio; le 15m
/// sono aggregate in codice. La candela in formazione resta privata: Kimi e
/// i filtri vedono solo candele CHIUSE.
struct CandleStore: Sendable {
    private let capacity: Int
    private(set) var oneMinute: [Candle] = []
    private(set) var fifteenMinute: [Candle] = []
    private var forming15m: Candle?

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    /// Backfill all'avvio: l'ultima candela restituita dal REST può essere
    /// ancora in formazione, quindi viene scartata (verrà ricostruita dallo
    /// stream man mano che i minuti si chiudono).
    mutating func seed(oneMinute newOneMinute: [Candle], fifteenMinute newFifteen: [Candle]) {
        var one = newOneMinute
        if let last = one.last, Date() < last.timestamp.addingTimeInterval(60) {
            one.removeLast()
        }
        var fifteen = newFifteen
        if let last = fifteen.last, Date() < last.timestamp.addingTimeInterval(900) {
            fifteen.removeLast()
        }
        oneMinute = Array(one.suffix(capacity))
        fifteenMinute = Array(fifteen.suffix(capacity))
        forming15m = nil
    }

    /// Ingesta una candela 1m chiusa: aggiorna la serie 1m e l'aggregazione
    /// 15m. Duplicati e candele fuori ordine vengono ignorati.
    mutating func ingest(_ candle: Candle) {
        if let last = oneMinute.last {
            if candle.timestamp == last.timestamp {
                oneMinute[oneMinute.count - 1] = candle
            } else if candle.timestamp > last.timestamp {
                oneMinute.append(candle)
            } else {
                return
            }
        } else {
            oneMinute.append(candle)
        }
        if oneMinute.count > capacity {
            oneMinute.removeFirst(oneMinute.count - capacity)
        }
        aggregate15m(candle)
    }

    private mutating func aggregate15m(_ candle: Candle) {
        let bucket = Date(
            timeIntervalSince1970: (candle.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900
        )
        if let forming = forming15m, forming.timestamp == bucket {
            forming15m = Candle(
                timestamp: bucket,
                open: forming.open,
                high: max(forming.high, candle.high),
                low: min(forming.low, candle.low),
                close: candle.close,
                volume: forming.volume + candle.volume
            )
        } else {
            if let forming = forming15m {
                fifteenMinute.append(forming)
                if fifteenMinute.count > capacity {
                    fifteenMinute.removeFirst(fifteenMinute.count - capacity)
                }
            }
            forming15m = Candle(
                timestamp: bucket,
                open: candle.open,
                high: candle.high,
                low: candle.low,
                close: candle.close,
                volume: candle.volume
            )
        }
    }

    var oneMinuteCount: Int { oneMinute.count }

    /// Contesto per Kimi: ultime 100 candele chiuse + indicatori su 2 timeframe.
    func context(candlesPerTimeframe: Int = 100) -> MarketContext {
        MarketContext(
            oneMinuteCandles: Array(oneMinute.suffix(candlesPerTimeframe)),
            fifteenMinuteCandles: Array(fifteenMinute.suffix(candlesPerTimeframe)),
            oneMinuteIndicators: Indicators.snapshot(of: oneMinute),
            fifteenMinuteIndicators: Indicators.snapshot(of: fifteenMinute)
        )
    }
}

/// Indicatori tecnici calcolati in codice (Wilder dove applicabile):
/// nessuna stima delegata al modello.
enum Indicators {
    static func snapshot(of candles: [Candle]) -> IndicatorSnapshot {
        let closes = candles.map(\.close)
        let volumes = candles.map(\.volume)
        return IndicatorSnapshot(
            rsi14: rsi(closes, period: 14),
            ema12: ema(closes, period: 12),
            ema26: ema(closes, period: 26),
            sma50: sma(closes, period: 50),
            sma200: sma(closes, period: 200),
            atr14: atr(candles, period: 14),
            high20: candles.suffix(20).map(\.high).max(),
            low20: candles.suffix(20).map(\.low).min(),
            avgVolume20: sma(volumes, period: 20)
        )
    }

    static func sma(_ values: [Double], period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        return values.suffix(period).reduce(0, +) / Double(period)
    }

    /// EMA con seed = SMA del primo periodo, poi smoothing k = 2/(n+1).
    static func ema(_ values: [Double], period: Int) -> Double? {
        guard period > 1, values.count >= period else { return nil }
        let k = 2.0 / Double(period + 1)
        var current = values.prefix(period).reduce(0, +) / Double(period)
        for value in values.dropFirst(period) {
            current = value * k + current * (1 - k)
        }
        return current
    }

    /// RSI di Wilder: medie esponenziali di gain/loss sulle variazioni di close.
    static func rsi(_ closes: [Double], period: Int = 14) -> Double? {
        guard closes.count > period else { return nil }
        var gains = 0.0
        var losses = 0.0
        for index in 1...period {
            let change = closes[index] - closes[index - 1]
            if change >= 0 { gains += change } else { losses -= change }
        }
        var averageGain = gains / Double(period)
        var averageLoss = losses / Double(period)
        guard closes.count > period + 1 else {
            return rsiValue(gain: averageGain, loss: averageLoss)
        }
        for index in (period + 1)..<closes.count {
            let change = closes[index] - closes[index - 1]
            averageGain = (averageGain * Double(period - 1) + max(change, 0)) / Double(period)
            averageLoss = (averageLoss * Double(period - 1) + max(-change, 0)) / Double(period)
        }
        return rsiValue(gain: averageGain, loss: averageLoss)
    }

    private static func rsiValue(gain: Double, loss: Double) -> Double {
        if loss == 0 { return gain == 0 ? 50 : 100 }
        let rs = gain / loss
        return 100 - 100 / (1 + rs)
    }

    /// ATR di Wilder sulle candele chiuse.
    static func atr(_ candles: [Candle], period: Int = 14) -> Double? {
        guard candles.count > period else { return nil }
        var trueRanges: [Double] = []
        trueRanges.reserveCapacity(candles.count - 1)
        for index in 1..<candles.count {
            let current = candles[index]
            let previousClose = candles[index - 1].close
            trueRanges.append(max(
                current.high - current.low,
                abs(current.high - previousClose),
                abs(current.low - previousClose)
            ))
        }
        guard trueRanges.count >= period else { return nil }
        var atr = trueRanges.prefix(period).reduce(0, +) / Double(period)
        for range in trueRanges.dropFirst(period) {
            atr = (atr * Double(period - 1) + range) / Double(period)
        }
        return atr
    }
}
