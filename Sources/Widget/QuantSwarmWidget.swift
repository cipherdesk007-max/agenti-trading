import WidgetKit
import SwiftUI

private struct WidgetStatusSnapshot: Codable {
    let updatedAt: Date
    let isRunning: Bool
    let paperTrading: Bool
    let status: String
    let equity: Double?
    let dayPnL: Double?
    let positionsCount: Int
    let openOrdersCount: Int
    let symbols: [String]
    let kimiModel: String
    let riskPerTradePercent: Double
}

private struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetStatusSnapshot?
}

private struct Provider: TimelineProvider {
    private let suiteName = "group.com.quantswarm.alphazero"
    private let statusKey = "widget_status_json"

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), snapshot: load())
        let refresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func load() -> WidgetStatusSnapshot? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: statusKey) else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetStatusSnapshot.self, from: data)
    }
}

private struct QuantSwarmWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private let green = Color(red: 0.1, green: 1.0, blue: 0.55)

    var body: some View {
        ZStack {
            Color.black
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .containerBackground(.black, for: .widget)
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(snapshot.isRunning ? green : .gray)
                    .frame(width: 8, height: 8)
                Text(snapshot.isRunning ? "ENGINE LIVE" : "ENGINE OFF")
                    .font(.system(.caption2, design: .monospaced, weight: .black))
                    .foregroundStyle(snapshot.isRunning ? green : .gray)
                Spacer()
                Text(snapshot.paperTrading ? "PAPER" : "LIVE")
                    .font(.system(.caption2, design: .monospaced, weight: .black))
                    .foregroundStyle(snapshot.paperTrading ? green : .red)
            }

            Text(snapshot.status)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)

            if let equity = snapshot.equity {
                Text(money(equity))
                    .font(.system(family == .systemSmall ? .title3 : .title2, design: .monospaced, weight: .black))
                    .foregroundStyle(.white)
            }
            if let dayPnL = snapshot.dayPnL {
                Text(signed(dayPnL))
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(dayPnL >= 0 ? green : .red)
            }

            if family != .systemSmall {
                HStack {
                    Text("POS \(snapshot.positionsCount)")
                    Text("ORD \(snapshot.openOrdersCount)")
                    Spacer()
                    Text(snapshot.symbols.prefix(3).joined(separator: ","))
                }
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.gray)
                Text("\(snapshot.kimiModel) · rischio \(String(format: "%.2f", snapshot.riskPerTradePercent))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUANTSWARM")
                .font(.system(.caption, design: .monospaced, weight: .black))
                .foregroundStyle(green)
            Text("Apri l'app una volta per pubblicare lo stato del motore.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
        }
        .padding(12)
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "-") + money(abs(value))
    }
}

@main
struct QuantSwarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuantSwarmStatusWidget()
    }
}

private struct QuantSwarmStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.quantswarm.alphazero.widget",
            provider: Provider()
        ) { entry in
            QuantSwarmWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("QuantSwarm Status")
        .description("Mostra se il motore è attivo, equity e P&L giornaliero. Read-only: niente ordini dal widget.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
