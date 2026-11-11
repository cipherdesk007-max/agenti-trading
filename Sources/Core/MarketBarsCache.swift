import Foundation

/// Ultime barre giornaliere dei 15 ETF salvate su disco (cartella Caches,
/// esclusa dal backup): all'apertura i grafici compaiono subito, poi il primo
/// controllo li aggiorna. Dati di mercato pubblici, nessun dato del conto.
enum MarketBarsCache {
    struct Payload: Codable {
        let savedAt: Date
        let bars: [String: [Candle]]
    }

    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("market-bars.json")
    }

    static func save(_ bars: [String: [Candle]], now: Date = Date()) {
        guard let url, !bars.isEmpty else { return }
        // 300 sedute: media a 200 su tutti i 90 giorni del grafico.
        let trimmed = bars.mapValues { Array($0.suffix(300)) }
        guard let data = try? JSONEncoder().encode(Payload(savedAt: now, bars: trimmed)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Payload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
