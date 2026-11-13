import Foundation
import SwiftData

/// Potatura della memoria degli agenti in SwiftData. `CouncilRecord` e
/// `DecisionSample` crescono a ogni decisione (consiglio / hold): senza potatura lo
/// store cresce senza limite nel tempo. `TradeRecord` NON viene toccato: è lo storico
/// delle operazioni, esportabile dall'app.
enum MemoryPruner {
    /// Ritenzione della memoria agenti: 90 giorni.
    static let retentionDays = 90

    /// Elimina CouncilRecord e DecisionSample più vecchi di `retentionDays` rispetto a
    /// `now`. Ritorna quanti record ha eliminato. Sicura con context nil (0 eliminati).
    @discardableResult
    static func prune(context: ModelContext?, now: Date = Date()) -> Int {
        guard let context else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? now
        var removed = 0
        let oldCouncil = FetchDescriptor<CouncilRecord>(predicate: #Predicate<CouncilRecord> { $0.createdAt < cutoff })
        if let records = try? context.fetch(oldCouncil) {
            for record in records { context.delete(record) }
            removed += records.count
        }
        let oldSamples = FetchDescriptor<DecisionSample>(predicate: #Predicate<DecisionSample> { $0.createdAt < cutoff })
        if let samples = try? context.fetch(oldSamples) {
            for sample in samples { context.delete(sample) }
            removed += samples.count
        }
        if removed > 0 { try? context.save() }
        return removed
    }
}
