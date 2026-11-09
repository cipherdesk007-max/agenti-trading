import Foundation

/// Export del dataset di training in formato JSONL (una decisione per riga).
///
/// Stessa politica del report di sessione: nessuna scrittura durante il
/// trading (i campioni vivono in SwiftData), il file nasce solo su richiesta
/// ESPORTA, ne esiste sempre al massimo UNO, ELIMINA lo cancella dopo l'invio.
enum DatasetExporter {
    static let filePrefix = "quantswarm-training-"

    static func write(samples: [DecisionSample]) -> URL? {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        lines.reserveCapacity(samples.count)
        for sample in samples {
            guard let data = try? encoder.encode(TrainingSampleDTO(sample: sample)),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }

        let url = directory.appendingPathComponent("\(filePrefix)\(fileStamp(Date())).jsonl")
        do {
            deleteAllExports(in: directory)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func existingExportURL() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func deleteAllExports(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// Riga del dataset: chiavi snake_case, pronta per essere letta da qualsiasi
/// pipeline di training/analisi (pandas, fine-tuning, notebook).
private struct TrainingSampleDTO: Encodable {
    let timestamp: Date
    let symbol: String
    let price: Double
    let atr14: Double
    let action: String
    let confidence: Double
    let entry: Double
    let stop: Double
    let target: Double
    let winProbability: Double
    let payoff: Double
    let rationale: String
    let executed: Bool
    let orderID: String?
    let netPnl: Double?
    let postHoldMovePct: Double?
    let outcome: String

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case symbol
        case price
        case atr14 = "atr_14"
        case action
        case confidence
        case entry
        case stop
        case target
        case winProbability = "win_prob"
        case payoff
        case rationale
        case executed
        case orderID = "order_id"
        case netPnl = "net_pnl"
        case postHoldMovePct = "post_hold_move_pct"
        case outcome
    }

    init(sample: DecisionSample) {
        timestamp = sample.createdAt
        symbol = sample.symbol
        price = sample.price
        atr14 = sample.atr14
        action = sample.action
        confidence = sample.confidence
        entry = sample.entryPrice
        stop = sample.stopLoss
        target = sample.takeProfit
        winProbability = sample.winProbability
        payoff = sample.payoffRatio
        rationale = sample.rationale
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        executed = sample.executed
        orderID = sample.orderID
        netPnl = sample.netPnL
        postHoldMovePct = sample.postHoldMovePct
        if let pnl = sample.netPnL {
            outcome = pnl > 0 ? "win" : (pnl < 0 ? "loss" : "flat")
        } else if sample.postHoldMovePct != nil {
            outcome = "hold_evaluated"
        } else {
            outcome = "pending"
        }
    }
}
