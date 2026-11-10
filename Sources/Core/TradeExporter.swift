import Foundation

/// Export CSV dei trade chiusi: per il commercialista e per confrontarli con
/// l'estratto conto Alpaca. Separatore ";" e decimali con la virgola (Excel
/// italiano). File cifrato ed escluso dai backup.
enum TradeExporter {
    static let filePrefix = "quantswarm-trade-"

    static func write(records: [TradeRecord]) -> URL? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "it_IT")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        func num(_ value: Double?, _ digits: Int = 2) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
                .replacingOccurrences(of: ".", with: ",")
        }
        func text(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
        }
        var lines = ["data;simbolo;azione;quantita;ingresso;uscita;pnl_usd;stop;target;id_ordine;motivazione"]
        for record in records.sorted(by: { $0.createdAt < $1.createdAt }) {
            let entry = record.actualEntry ?? record.expectedEntry
            let exit = record.netPnL.map { entry + $0 / max(record.requestedQuantity, 1) }
            lines.append([
                dateFormatter.string(from: record.createdAt),
                record.symbol,
                record.action,
                num(record.requestedQuantity, 0),
                num(entry),
                num(exit),
                num(record.netPnL),
                num(record.stopLoss),
                record.takeProfit > 0 ? num(record.takeProfit) : "",
                record.orderID,
                text(record.rationale)
            ].joined(separator: ";"))
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("\(filePrefix)\(stamp.string(from: Date())).csv")
        do {
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
            return url
        } catch {
            return nil
        }
    }
}
