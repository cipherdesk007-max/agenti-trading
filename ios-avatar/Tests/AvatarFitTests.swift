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

    @MainActor
    func testDecodificaSnapshotDemoAvatar() throws {
        // il file usato dalla CI per gli screenshot deve decodificarsi esattamente
        // come i dati dell'app ( stessi tipi, stesse chiavi )
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // ios-avatar/
        let url = dir.appendingPathComponent("Demo/avatar-demo.json")
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(AppStore.Snapshot.self, from: data)
        XCTAssertEqual(snap.measurements.heightCm, 187)
        XCTAssertEqual(snap.measurements.weightKg, 83)
        XCTAssertEqual(snap.events.count, 3)
        XCTAssertEqual(snap.workouts.count, 4)
        XCTAssertEqual(snap.trackers.count, 3)
        XCTAssertEqual(snap.exercises.count, 11)
        XCTAssertTrue(snap.smoke.enabled)
        XCTAssertEqual(snap.exercises.first?.history.count ?? 0, 2)
        XCTAssertNotNil(snap.demoExerciseId)
    }

    func testTabDaArgomentiDiLancio() {
        XCTAssertEqual(AppTab.tab(fromArgs: []), .home)
        XCTAssertEqual(AppTab.tab(fromArgs: ["--tab=workout"]), .workout)
        XCTAssertEqual(AppTab.tab(fromArgs: ["altro", "--tab=Sistema"]), .sistema)
        XCTAssertEqual(AppTab.tab(fromArgs: ["--tab=INESISTENTE"]), .home)
        XCTAssertEqual(AppTab.tab(fromArgs: ["--tab=workout", "--tab=tracker"]), .workout)
        XCTAssertEqual(AppTab.tab(fromArgs: ["--tab"]), .home)
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

    func testSceltaFotoPreferisceUltimoSelfie() {
        // lista vuota: nessuna scelta
        XCTAssertNil(SceltaFoto.migliore([ ]))
        let adesso = Date()
        let selfieVecchio = FotoCandidata(id: "a", data: adesso.addingTimeInterval(-3600), selfie: true)
        let fotoRecente = FotoCandidata(id: "b", data: adesso, selfie: false)
        // esiste un selfie: vince anche se la foto del rullino è più recente
        XCTAssertEqual(SceltaFoto.migliore([selfieVecchio, fotoRecente])?.id, "a")
        // tra due selfie vince il più recente
        let selfieNuovo = FotoCandidata(id: "c", data: adesso.addingTimeInterval(-60), selfie: true)
        XCTAssertEqual(SceltaFoto.migliore([selfieVecchio, selfieNuovo, fotoRecente])?.id, "c")
        // senza selfie: l'ultima foto del rullino
        XCTAssertEqual(SceltaFoto.migliore([fotoRecente])?.id, "b")
    }

    func testRitaglioVisoCerchio() {
        let formato = UIGraphicsImageRendererFormat()
        formato.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 60), format: formato)
        let immagine = renderer.image { contesto in
            UIColor.red.setFill()
            contesto.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        }
        // lato minore, quadrata
        let cerchio = RitaglioViso.cerchio(immagine)
        XCTAssertNotNil(cerchio)
        XCTAssertEqual(cerchio?.size.width ?? 0, 60, accuracy: 1)
        XCTAssertEqual(cerchio?.size.height ?? 0, 60, accuracy: 1)
        // il lato massimo viene rispettato
        let grande = RitaglioViso.cerchio(immagine, latoMax: 30)
        XCTAssertEqual(grande?.size.width ?? 0, 30, accuracy: 1)
        // immagine senza contenuto: nessun ritaglio
        XCTAssertNil(RitaglioViso.cerchio(UIImage()))
    }
}
