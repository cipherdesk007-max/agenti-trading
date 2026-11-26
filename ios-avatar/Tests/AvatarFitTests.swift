import XCTest
@preconcurrency import SceneKit
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

    func testLoftGeometriaCoerente() {
        // un tubo a 3 anelli e 12 segmenti deve avere 36 vertici e 432 indici
        let anelli = [
            AnelloLoft(t: 0, rx: 5, rz: 4),
            AnelloLoft(t: 0.5, rx: 6, rz: 5),
            AnelloLoft(t: 1, rx: 4, rz: 3)
        ]
        let geo = AvatarRig.loft(da: SCNVector3(0, 0, 0), a: SCNVector3(0, 20, 0), anelli: anelli, bulge: 0.2, segmenti: 12, materiale: SCNMaterial())
        XCTAssertEqual(geo.sources.count, 2)  // vertici + normali
        XCTAssertGreaterThanOrEqual(geo.sources.first?.vectorCount ?? 0, 36)
        XCTAssertFalse(geo.elements.isEmpty)
        XCTAssertEqual(geo.elements.first?.primitiveCount ?? 0, (3 - 1) * 12 * 2)  // 48 triangoli
    }

    func testPosaCiclica() {
        // l'animazione deve chiudere il cerchio: il fotogramma dopo l'ultimo
        // riparte dall'ultima posa, non da .idle
        let keys = [
            Keyframe(pose: Pose(elbow: 0), duration: 1.0),
            Keyframe(pose: Pose(elbow: 1), duration: 1.0)
        ]
        let p = AvatarRig.posaA(2.02, keys: keys, total: 2.0)
        XCTAssertGreaterThan(p.elbow, 0.9, "il ciclo deve ripartire dalla Fine, non da idle")
        let dentro = AvatarRig.posaA(1.5, keys: keys, total: 2.0)
        XCTAssertEqual(dentro.elbow, 0.5, accuracy: 0.05)
    }

    @MainActor
    func testAppoggioPiediATerra() {
        // da fermo il bacino sta esattamente sopra lo scarpone: caviglia = altezza scarpa
        let rig = AvatarRig(measurements: Measurements(), appearance: Appearance(), fitness: 0.4, faceMesh: nil)
        let h = max(Measurements().heightCm, 120)
        let legLen = min(max(Measurements().legCm, h * 0.30), h * 0.58)
        let footH = max(h * 0.04 + CGFloat(42 - 36) * 0.06, 2)
        let atteso = 3.5 + legLen + footH
        XCTAssertEqual(rig.altezzaPelvi(.idle), atteso, accuracy: 0.01)
        // una posa appesa ha l'altezza esplicita, scalata sul corpo
        XCTAssertEqual(rig.altezzaPelvi(Pose(pelvisY: 104)), 104, accuracy: 0.001)
        // gambe flesse: il bacino scende in base alla gamba piu' corta (squat)
        let squat = Pose(hip: -1.15, knee: -1.45)
        XCTAssertLessThan(rig.altezzaPelvi(squat), atteso - 25)
    }

    @MainActor
    func testCameraVedeIlCorpo() {
        // regressione della 1.1.4: il corpo è in centimetri e la camera
        // sta a 2,2h, i piani depth di default (zFar = 100) facevano
        // sparire tutto il manichino
        let rig = AvatarRig(measurements: Measurements(), appearance: Appearance(), fitness: 0.4, faceMesh: nil)
        let camera = rig.cameraNode.camera
        XCTAssertNotNil(camera)
        guard let camera else { return }
        let h = max(Measurements().heightCm, 120)
        XCTAssertLessThan(camera.zNear, 2)
        XCTAssertGreaterThan(camera.zFar, h * 2.2 + h, "il corpo intero deve stare tra zNear e zFar")
    }

    func testVersionePubblicataParsing() {
        let json = #"{"versione":"1.1.4","build":22,"data":"2026-11-26","url":"https://esempio/AvatarFit.ipa"}"#
        let v = VersionePubblicata.da(json)
        XCTAssertEqual(v?.versione, "1.1.4")
        XCTAssertEqual(v?.build, 22)
        XCTAssertEqual(v?.url, "https://esempio/AvatarFit.ipa")
        XCTAssertNil(VersionePubblicata.da("non è json"))
        XCTAssertNil(VersionePubblicata.da(#"{"versione":"1"}"#))
    }

    func testIkPortaLaManoSulBersaglio() {
        // l'IK analitica deve mettere la mano ESATTAMENTE sul bersaglio,
        // con entrambi i rami del gomito, e saturare senza esplodere
        // fuori portata
        let spalla = Punto2D(y: 100, z: 0)
        let l1: CGFloat = 37
        let l2: CGFloat = 30
        var bersagli: [Punto2D] = []
        for dy in stride(from: CGFloat(-65), through: 65, by: 15) {
            for dz in stride(from: CGFloat(-45), through: 45, by: 15) {
                bersagli.append(Punto2D(y: 100 + dy, z: dz))
            }
        }
        for ramo in [-1, 1] {
            for bersaglio in bersagli {
                let a = angoliIk(spalla: spalla, bersaglio: bersaglio, l1: l1, l2: l2, ramo: ramo)
                let gomito = Punto2D(
                    y: spalla.y - l1 * CGFloat(cos(Double(a.spalla))),
                    z: spalla.z - l1 * CGFloat(sin(Double(a.spalla)))
                )
                let mano = Punto2D(
                    y: gomito.y - l2 * CGFloat(cos(Double(a.avambraccio))),
                    z: gomito.z - l2 * CGFloat(sin(Double(a.avambraccio)))
                )
                let d = distanza2D(mano, bersaglio)
                let dBersaglio = distanza2D(spalla, bersaglio)
                let minD = abs(l1 - l2) + 0.5
                let maxD = l1 + l2 - 0.5
                if dBersaglio >= minD && dBersaglio <= maxD {
                    XCTAssertLessThan(d, 0.01, "mano fuori dal bersaglio a ramo \(ramo)")
                } else {
                    XCTAssertLessThan(d, 1.0, "saturazione troppo brusca a ramo \(ramo)")
                }
            }
        }
    }

    @MainActor
    func testManiAncoratePerTuttoIlCiclo() {
        // nelle demo di contatto le mani non si staccano mai: la posa
        // interpolata resta sempre alla portata dell'ancora (sbarra o terra)
        let rig = AvatarRig(measurements: Measurements(), appearance: Appearance(), fitness: 0.4, faceMesh: nil)
        for movimento in [MovementType.pullUp, .pushUp, .plank] {
            rig.play(movimento, muscles: [])
            let keys = Keyframes.forMovement(movimento)
            let total = CGFloat(keys.reduce(0.0) { $0 + $1.duration })
            var t: CGFloat = 0
            while t <= total {
                let p = AvatarRig.posaA(t, keys: keys, total: total)
                let scarto = rig.scartoManiAncorate(p)
                XCTAssertLessThan(scarto, 0.6, "mani fuori portata in \(movimento.rawValue) a t=\(t)")
                t += 1.0 / 12.0
            }
            rig.stop()
        }
    }

    func testVoltoSfumato() {
        // il volto-foto sul 3D deve avere la maschera ovale sfumata e
        // restare quadrato in formato (il piano lo ritaglia lui)
        let formato = UIGraphicsImageRendererFormat.default()
        formato.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: formato)
        let tonda = renderer.image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let sfumato = AvatarRig.voltoSfumato(tonda)
        XCTAssertEqual(sfumato.size.width, 64, accuracy: 0.5)
        XCTAssertEqual(sfumato.size.height, 64, accuracy: 0.5)
        XCTAssertNotNil(sfumato.cgImage)
    }

    func testConfrontoVersioni() {
        XCTAssertEqual(VersionePubblicata.confronta("1.1.4", "1.1.3"), .orderedDescending)
        XCTAssertEqual(VersionePubblicata.confronta("1.1.3", "1.1.4"), .orderedAscending)
        XCTAssertEqual(VersionePubblicata.confronta("1.2.10", "1.2.9"), .orderedDescending)
        XCTAssertEqual(VersionePubblicata.confronta("1.1", "1.1.0"), .orderedSame)
        XCTAssertEqual(VersionePubblicata.confronta("1.1.4", "1.1.4"), .orderedSame)
    }
}
