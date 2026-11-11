import Foundation

/// Un punto per giorno di borsa: patrimonio del conto, capitale del bot e
/// prezzo di SPY (riferimento "compra e tieni" per capire se il bot vale la pena).
struct EquityPoint: Codable, Sendable, Equatable {
    let day: String
    var equity: Double
    var benchmark: Double?
    /// Capitale del bot in quel momento: min(patrimonio, tetto). nil = patrimonio.
    var capital: Double?
}

/// Logica pura della curva del capitale (verificata da Tests/EquityHistoryTests).
enum EquityHistory {
    static let maximumPoints = 750

    /// Aggiorna il punto del giorno (l'ultimo controllo del giorno vince)
    /// oppure ne aggiunge uno nuovo. Valori non validi vengono ignorati.
    static func record(_ points: [EquityPoint], day: String, equity: Double, benchmark: Double?,
                       capital: Double? = nil) -> [EquityPoint] {
        guard equity.isFinite, equity > 0, !day.isEmpty else { return points }
        let bench = benchmark.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let cap = capital.flatMap { $0.isFinite && $0 > 0 ? min($0, equity) : nil }
        var copy = points
        if let last = copy.last, last.day == day {
            copy[copy.count - 1] = EquityPoint(day: day, equity: equity, benchmark: bench ?? last.benchmark,
                                               capital: cap ?? last.capital)
        } else if let last = copy.last, last.day > day {
            return points // orologio indietro: non si riscrive la storia
        } else {
            copy.append(EquityPoint(day: day, equity: equity, benchmark: bench, capital: cap))
        }
        if copy.count > maximumPoints { copy.removeFirst(copy.count - maximumPoints) }
        return copy
    }

    struct Summary: Sendable, Equatable {
        let days: Int
        /// Guadagno del conto dal primo punto diviso il capitale del bot di
        /// allora: con 10.000 USD di capitale su un conto da 100.000, +500 USD
        /// sono +5% (non +0,5%).
        let botReturn: Double
        /// Rendimento di SPY sullo stesso periodo (nil se mancano i prezzi).
        let benchmarkReturn: Double?
        /// Massima perdita dal picco del patrimonio (valore negativo o 0).
        let maxDrawdown: Double
    }

    static func summary(_ points: [EquityPoint]) -> Summary? {
        guard points.count >= 2 else { return nil }
        let line = normalized(points).bot
        var peak = line[0]
        var worst = 0.0
        for value in line {
            peak = max(peak, value)
            worst = min(worst, value / peak - 1)
        }
        let bench: Double?
        if let firstBench = points.first(where: { $0.benchmark != nil })?.benchmark,
           let lastBench = points.last(where: { $0.benchmark != nil })?.benchmark {
            bench = lastBench / firstBench - 1
        } else {
            bench = nil
        }
        return Summary(days: points.count, botReturn: line[line.count - 1] / 100 - 1,
                       benchmarkReturn: bench, maxDrawdown: worst)
    }

    /// Serie normalizzate a 100 al primo punto, per disegnarle sulla stessa scala.
    static func normalized(_ points: [EquityPoint]) -> (bot: [Double], benchmark: [Double?]) {
        guard let first = points.first else { return ([], []) }
        let firstBench = points.first(where: { $0.benchmark != nil })?.benchmark
        let base = first.capital ?? first.equity
        let bot = points.map { 100 * (1 + ($0.equity - first.equity) / base) }
        let bench = points.map { point -> Double? in
            guard let value = point.benchmark, let base = firstBench else { return nil }
            return value / base * 100
        }
        return (bot, bench)
    }
}

/// Una curva per conto Alpaca (numero del conto): paper, live e ogni nuovo
/// conto paper non si mescolano mai.
enum EquityHistoryStore {
    private static func key(_ account: String) -> String {
        "com.quantswarm.alphazero.equityHistory.\(account)"
    }

    static func load(account: String) -> [EquityPoint] {
        guard let data = UserDefaults.standard.data(forKey: key(account)),
              let points = try? JSONDecoder().decode([EquityPoint].self, from: data) else { return [] }
        return points
    }

    static func save(_ points: [EquityPoint], account: String) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        UserDefaults.standard.set(data, forKey: key(account))
    }
}
