import XCTest
@preconcurrency import SceneKit
@testable import AvatarFit

// I numeri attesi vengono dalla simulazione Python del driver personaggio
// (studio fase 2, docs/STUDIO-AVATAR3D.md) con le misure di default
// (175 cm, gamba 92, braccio 62). Le tolleranze sono ampie ~3 cm per
// coprire la differenza tra l'incorniciamento glTF puro della sim e i
// limiti della bounding box SceneKit.

final class PersonaggioTests: XCTestCase {

    @MainActor
    private func nuovo() throws -> PersonaggioRig {
        guard PersonaggioRig.disponibile else {
            throw XCTSkip("file CC0 del personaggio non nel bundle (CI: scaricali prima di xcodegen)")
        }
        guard let rig = PersonaggioRig(measurements: Measurements()) else {
            XCTFail("il glTF c'è ma non si carica. CrashLog: " + CrashLog.tail(6))
            throw XCTSkip("rig non creato")
        }
        return rig
    }

    /// una misura dentro la banda centro ± tol
    private func dentro(_ valore: Double, _ centro: Double, _ tol: Double, _ nome: String) {
        XCTAssertLessThanOrEqual(abs(valore - centro), tol, "\(nome): \(valore) atteso ~\(centro)")
    }

    @MainActor
    func testPersonaggioCaricaESiReggeInPiedi() throws {
        let rig = try nuovo()
        let m = rig.applica(0, movimento: .curl)
        dentro(m.pelviY, 91.3, 3.5, "bacino in piedi")
        dentro(m.puntaY, 1.5, 3.5, "pianta a terra in piedi")
        dentro(m.manoY, 92.5, 3.5, "mano lungo il fianco")
        XCTAssertLessThanOrEqual(m.ancoraDx, 5.0, "presa del bersaglio (ancora)")
    }

    @MainActor
    func testPushUpManiBasseEPuntaAlSuolo() throws {
        let rig = try nuovo()
        let m = rig.applica(0.5, movimento: .pushUp)
        dentro(m.manoY, 16.7, 3.5, "mano bassa")
        dentro(m.puntaY, 8.6, 3.5, "avampiede dritto")
        dentro(m.pelviY, 41.1, 3.5, "bacino della flessione")
        XCTAssertLessThanOrEqual(m.ancoraDx, 7.0, "mano vicino al bersaglio")
    }

    @MainActor
    func testPullUpSaleConLaSbarra() throws {
        let rig = try nuovo()
        let sotto = rig.applica(0, movimento: .pullUp)
        dentro(sotto.manoY, 200.1, 3.5, "mano alla sbarra, appeso")
        XCTAssertLessThanOrEqual(sotto.ancoraDx, 5.0, "presa della sbarra")
        let su = rig.applica(2.5, movimento: .pullUp)
        dentro(su.manoY, 212.1, 4.0, "mano resta alla sbarra in alto")
        dentro(su.puntaY, 57.0, 4.0, "piedi che salgono")
        dentro(su.pelviY, 140.7, 4.0, "bacino che sale")
    }

    @MainActor
    func testSquatScendeSenzaAffondare() throws {
        let rig = try nuovo()
        let m = rig.applica(1.6, movimento: .squat)
        dentro(m.pelviY, 62.0, 4.0, "bacino basso dello squat")
        dentro(m.puntaY, -3.1, 4.0, "pianta che resta vicina al suolo")
        dentro(m.manoY, 116.2, 4.0, "mani avanti per bilanciarsi")
    }

    @MainActor
    func testCurlAlzaLaMano() throws {
        let rig = try nuovo()
        let giu = rig.applica(0, movimento: .curl)
        dentro(giu.manoY, 92.5, 3.5, "mano bassa del curl")
        let su = rig.applica(1.4, movimento: .curl)
        dentro(su.manoY, 126.5, 4.0, "mano alta del curl")
        XCTAssertLessThanOrEqual(su.ancoraDx, 3.5, "presa")
    }

    @MainActor
    func testRowTiraIlGomitoIndietro() throws {
        let rig = try nuovo()
        let m = rig.applica(1.2, movimento: .row)
        dentro(m.manoY, 143.9, 4.0, "mano alta del rematore")
        XCTAssertLessThanOrEqual(m.ancoraDx, 3.0, "presa")
    }

    @MainActor
    func testBenchManoScendeSulPettorale() throws {
        let rig = try nuovo()
        let m = rig.applica(2.0, movimento: .bench)
        dentro(m.manoY, 68.1, 4.0, "mano bassa della panca")
        dentro(m.manoZ, -11.8, 4.0, "mano sopra il petto")
        dentro(m.pelviY, 39.5, 4.0, "bacino disteso sulla panca")
    }

    @MainActor
    func testLateralRaiseBraccioOrizzontale() throws {
        let rig = try nuovo()
        let m = rig.applica(1.1, movimento: .lateralRaise)
        dentro(m.manoY, 92.8, 3.5, "mano dell'alzata")
        XCTAssertLessThanOrEqual(m.ancoraDx, 4.5, "presa")
    }

    @MainActor
    func testLungePassoAvanti() throws {
        let rig = try nuovo()
        let m = rig.applica(1.4, movimento: .lunge)
        dentro(m.manoY, 79.0, 4.0, "mani basse nell'affondo")
        dentro(m.puntaY, -1.7, 4.0, "passo che resta a terra")
    }

    @MainActor
    func testPlankAvambraccioETacco() throws {
        let rig = try nuovo()
        let m = rig.applica(0, movimento: .plank)
        dentro(m.manoY, 13.8, 4.0, "mano a terra")
        dentro(m.manoZ, 61.1, 4.0, "mano avanti")
        dentro(m.puntaY, 7.1, 4.0, "punta in punta di piedi")
        XCTAssertLessThanOrEqual(m.ancoraDx, 10.0, "presa del plank")
    }

    @MainActor
    func testCustomBraccioSopraLaTesta() throws {
        let rig = try nuovo()
        let m = rig.applica(0.3, movimento: .custom)
        dentro(m.manoY, 186.2, 5.0, "mano sopra la testa")
        XCTAssertLessThan(m.pelviY, 100.0, "resta in piedi")
    }

    @MainActor
    func testStopRiportaARiposo() throws {
        let rig = try nuovo()
        _ = rig.applica(1.4, movimento: .curl)
        rig.stop()
        XCTAssertEqual(rig.misure, MisureContatto(), "misure azzerate dopo lo stop")
    }
}
