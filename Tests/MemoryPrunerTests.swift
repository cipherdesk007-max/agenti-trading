import XCTest
import SwiftData
@testable import QuantSwarmAlphaZero

/// Test della potatura della memoria agenti (SwiftData in-memory): i record vecchi
/// vengono eliminati, quelli recenti restano, context nil è sicuro.
final class MemoryPrunerTests: XCTestCase {

    private func decision(_ symbol: String = "SPY") -> KimiDecision {
        KimiDecision(symbol: symbol, action: .buy, confidence: 0.8, entryPrice: 500,
                     stopLoss: 490, takeProfit: 520, winProbability: 0.6, payoffRatio: 2,
                     rationale: "test")
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: CouncilRecord.self, DecisionSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testPruneRemovesOnlyOldRecords() throws {
        let context = try makeContext()
        let now = Date()
        let old = now.addingTimeInterval(-Double(MemoryPruner.retentionDays + 10) * 86_400)
        let recent = now.addingTimeInterval(-3_600)
        for i in 0..<5 {
            let r = CouncilRecord(reports: [], divergence: nil, decision: decision("SPY\(i)"), price: 500)
            r.createdAt = old
            context.insert(r)
            let s = DecisionSample(decision: decision("SPY\(i)"), price: 500, atr: 2)
            s.createdAt = old
            context.insert(s)
        }
        for i in 0..<3 {
            let r = CouncilRecord(reports: [], divergence: nil, decision: decision("QQQ\(i)"), price: 400)
            r.createdAt = recent
            context.insert(r)
        }
        try context.save()

        let removed = MemoryPruner.prune(context: context, now: now)
        XCTAssertEqual(removed, 10, "5 CouncilRecord + 5 DecisionSample vecchi vanno eliminati")
        XCTAssertEqual(try context.fetch(FetchDescriptor<CouncilRecord>()).count, 3, "restano solo i recenti")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DecisionSample>()).count, 0)
    }

    func testPruneKeepsEverythingWhenRecent() throws {
        let context = try makeContext()
        context.insert(CouncilRecord(reports: [], divergence: nil, decision: decision(), price: 500))
        try context.save()
        XCTAssertEqual(MemoryPruner.prune(context: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CouncilRecord>()).count, 1)
    }

    func testPruneWithNilContextIsSafe() {
        XCTAssertEqual(MemoryPruner.prune(context: nil), 0)
    }
}
