import Foundation
import WidgetKit

/// Snapshot condiviso con la Widget Extension tramite App Group.
/// Il widget è read-only: mostra se il motore è vivo, non invia ordini.
struct WidgetStatusSnapshot: Codable, Sendable {
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

enum WidgetStatusBridge {
    private static let suiteName = "group.com.quantswarm.alphazero"
    private static let statusKey = "widget_status_json"
    private static let widgetKind = "com.quantswarm.alphazero.widget"
    private static var lastWriteAt: Date?

    @MainActor
    static func write(engine: QuantSwarmEngine, force: Bool = false) {
        let now = Date()
        if !force, let lastWriteAt, now.timeIntervalSince(lastWriteAt) < 10 {
            return
        }
        lastWriteAt = now
        let snapshot = WidgetStatusSnapshot(
            updatedAt: now,
            isRunning: engine.isRunning,
            paperTrading: engine.paperTrading,
            status: engine.statusMessage,
            equity: engine.account?.equityValue,
            dayPnL: engine.account?.dayPnL,
            positionsCount: engine.positions.count,
            openOrdersCount: engine.openOrders.count,
            symbols: engine.configuredSymbolsForWidget,
            kimiModel: engine.strategyConfig.kimiModel,
            riskPerTradePercent: engine.strategyConfig.riskPerTradePercent
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: statusKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    static func clear() {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: statusKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
