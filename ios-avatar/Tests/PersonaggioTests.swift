import XCTest
@preconcurrency import SceneKit
import UIKit
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
        // t=0 è la FINE del ciclo (mano alta della chiaveultima prima del
        // wrap): la posa "in piedi mano bassa" va campionata a metà della
        // prima discesa, t=0.75 (verificato con la simulazione numerica)
        let m = rig.applica(0.75, movimento: .curl)
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
        // t=0 = mano alta (fine ciclo, wrap sull'ultima chiave): la discesa
        // completa si vede a t=0.75 (simulazione: manoY 93.4 ~ 92.5)
        let giu = rig.applica(0.75, movimento: .curl)
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

    // MARK: 1.1.10 - volto, proporzioni, auto-camera

    /// immagine di prova a tinta unita per il volto
    @MainActor
    private func immagineProva() -> UIImage {
        let formato = UIGraphicsImageRendererFormat()
        formato.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: formato).image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @MainActor
    func testVoltoFotoSullaTestaDelPersonaggio() throws {
        // senza foto: nessun piano del volto
        let base = try nuovo()
        XCTAssertNil(base.scene.rootNode.childNode(withName: "voltoFoto", recursively: true),
                     "senza foto non deve esserci il piano del volto")

        guard PersonaggioRig.disponibile,
              let rig = PersonaggioRig(measurements: Measurements(), facePhoto: immagineProva()) else {
            XCTFail("rig con volto non creato. CrashLog: " + CrashLog.tail(6))
            return
        }
        guard let nodoVolto = rig.scene.rootNode.childNode(withName: "voltoFoto", recursively: true) else {
            XCTFail("il piano del volto deve essere figlio della testa")
            return
        }
        let piano = nodoVolto.geometry as? SCNPlane
        XCTAssertNotNil(piano, "la geometria del volto deve essere un piano")
        if let piano {
            let lato = Double(piano.width)
            // altezzaTesta (osso head -> sommita') ~0.21 nel glTF, lato = 62%
            dentro(lato, 0.13, 0.06, "lato del volto (unita' glTF)")
            XCTAssertFalse(nodoVolto.geometry?.firstMaterial?.isDoubleSided ?? true,
                           "il volto non deve vedersi da dietro la testa")
            // il volto sta SUL viso: il piano e' ben sopra l'attacco del collo
            // (il nodo head nasce al collo; prima del fix y era ~0.02)
            XCTAssertGreaterThan(Double(nodoVolto.position.y), 0.04,
                                 "il volto deve stare sul viso, non sopra il collo")
        }
    }

    @MainActor
    func testProporzioniDellUtenteSulleOssa() throws {
        // misure di default: fattori esattamente 1 (il driver non cambia)
        let base = try nuovo()
        XCTAssertEqual(base.fattoreBraccia, 1.0, accuracy: 1e-9, "braccia di default = glTF")
        XCTAssertEqual(base.fattoreGambe, 1.0, accuracy: 1e-9, "gambe di default = glTF")

        // braccia lunghe: clamp a 1.15 (oltre si deforma la skinning)
        var lunghe = Measurements()
        lunghe.armCm = 75
        guard let rigLunghe = PersonaggioRig(measurements: lunghe) else {
            XCTFail("rig braccia lunghe non creato. CrashLog: " + CrashLog.tail(6))
            return
        }
        XCTAssertEqual(rigLunghe.fattoreBraccia, 1.15, accuracy: 0.01, "braccia 75 cm saturano il clamp")
        // gambe lunghe: 100 cm -> ~1.087 (sotto il clamp)
        var alte = Measurements()
        alte.legCm = 100
        guard let rigAlte = PersonaggioRig(measurements: alte) else {
            XCTFail("rig gambe lunghe non creato. CrashLog: " + CrashLog.tail(6))
            return
        }
        XCTAssertEqual(rigAlte.fattoreGambe, 1.08696, accuracy: 0.01, "gambe 100 cm scalano ~1.087")

        // le proporzioni si vedono nel guidato senza spaccare la posa: col
        // braccio lungo cresce ANCHE il bersaglio del manichino (quasi 21%),
        // il personaggio e' clampato a 1.15: la mano alta del curl resta
        // nella stessa banda (raggiunge il suo bersaglio, un po' piu' corta
        // del manichino iper-dotato). Non si puo' pretendere la monotonia.
        let manoBase = base.applica(0, movimento: .curl).manoY
        let manoLunghe = rigLunghe.applica(0, movimento: .curl).manoY
        dentro(manoLunghe, manoBase, 8.0, "mano alta del curl con braccia lunghe")
    }

    @MainActor
    func testAutoCameraInquadraLEsercizio() throws {
        let rig = try nuovo()
        // in piedi (curl): camera vicina come da progetto
        rig.inquadra(.curl)
        let distanzaCurl = rig.distanzaCamera
        let quotaCurl = rig.quotaCamera
        XCTAssertGreaterThan(distanzaCurl, 150, "la camera non deve finire dentro il personaggio")
        XCTAssertLessThan(distanzaCurl, 260, "in piedi la camera non deve arretrare oltre")
        dentro(quotaCurl, 65, 30, "quota del centro inquadrato in piedi")

        // trazioni: la mano sale alla sbarra (~212 cm): la camera arretra e alza il centro
        rig.inquadra(.pullUp)
        XCTAssertGreaterThan(rig.distanzaCamera, distanzaCurl + 60,
                             "nelle trazioni la camera deve arretrare rispetto al curl")
        XCTAssertGreaterThan(rig.quotaCamera, quotaCurl, "nelle trazioni il centro inquadrato sale")

        // l'inquadratura verticale copre l'estensione del corpo
        let mezzaFov = 23.0 * Double.pi / 180
        let copertura = rig.distanzaCamera * tan(mezzaFov)
        XCTAssertGreaterThanOrEqual(copertura, rig.estensioneYCamera / 2,
                                    "mezzo campo visivo (\(copertura) cm) deve coprire metà estensione (\(rig.estensioneYCamera / 2) cm)")

        // plank: il corpo si distende verso la camera (mano avanti ~61 cm),
        // la camera arretra un po' rispetto al curl
        rig.inquadra(.plank)
        XCTAssertGreaterThan(rig.distanzaCamera, distanzaCurl + 5,
                             "nel plank la camera deve arretrare per la mano avanti")

        // stop: camera di nuovo alla posa in piedi (piu' lontana, come da progetto)
        rig.stop()
        XCTAssertGreaterThan(rig.distanzaCamera, 300, "dopo lo stop la camera torna alla posa in piedi")
    }
}
