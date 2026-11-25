import XCTest
@testable import AvatarFit

final class AvatarFitTests: XCTestCase {
    func testEpley1RM() {
        XCTAssertEqual(epley1RM(100, 1), 100)
        XCTAssertEqual(epley1RM(100, 10), 100 * (1 + 10.0 / 30), accuracy: 0.001)
        XCTAssertEqual(epley1RM(0, 10), 0)
    }

    func testBMI() {
        var m = Measurements()
        m.heightCm = 180
        m.weightKg = 72
        XCTAssertEqual(m.bmi, 72 / (1.8 * 1.8), accuracy: 0.001)
        m.heightCm = 0
        XCTAssertEqual(m.bmi, 0)
    }

    func testKeyframeCopronoTuttiIMovimenti() {
        for movement in MovementType.allCases {
            let keys = Keyframes.forMovement(movement)
            XCTAssertFalse(keys.isEmpty, "keyframe mancanti per \(movement.rawValue)")
            XCTAssertTrue(keys.allSatisfy { $0.duration > 0 })
        }
    }

    func testTraguardiSaluteOrdinati() {
        let minuti = HealthMilestone.all.map(\.minutes)
        XCTAssertEqual(minuti, minuti.sorted())
    }

    func testLerpPose() {
        let p = lerpPose(.idle, Pose(elbow: 2, hip: 1), 0.5)
        XCTAssertEqual(p.elbow, 1.0, accuracy: 0.0001)
        XCTAssertEqual(p.hip, 0.5, accuracy: 0.0001)
        XCTAssertEqual(lerpPose(.idle, Pose(elbow: 2), 0).elbow, 0, accuracy: 0.0001)
    }

    func testEsercizioBest1RM() {
        let ex = Exercise(name: "Panca piana", muscle: .petto, equipment: "Bilanciere", movement: .bench)
        XCTAssertEqual(ex.best1RM, 0)
        var e2 = ex
        e2.history = [ExerciseLog(date: Date(), weight: 100, reps: 5)]
        XCTAssertEqual(e2.best1RM, epley1RM(100, 5), accuracy: 0.001)
    }

    func testFrazioniPesoCorporeo() {
        XCTAssertEqual(MovementType.pullUp.bodyweightFraction, 1.0)
        XCTAssertEqual(MovementType.pushUp.bodyweightFraction, 0.64)
        XCTAssertEqual(MovementType.squat.bodyweightFraction, 0.65)
        XCTAssertEqual(MovementType.lunge.bodyweightFraction, 0.65)
        XCTAssertEqual(MovementType.plank.bodyweightFraction, 0.5)
        XCTAssertEqual(MovementType.bench.bodyweightFraction, 0)
        XCTAssertEqual(MovementType.row.bodyweightFraction, 0)
        XCTAssertEqual(MovementType.curl.bodyweightFraction, 0)
        XCTAssertEqual(MovementType.lateralRaise.bodyweightFraction, 0)
        XCTAssertEqual(MovementType.custom.bodyweightFraction, 0)
        XCTAssertTrue(MovementType.pushUp.usesBodyweight)
        XCTAssertFalse(MovementType.bench.usesBodyweight)
    }

    func testEffectiveLoad() {
        // flessioni a corpo libero, 72 kg: 64% del peso
        XCTAssertEqual(effectiveLoad(movement: .pushUp, bodyWeightKg: 72, addedKg: 0), 46.08, accuracy: 0.001)
        // trazioni con zavorra 10 kg: corpo intero + extra
        XCTAssertEqual(effectiveLoad(movement: .pullUp, bodyWeightKg: 72, addedKg: 10), 82, accuracy: 0.001)
        // panca: solo il carico esterno
        XCTAssertEqual(effectiveLoad(movement: .bench, bodyWeightKg: 72, addedKg: 100), 100, accuracy: 0.001)
        // input negativi: mai sotto zero
        XCTAssertEqual(effectiveLoad(movement: .pushUp, bodyWeightKg: -5, addedKg: -1), 0, accuracy: 0.001)
    }

    func test1RMCorpoLiberoNonZero() {
        // il bug originale: 12 flessioni a corpo libero con 72 kg davano 1RM = 0 kg
        let load = effectiveLoad(movement: .pushUp, bodyWeightKg: 72, addedKg: 0)
        XCTAssertGreaterThan(epley1RM(load, 12), 40)
        let ex = Exercise(name: "Flessioni", muscle: .petto, equipment: "Corpo libero", movement: .pushUp)
        var e2 = ex
        e2.history = [ExerciseLog(date: Date(), weight: load, reps: 12)]
        XCTAssertGreaterThan(e2.best1RM, 40)
    }
}
