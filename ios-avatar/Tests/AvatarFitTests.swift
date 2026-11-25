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
}
