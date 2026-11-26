import Foundation
import SwiftUI
@preconcurrency import GLTFSceneKit
@preconcurrency import SceneKit
import UIKit

// MARK: - Personaggio CC0 (Quaternius Superhero Male) guidato dalle pose del rig
//
// FASE 2 dello studio 3D (docs/STUDIO-AVATAR3D.md): il personaggio rigged CC0
// prende il posto del manichino nell'Home. Le pose calibrate di AvatarRig
// guidano lo scheletro glTF con lo stesso driver verificato frame per frame
// nella simulazione Python (distanza mano-bersaglio: max ~8 cm dichiarato su
// tutti gli esercizi, riprodotta nei test unitari). Onestà dichiarata: volto
// foto dell'utente, misure modulate sulle ossa, auto-camera e bagliore
// muscolare in Metal NON sono ancora implementati su questo personaggio.

/// Minime misure di contatto dell'ultima posa applicata, in cm dal suolo del
/// personaggio: servono ai test per verificare il driver senza passare dal
/// rendering (SceneKit).
struct MisureContatto: Equatable, Sendable {
    /// Posizione della mano destra (y dal suolo, z verso la camera).
    var manoY: Double = 0
    var manoZ: Double = 0
    /// Distanza mano destra-bersaglio dell'IK (cm): 0 = presa perfetta.
    var ancoraDx: Double = 0
    /// Altezza del bacino dal suolo (cm).
    var pelviY: Double = 0
    /// Posizione della punta del piede destro (y dal suolo, z).
    var puntaY: Double = 0
    var puntaZ: Double = 0
}

final class PersonaggioRig {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// Il personaggio è nel bundle solo dopo lo step della CI che lo scarica:
    /// senza quei file la Home ricade sul manichino, senza crash.
    static var disponibile: Bool {
        Bundle.main.url(forResource: "Superhero_Male_FullBody", withExtension: "gltf") != nil
    }

    // scheletro guidato
    private var nodi: [String: SCNNode] = [:]
    private var restLocale: [String: simd_double4x4] = [:]
    /// nodi del glTF dal root in giù, in ordine di visita (padre prima del figlio)
    private var catena: [(nome: String, padre: String?)] = []

    // rest world del bacino e del suo padre (fisso: sopra il bacino non si guida nulla)
    private var restPelvi = SIMD3<Double>.zero
    private var restPelviPadre = matrix_identity_double4x4

    // geometrica dell'uomo (stesse formule di AvatarRig, in cm)
    private let bodyH: Double
    private let scala: Double
    private let thighLen: Double
    private let shinLen: Double
    private let footH: Double
    private let torsoH: Double
    private let upperLen: Double
    private let foreLen: Double
    private let gambaManichino: Double
    // geometria del personaggio (il glTF è in metri: "unita" = cm per unità)
    private let unita: Double
    private let piantaY: Double
    private let L1: Double
    private let L2: Double
    private let cosciaChar: Double
    private let altezzaChar: Double

    private var manubri: [SCNNode] = []
    private var sbarraFissa: SCNNode?
    private var highlighted: [SCNMaterial] = []
    private var demoTask: Task<Void, Never>?
    private(set) var misure = MisureContatto()
    private let glow = UIColor(hex: 0x00E5FF)

    /// Esito del driver per una posa: delta di rotazione locale per osso,
    /// mondo FK risultante e bersagli (unità glTF e cm).
    private struct EsitoGuida {
        var delta: [String: (dx: Double, dz: Double)]
        var mondo: [String: simd_double4x4]
        var bersaglioPelvi: SIMD3<Double>
        /// bersaglio della mano destra (y dal suolo, z) in cm, se l'IK è partito
        var ancora: (y: Double, z: Double)?
    }

    init?(measurements m: Measurements) {
        guard let url = Bundle.main.url(forResource: "Superhero_Male_FullBody", withExtension: "gltf") else {
            return nil
        }
        let scenaCaricata: SCNScene
        do {
            let sorgente = try GLTFSceneSource(url: url, options: nil)
            scenaCaricata = try sorgente.scene(options: nil)
        } catch {
            CrashLog.append("personaggio non caricabile: \(error)")
            return nil
        }

        // geometria dell'uomo 1:1 da AvatarRig
        bodyH = max(m.heightCm, 120)
        scala = bodyH / 175
        let legLen = min(max(m.legCm, bodyH * 0.30), bodyH * 0.58)
        thighLen = max(legLen * 0.55, bodyH * 0.15)
        shinLen = max(legLen * 0.45, bodyH * 0.12)
        footH = max(bodyH * 0.04 + Double(m.shoeSize - 36) * 0.06, 2)
        let armLen = min(max(m.armCm, bodyH * 0.35), bodyH * 0.60) * 1.08
        upperLen = armLen * 0.55
        foreLen = armLen * 0.45
        torsoH = max((thighLen + shinLen) * 0.62, bodyH * 0.22)
        gambaManichino = thighLen + shinLen

        // snapshot dello scheletro a riposo in un helper statico: le funzioni
        // locali (visita, posRest) non devono catturare self prima che tutte
        // le proprieta' dell'init siano inizializzate (errore Swift: 'self'
        // used in method call before all stored properties are initialized)
        guard let scheletro = PersonaggioRig.caricaScheletroDa(scenaCaricata) else {
            return nil
        }
        nodi = scheletro.nodi
        restLocale = scheletro.restLocale
        catena = scheletro.catena
        restPelvi = scheletro.restPelvi
        restPelviPadre = scheletro.restPelviPadre
        piantaY = scheletro.piantaY
        altezzaChar = scheletro.altezzaChar
        unita = bodyH / altezzaChar
        L1 = scheletro.braccio * unita
        L2 = (scheletro.avambraccio + 0.05) * unita
        cosciaChar = (scheletro.coscia + scheletro.stinco) * unita

        scenaCaricata.background.contents = UIColor.clear
        scene.rootNode.addChildNode(scenaCaricata.rootNode)
        aggiungiLuciECamera()
    }

    /// Scheletro letto dal glTF a riposo: distanze in unita' glTF (non cm).
    private struct ScheletroLetto {
        var nodi: [String: SCNNode]
        var restLocale: [String: simd_double4x4]
        var catena: [(nome: String, padre: String?)]
        var restPelvi: SIMD3<Double>
        var restPelviPadre: simd_double4x4
        var piantaY: Double
        var altezzaChar: Double
        var braccio: Double
        var avambraccio: Double
        var coscia: Double
        var stinco: Double
    }

    /// Percorre il glTF e misura lo scheletro in posa di riposo (bind pose).
    /// Statico perche' le funzioni locali visitano proprieta' della classe e
    /// in init catturerebbero self non ancora inizializzato.
    private static func caricaScheletroDa(_ scena: SCNScene) -> ScheletroLetto? {
        var nodi: [String: SCNNode] = [:]
        var restLocale: [String: simd_double4x4] = [:]
        var catena: [(nome: String, padre: String?)] = []
        var minimoY = Double.greatestFiniteMagnitude
        var massimoY = -Double.greatestFiniteMagnitude
        func visita(_ nodo: SCNNode, padre: String?) {
            let nome = nodo.name ?? "_\(catena.count)"
            nodi[nome] = nodo
            restLocale[nome] = PersonaggioRig.d4x4(nodo.simdTransform)
            catena.append((nome, padre))
            if nodo.geometry != nil {
                // angoli del box locale del nodo: trasformati in mondo danno
                // l'altezza del personaggio in posa di riposo (bind pose)
                let (lmin, lmax) = nodo.boundingBox
                let mat = PersonaggioRig.d4x4(nodo.simdWorldTransform)
                for x in [Double(lmin.x), Double(lmax.x)] {
                    for y in [Double(lmin.y), Double(lmax.y)] {
                        for z in [Double(lmin.z), Double(lmax.z)] {
                            let wy = (mat * SIMD4<Double>(x, y, z, 1)).y
                            minimoY = min(minimoY, wy)
                            massimoY = max(massimoY, wy)
                        }
                    }
                }
            }
            for figlio in nodo.childNodes {
                visita(figlio, padre: nome)
            }
        }
        visita(scena.rootNode, padre: nil)

        guard nodi["pelvis"] != nil, nodi["upperarm_r"] != nil, nodi["upperarm_l"] != nil,
              nodi["hand_r"] != nil, nodi["hand_l"] != nil, nodi["ball_r"] != nil else {
            CrashLog.append("scheletro del personaggio non trovato nel file glTF")
            return nil
        }
        guard minimoY < massimoY, massimoY > 0.8, massimoY < 3.0 else {
            CrashLog.append("personaggio senza geometria visibile o scala inattesa")
            return nil
        }
        func posRest(_ nome: String) -> SIMD3<Double> {
            guard let nodo = nodi[nome] else { return .zero }
            let m = PersonaggioRig.d4x4(nodo.simdWorldTransform)
            return SIMD3<Double>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        let restPelvi = posRest("pelvis")
        var restPelviPadre = matrix_identity_double4x4
        if let padre = nodi["pelvis"]?.parent {
            restPelviPadre = PersonaggioRig.d4x4(padre.simdWorldTransform)
        }
        return ScheletroLetto(
            nodi: nodi,
            restLocale: restLocale,
            catena: catena,
            restPelvi: restPelvi,
            restPelviPadre: restPelviPadre,
            piantaY: minimoY,
            altezzaChar: massimoY - minimoY,
            braccio: simd_distance(posRest("upperarm_l"), posRest("lowerarm_l")),
            avambraccio: simd_distance(posRest("lowerarm_l"), posRest("hand_l")),
            coscia: simd_distance(posRest("thigh_l"), posRest("calf_l")),
            stinco: simd_distance(posRest("calf_l"), posRest("foot_l"))
        )
    }

    // MARK: matematica (port 1:1 della simulazione Python verificata)

    private func rotX4(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private func rotZ4(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(columns: (
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private static func d4x4(_ m: simd_float4x4) -> simd_double4x4 {
        func col(_ c: simd_float4) -> SIMD4<Double> {
            SIMD4<Double>(Double(c.x), Double(c.y), Double(c.z), Double(c.w))
        }
        return simd_double4x4(columns: (col(m.columns.0), col(m.columns.1), col(m.columns.2), col(m.columns.3)))
    }

    private static func f4x4(_ m: simd_double4x4) -> simd_float4x4 {
        func col(_ c: SIMD4<Double>) -> simd_float4 {
            simd_float4(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
        }
        return simd_float4x4(columns: (col(m.columns.0), col(m.columns.1), col(m.columns.2), col(m.columns.3)))
    }

    private static func rot3Di(_ m: simd_double4x4) -> simd_double3x3 {
        simd_double3x3(columns: (
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        ))
    }

    /// FK manuale: rest locale + delta di rotazione POST-moltiplicati, con la
    /// correzione della traslazione del bacino nel frame del suo padre (fisso).
    private func fk(_ delta: [String: (dx: Double, dz: Double)], bersaglioPelvi: SIMD3<Double>?) -> [String: simd_double4x4] {
        var mondo: [String: simd_double4x4] = [:]
        for voce in catena {
            var locale = restLocale[voce.nome] ?? matrix_identity_double4x4
            if let d = delta[voce.nome] {
                if d.dx != 0 { locale = locale * rotX4(d.dx) }
                if d.dz != 0 { locale = locale * rotZ4(d.dz) }
            }
            if voce.nome == "pelvis", let bersaglio = bersaglioPelvi {
                // il bacino è montato sotto nodi ruotati (armature −90°): lo
                // spostamento verso il bersaglio va ruotato nel frame del padre
                let spostamento = PersonaggioRig.rot3Di(restPelviPadre).transpose * (bersaglio - restPelvi)
                locale.columns.3 += SIMD4<Double>(spostamento.x, spostamento.y, spostamento.z, 0)
            }
            let mondoPadre = voce.padre.flatMap { mondo[$0] } ?? matrix_identity_double4x4
            mondo[voce.nome] = mondoPadre * locale
        }
        return mondo
    }

    /// Posizione mondo di un figlio non guidato (mano, punta del piede):
    /// mondo del padre guidato * rest locale del figlio.
    private func figlio(_ mondo: [String: simd_double4x4], padre: String, figlio nome: String) -> SIMD3<Double> {
        let base = mondo[padre] ?? matrix_identity_double4x4
        let m = base * (restLocale[nome] ?? matrix_identity_double4x4)
        return SIMD3<Double>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Altezza del bacino dell'uomo per una posa (cm): 1:1 da AvatarRig.
    private func altezzaPelvi(_ p: Pose) -> Double {
        if let y = p.pelvisY {
            return Double(y) * scala
        }
        func sotto(_ f: Double, _ k: Double) -> Double {
            3.5 + thighLen * cos(f) + shinLen * cos(f - k)
        }
        let fL = Double(p.hipL ?? p.hip)
        let fR = Double(p.hipR ?? p.hip)
        let gL = Double(p.kneeL ?? p.knee)
        let gR = Double(p.kneeR ?? p.knee)
        return min(sotto(fL, gL), sotto(fR, gR)) + footH
    }

    private func spalla2D(_ p: Pose) -> (y: Double, z: Double) {
        func ruota(_ a: Double, y: Double, z: Double) -> (Double, Double) {
            (y * cos(a) - z * sin(a), y * sin(a) + z * cos(a))
        }
        let o1 = ruota(Double(p.bodyPitch), y: 4.5, z: 0)
        let o2 = ruota(Double(p.bodyPitch + p.torsoPitch), y: torsoH - 3.2, z: 0)
        return (
            altezzaPelvi(p) - Double(p.pelvisDrop) + Double(p.rootLift) + o1.0 + o2.0,
            o1.1 + o2.1
        )
    }

    private func mano2DManichino(_ p: Pose) -> (y: Double, z: Double) {
        let sp = spalla2D(p)
        let ts = Double(p.bodyPitch + p.torsoPitch - p.shoulderX)
        let tg = ts - Double(p.elbow)
        let gomitoY = sp.y - upperLen * cos(ts)
        let gomitoZ = sp.z - upperLen * sin(ts)
        return (y: gomitoY - foreLen * cos(tg), z: gomitoZ - foreLen * sin(tg))
    }

    /// Risolve il sistema 3x3 con eliminazione di Gauss (la stessa della sim).
    private func gauss(_ A: [[Double]], _ b: [Double]) -> [Double] {
        var m = A
        var v = b
        var x = [0.0, 0.0, 0.0]
        for i in 0..<3 {
            var piv = i
            for r in (i + 1)..<3 where abs(m[r][i]) > abs(m[piv][i]) {
                piv = r
            }
            if abs(m[piv][i]) < 1e-9 { continue }
            m.swapAt(i, piv)
            v.swapAt(i, piv)
            for r in (i + 1)..<3 {
                let f = m[r][i] / m[i][i]
                for c in i..<3 { m[r][c] -= f * m[i][c] }
                v[r] -= f * v[i]
            }
        }
        for i in [2, 1, 0] where abs(m[i][i]) > 1e-9 {
            var s = v[i]
            for j in (i + 1)..<3 { s -= m[i][j] * x[j] }
            x[i] = s / m[i][i]
        }
        return x
    }

    // MARK: driver

    /// Dai valori chiave della posa ai delta di rotazione locale del personaggio.
    private func guida(_ p: Pose, movimento: MovementType) -> EsitoGuida {
        let elbow = Double(p.elbow)
        let shoulderZ = Double(p.shoulderZ)
        let abd = Double.pi / 2 - abs(shoulderZ)

        // quota del bacino (cm dal suolo) -> bersaglio in unità glTF
        var pycm: Double
        if let py = p.pelvisY {
            pycm = Double(py) * scala - Double(p.pelvisDrop) + Double(p.rootLift)
        } else {
            let riposo = altezzaPelvi(Pose())
            let ora = altezzaPelvi(p)
            let drop = max(0, riposo - ora)
            pycm = (restPelvi.y - piantaY) * unita - drop * (cosciaChar / gambaManichino)
        }
        let bersaglioPelvi = SIMD3<Double>(restPelvi.x, piantaY + pycm / unita, restPelvi.z)

        var d: [String: (dx: Double, dz: Double)] = [:]
        d["pelvis"] = (Double(p.bodyPitch), 0)
        let terzo = Double(p.torsoPitch) / 3
        d["spine_01"] = (terzo, 0)
        d["spine_02"] = (terzo, 0)
        d["spine_03"] = (terzo, 0)
        // nota: la mappa l/r è incrociata per le gambe, come verificato nella
        // simulazione (le pose studio mettono il passo che avanza in hipL)
        d["thigh_r"] = (-Double(p.hipL ?? p.hip), 0)
        d["thigh_l"] = (-Double(p.hipR ?? p.hip), 0)
        d["calf_r"] = (Double(p.kneeL ?? p.knee), 0)
        d["calf_l"] = (Double(p.kneeR ?? p.knee), 0)
        d["upperarm_l"] = (-Double(p.shoulderX), -abd)
        d["upperarm_r"] = (-Double(p.shoulderX), abd)
        d["lowerarm_l"] = (elbow, 0)
        d["lowerarm_r"] = (elbow, 0)
        // piede piatto nelle pose a terra (coppia V4): compensa corpo+coscia+stinco.
        // Nelle trazioni no: i piedi penzolano (foot = 0 nella simulazione)
        if movimento == .pullUp {
            d["foot_l"] = (0, 0)
            d["foot_r"] = (0, 0)
        } else {
            let gambaL = (d["thigh_l"]?.dx ?? 0) + (d["calf_l"]?.dx ?? 0)
            let gambaR = (d["thigh_r"]?.dx ?? 0) + (d["calf_r"]?.dx ?? 0)
            d["foot_l"] = (-(Double(p.bodyPitch) + gambaL), 0)
            d["foot_r"] = (-(Double(p.bodyPitch) + gambaR), 0)
        }

        var mondo = fk(d, bersaglioPelvi: bersaglioPelvi)
        var ancora: (y: Double, z: Double)? = nil

        // braccia: IK numerico a 3 gradi (abduzione, gomito, piano saggittale)
        // verso il bersaglio = spalla del personaggio + direzione mano manichino
        // scalata sulla portata del personaggio
        let spM = spalla2D(p)
        let manoM = mano2DManichino(p)
        let vx = manoM.y - spM.y
        let vz = manoM.z - spM.z
        let distM = (vx * vx + vz * vz).squareRoot()
        if distM > 0.5 {
            let unito = (vx / distM, vz / distM)
            let rho = (L1 + L2) / (upperLen + foreLen)
            let raggio = min(distM * rho, (L1 + L2) * 0.94)
            if let spm = mondo["upperarm_r"] {
                let spalla = SIMD3<Double>(spm.columns.3.x, spm.columns.3.y, spm.columns.3.z)
                let bersY = (spalla.y - piantaY) * unita + unito.0 * raggio
                let bersZ = spalla.z * unita + unito.1 * raggio
                ancora = (bersY, bersZ)

                func manoDel(_ v: [Double]) -> (y: Double, z: Double) {
                    var dd = d
                    dd["upperarm_l"] = (v[2], -v[0])
                    dd["upperarm_r"] = (v[2], v[0])
                    dd["lowerarm_l"] = (v[1], 0)
                    dd["lowerarm_r"] = (v[1], 0)
                    let w = fk(dd, bersaglioPelvi: bersaglioPelvi)
                    let m = figlio(w, padre: "lowerarm_r", figlio: "hand_r")
                    return ((m.y - piantaY) * unita, m.z * unita)
                }

                // due inizializzazioni: quella analitica e quella che sblocca il
                // ramo negativo dell'abduzione (il percorso sopra-testa)
                let tsman = Double(p.bodyPitch + p.torsoPitch - p.shoulderX)
                let initAnalitica = max(0.05, abd)
                let initAlternativa = min(3.4, Double.pi / 2 - min(abs(tsman) + abs(shoulderZ), Double.pi / 2 + 2.0))
                var iniziali: [Double] = []
                for i in [initAnalitica, initAlternativa] {
                    let arrotondato = (i * 1000).rounded() / 1000
                    if !iniziali.contains(arrotondato) { iniziali.append(arrotondato) }
                }

                var migliore: (r: Double, v: [Double], ea: Double)? = nil
                for iniziale in iniziali {
                    var v = [iniziale, max(0.05, elbow), 0.0]
                    var meglio: (r: Double, v: [Double], ea: Double)? = nil
                    for _ in 0..<12 {
                        let pos = manoDel(v)
                        let ey = bersY - pos.y
                        let ez = bersZ - pos.z
                        let r = (ey * ey + ez * ez).squareRoot()
                        let wa: Double = r < 8.0 ? 0.35 : 0.06
                        let ea = wa * (abd - v[0])
                        if meglio == nil || r < meglio!.r {
                            meglio = (r, v, abs(ea))
                        }
                        if r < 1.5 && abs(ea) < 0.12 { break }
                        let eps = 0.05
                        let p1 = manoDel([v[0] + eps, v[1], v[2]])
                        let p2 = manoDel([v[0], v[1] + eps, v[2]])
                        let p3 = manoDel([v[0], v[1], v[2] + eps])
                        let colonne = [
                            ((p1.y - pos.y) / eps, (p1.z - pos.z) / eps, wa),
                            ((p2.y - pos.y) / eps, (p2.z - pos.z) / eps, 0.0),
                            ((p3.y - pos.y) / eps, (p3.z - pos.z) / eps, 0.0)
                        ]
                        var A = [[Double]](repeating: [0, 0, 0], count: 3)
                        var b = [0.0, 0.0, 0.0]
                        for i in 0..<3 {
                            for j in 0..<3 {
                                A[i][j] = colonne[i].0 * colonne[j].0
                                    + colonne[i].1 * colonne[j].1
                                    + colonne[i].2 * colonne[j].2
                                    + (i == j ? 0.02 : 0)
                            }
                            b[i] = colonne[i].0 * ey + colonne[i].1 * ez + colonne[i].2 * ea
                        }
                        let passo = gauss(A, b)
                        let d0 = min(max(passo[0], -0.7), 0.7)
                        let d1 = min(max(passo[1], -0.7), 0.7)
                        let d2 = min(max(passo[2], -0.7), 0.7)
                        v[0] = min(max(v[0] + d0, -2.30), 3.45)
                        v[1] = min(max(v[1] + d1, -0.10), 3.05)
                        v[2] = min(max(v[2] + d2, -1.30), 1.30)
                    }
                    if let m = meglio {
                        if migliore == nil || (m.r + 0.4 * m.ea) < (migliore!.r + 0.4 * migliore!.ea) {
                            migliore = m
                        }
                    }
                }

                if let v = migliore {
                    d["upperarm_l"] = (v.v[2], -v.v[0])
                    d["upperarm_r"] = (v.v[2], v.v[0])
                    d["lowerarm_l"] = (v.v[1], 0)
                    d["lowerarm_r"] = (v.v[1], 0)
                    mondo = fk(d, bersaglioPelvi: bersaglioPelvi)
                }
            }
        }

        return EsitoGuida(delta: d, mondo: mondo, bersaglioPelvi: bersaglioPelvi, ancora: ancora)
    }

    // MARK: scrittura sui nodi SceneKit

    private func scrivi(_ esito: EsitoGuida) {
        for (nome, del) in esito.delta {
            guard let nodo = nodi[nome], let rest = restLocale[nome] else { continue }
            var locale = rest
            if del.0 != 0 { locale = locale * rotX4(del.0) }
            if del.1 != 0 { locale = locale * rotZ4(del.1) }
            nodo.simdTransform = PersonaggioRig.f4x4(locale)
        }
        // traslazione del bacino verso il bersaglio, nel frame del padre
        if let pelvi = nodi["pelvis"] {
            let spostamento = PersonaggioRig.rot3Di(restPelviPadre).transpose * (esito.bersaglioPelvi - restPelvi)
            var t = PersonaggioRig.d4x4(pelvi.simdTransform)
            t.columns.3 += SIMD4<Double>(spostamento.x, spostamento.y, spostamento.z, 0)
            pelvi.simdTransform = PersonaggioRig.f4x4(t)
        }
    }

    /// Applica la posa al tempo t del movimento e aggiorna le misure di contatto.
    /// Chiamata dal demo task e, in sincrono, dai test.
    @discardableResult
    func applica(_ t: Double, movimento: MovementType) -> MisureContatto {
        let keys = Keyframes.forMovement(movimento)
        guard !keys.isEmpty else { return misure }
        let total = max(keys.reduce(0.0) { $0 + $1.duration }, 0.001)
        let pose = AvatarRig.posaA(CGFloat(t), keys: keys, total: CGFloat(total))
        let esito = guida(pose, movimento: movimento)
        scrivi(esito)

        var nuova = MisureContatto()
        let mano = figlio(esito.mondo, padre: "lowerarm_r", figlio: "hand_r")
        let punta = figlio(esito.mondo, padre: "foot_r", figlio: "ball_r")
        nuova.manoY = (mano.y - piantaY) * unita
        nuova.manoZ = mano.z * unita
        nuova.puntaY = (punta.y - piantaY) * unita
        nuova.puntaZ = punta.z * unita
        nuova.pelviY = esito.bersaglioPelvi.y * unita - piantaY * unita
        if let ancora = esito.ancora {
            let dy = nuova.manoY - ancora.y
            let dz = nuova.manoZ - ancora.z
            nuova.ancoraDx = (dy * dy + dz * dz).squareRoot()
        }
        misure = nuova
        return nuova
    }

    // MARK: API del rig (stessa firma di AvatarRig)

    func play(_ movement: MovementType, muscles: [MuscleGroup]) {
        stop()
        CrashLog.append("demo avviata sul personaggio: \(movement.rawValue)")
        setHighlight(muscles)
        _ = applica(0, movimento: movement)
        usaAttrezzi(movement)
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            let inizio = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self else { return }
                let t = Double(ProcessInfo.processInfo.systemUptime - inizio)
                self.applica(t, movimento: movement)
                try? await Task.sleep(for: .seconds(0.033))
            }
        }
    }

    func stop() {
        demoTask?.cancel()
        demoTask = nil
        // nodi a riposo
        for (nome, nodo) in nodi {
            if let rest = restLocale[nome] {
                nodo.simdTransform = PersonaggioRig.f4x4(rest)
            }
        }
        clearHighlight()
        for m in manubri { m.removeFromParentNode() }
        manubri.removeAll()
        sbarraFissa?.removeFromParentNode()
        sbarraFissa = nil
        misure = MisureContatto()
    }

    func setHighlight(_ groups: [MuscleGroup]) {
        clearHighlight()
        guard !groups.isEmpty else { return }
        // il personaggio è una mesh unica skinned: il gruppo muscolare si
        // segnala con un bagliore pulsante sull'intero corpo. Onesto: la mappa
        // muscolo->vertici non c'è ancora (il manichino la aveva per nodi).
        for (_, nodo) in nodi {
            guard let materiali = nodo.geometry?.materials, !materiali.isEmpty else { continue }
            for materiale in materiali {
                materiale.emission.contents = glow
                highlighted.append(materiale)
            }
        }
        guard !highlighted.isEmpty else { return }
        let materials = highlighted
        let pulsazione = SCNAction.customAction(duration: 1.0) { [weak self] _, t in
            guard let self else { return }
            let alpha = 0.30 + 0.30 * (0.5 + 0.5 * sin(t * 2 * .pi))
            for material in materials {
                material.emission.contents = self.glow.withAlphaComponent(CGFloat(alpha))
            }
        }
        scene.rootNode.runAction(SCNAction.repeatForever(pulsazione), forKey: "pulse")
    }

    private func clearHighlight() {
        for materiale in highlighted {
            materiale.emission.contents = UIColor.black
        }
        highlighted.removeAll()
        scene.rootNode.removeAction(forKey: "pulse")
    }

    // MARK: attrezzi (in unità glTF: le misure del rig dell'app sono in cm)

    private func usaAttrezzi(_ movement: MovementType) {
        let u = 1.0 / unita
        if movement == .pullUp {
            // sbarra alla quota delle mani della fase appesa (presa dell'ancora)
            let sorgente = guida(AvatarRig.posaA(0,
                                                 keys: Keyframes.forMovement(movement),
                                                 total: CGFloat(max(Keyframes.forMovement(movement).reduce(0.0) { $0 + $1.duration }, 0.001))),
                                                 movimento: movement)
            let mano = figlio(sorgente.mondo, padre: "lowerarm_r", figlio: "hand_r")
            let materiale = SCNMaterial()
            materiale.diffuse.contents = UIColor(hex: 0x2A2F36)
            materiale.emission.contents = glow.withAlphaComponent(0.6)
            let barra = SCNNode(geometry: SCNCylinder(radius: 1.4 * u, height: 1.30))
            barra.geometry?.firstMaterial = materiale
            barra.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
            barra.position = SCNVector3(0, Float(mano.y), Float(mano.z))
            scene.rootNode.addChildNode(barra)
            sbarraFissa = barra
        }
        if movement == .curl || movement == .row || movement == .lateralRaise || movement == .custom {
            for nome in ["hand_l", "hand_r"] {
                guard let mano = nodi[nome] else { continue }
                let gruppo = SCNNode()
                let materialeFerro = SCNMaterial()
                materialeFerro.diffuse.contents = UIColor(hex: 0x364052)
                materialeFerro.specular.contents = UIColor.white.withAlphaComponent(0.2)
                let manico = SCNNode(geometry: SCNCapsule(capRadius: 1.2 * u, height: 7 * u))
                manico.geometry?.firstMaterial = materialeFerro
                manico.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
                gruppo.addChildNode(manico)
                for lato in [-1.0, 1.0] {
                    let testa = SCNNode(geometry: SCNSphere(radius: 3.0 * u))
                    testa.geometry?.firstMaterial = materialeFerro
                    testa.scale = SCNVector3(0.55, 1, 1)
                    testa.position = SCNVector3(Float(lato * 3.9 * u), 0, 0)
                    gruppo.addChildNode(testa)
                }
                mano.addChildNode(gruppo)
                manubri.append(gruppo)
            }
        }
    }

    // MARK: luci e camera

    private func aggiungiLuciECamera() {
        let h = altezzaChar

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.position = SCNVector3(Float(h * 0.9), Float(h * 1.7), Float(h * 1.4))
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = glow
        rim.light?.intensity = 650
        rim.position = SCNVector3(Float(-h * 0.8), Float(h * 0.9), Float(-h * 1.6))
        scene.rootNode.addChildNode(rim)

        let camera = SCNCamera()
        camera.fieldOfView = 46
        camera.zNear = 0.02
        camera.zFar = h * 20
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, Float(h * 0.58), Float(h * 2.2))
        let bersaglio = SCNNode()
        bersaglio.position = SCNVector3(0, Float(h * 0.52), 0)
        cameraNode.constraints = [SCNLookAtConstraint(target: bersaglio)]
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(bersaglio)
    }
}

// MARK: - Vista SwiftUI del personaggio (come AvatarSceneView per il manichino)

struct PersonaggioSceneView: UIViewRepresentable {
    var measurements: Measurements
    var demoMovement: MovementType?
    var demoMuscles: [MuscleGroup]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        if let rig = PersonaggioRig(measurements: measurements) {
            context.coordinator.rig = rig
            context.coordinator.lastFirma = "\(measurements)"
            view.scene = rig.scene
            view.pointOfView = rig.cameraNode
            if let movement = demoMovement {
                rig.play(movement, muscles: demoMuscles)
                context.coordinator.lastMovement = movement
                context.coordinator.lastMuscles = demoMuscles
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        let firma = "\(measurements)"
        if firma != c.lastFirma {
            if let rig = PersonaggioRig(measurements: measurements) {
                c.rig = rig
                uiView.scene = rig.scene
                uiView.pointOfView = rig.cameraNode
                c.lastFirma = firma
                if let movement = demoMovement {
                    rig.play(movement, muscles: demoMuscles)
                }
                c.lastMovement = demoMovement
                c.lastMuscles = demoMuscles
            }
            return
        }
        if demoMovement != c.lastMovement {
            if let movement = demoMovement {
                c.rig?.play(movement, muscles: demoMuscles)
            } else {
                c.rig?.stop()
            }
            c.lastMovement = demoMovement
            c.lastMuscles = demoMuscles
        } else if demoMuscles != c.lastMuscles {
            c.rig?.setHighlight(demoMuscles)
            c.lastMuscles = demoMuscles
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var rig: PersonaggioRig?
        var lastFirma = ""
        var lastMovement: MovementType?
        var lastMuscles: [MuscleGroup] = []
    }
}
