import Foundation
import UIKit
@preconcurrency import SceneKit

// MARK: - Posa

/// I numeri delle pose vengono da uno studio fatto frame per frame su un
/// renderer di riferimento (fogli di contatto verificati: mani a terra,
/// punte dei piedi a terra, sbarra in mano, schiena sulla panca).
struct Pose: Equatable {
    var bodyPitch: CGFloat = 0
    var rootLift: CGFloat = 0
    var torsoPitch: CGFloat = 0
    var pelvisDrop: CGFloat = 0
    var shoulderX: CGFloat = 0
    var shoulderZ: CGFloat = 0
    var elbow: CGFloat = 0
    var hip: CGFloat = 0
    var knee: CGFloat = 0
    // V3 (studio del rig): gambe indipendenti e altezza esplicita del bacino.
    var pelvisY: CGFloat? = nil
    var hipL: CGFloat? = nil
    var hipR: CGFloat? = nil
    var kneeL: CGFloat? = nil
    var kneeR: CGFloat? = nil

    static let idle = Pose()
    /// In piedi con un minimo di tono nelle braccia.
    static let riposo = Pose(shoulderZ: -0.10, elbow: 0.10)
}

struct Keyframe {
    let pose: Pose
    let duration: Double
}

// MARK: - Cinematica 2D (piano Y-Z: tutte le rotazioni del rig sono attorno a X)

struct Punto2D: Equatable, Sendable {
    var y: CGFloat
    var z: CGFloat
}

func ruotaX(_ angolo: CGFloat, _ p: Punto2D) -> Punto2D {
    let c = CGFloat(cos(Double(angolo)))
    let s = CGFloat(sin(Double(angolo)))
    return Punto2D(y: p.y * c - p.z * s, z: p.y * s + p.z * c)
}

func distanza2D(_ a: Punto2D, _ b: Punto2D) -> CGFloat {
    let dy = a.y - b.y
    let dz = a.z - b.z
    return (dy * dy + dz * dz).squareRoot()
}

/// Punto a distanza "lunghezza" dalla base: angolo 0 = braccio che pende
/// in giu' (direzione (−cos a, −sin a)), come i nodi del rig.
func puntoBraccio(_ base: Punto2D, angolo: CGFloat, lunghezza: CGFloat) -> Punto2D {
    Punto2D(
        y: base.y - lunghezza * CGFloat(cos(Double(angolo))),
        z: base.z - lunghezza * CGFloat(sin(Double(angolo)))
    )
}

/// IK analitica a due link (spalla + gomito) nel piano Y-Z: angoli che
/// portano la mano esattamente sul bersaglio. ramo = +1/−1 decide da che
/// parte piega il gomito. Se il bersaglio esce dalla portata la distanza
/// viene saturata: il braccio resta dritto verso il bersaglio invece di
/// strappare la spalla.
func angoliIk(spalla: Punto2D, bersaglio: Punto2D, l1: CGFloat, l2: CGFloat, ramo: Int) -> (spalla: CGFloat, avambraccio: CGFloat) {
    let dy = bersaglio.y - spalla.y
    let dz = bersaglio.z - spalla.z
    var d = (dy * dy + dz * dz).squareRoot()
    d = min(max(d, abs(l1 - l2) + 0.5), l1 + l2 - 0.5)
    let angoloSt = CGFloat(Double(atan2(Double(-dz), Double(-dy))))
    let cosK = min(max((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1), 1)
    let k = CGFloat(acos(Double(cosK)))
    let angoloSpalla = angoloSt - CGFloat(ramo) * k
    let gomito = puntoBraccio(spalla, angolo: angoloSpalla, lunghezza: l1)
    let angoloAvambraccio = CGFloat(Double(atan2(Double(gomito.z - bersaglio.z), Double(gomito.y - bersaglio.y))))
    return (angoloSpalla, angoloAvambraccio)
}

func lerpCG(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

private func lerpOpzionale(_ a: CGFloat?, _ b: CGFloat?, _ t: CGFloat) -> CGFloat? {
    switch (a, b) {
    case let (x?, y?):
        return lerpCG(x, y, t)
    case let (x?, nil):
        return x
    case let (nil, y?):
        return y
    default:
        return nil
    }
}

func lerpPose(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
    Pose(
        bodyPitch: lerpCG(a.bodyPitch, b.bodyPitch, t),
        rootLift: lerpCG(a.rootLift, b.rootLift, t),
        torsoPitch: lerpCG(a.torsoPitch, b.torsoPitch, t),
        pelvisDrop: lerpCG(a.pelvisDrop, b.pelvisDrop, t),
        shoulderX: lerpCG(a.shoulderX, b.shoulderX, t),
        shoulderZ: lerpCG(a.shoulderZ, b.shoulderZ, t),
        elbow: lerpCG(a.elbow, b.elbow, t),
        hip: lerpCG(a.hip, b.hip, t),
        knee: lerpCG(a.knee, b.knee, t),
        pelvisY: lerpOpzionale(a.pelvisY, b.pelvisY, t),
        hipL: lerpOpzionale(a.hipL ?? a.hip, b.hipL ?? b.hip, t),
        hipR: lerpOpzionale(a.hipR ?? a.hip, b.hipR ?? b.hip, t),
        kneeL: lerpOpzionale(a.kneeL ?? a.knee, b.kneeL ?? b.knee, t),
        kneeR: lerpOpzionale(a.kneeR ?? a.knee, b.kneeR ?? b.knee, t)
    )
}

func v3(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
    SCNVector3(Float(x), Float(y), Float(z))
}

// MARK: - Keyframe dei movimenti (numeri dello studio, corpo 175 cm)

enum Keyframes {
    static func forMovement(_ movement: MovementType) -> [Keyframe] {
        switch movement {
        case .pushUp:
            return [
                Keyframe(pose: Pose(bodyPitch: 1.17, shoulderX: 1.17, pelvisY: 44.5), duration: 1.0),
                Keyframe(pose: Pose(bodyPitch: 1.24, shoulderX: 1.24, elbow: -0.95, pelvisY: 37.8), duration: 1.0)
            ]
        case .pullUp:
            return [
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: -0.40, hip: -0.50, knee: -0.90, pelvisY: 104), duration: 0.9),
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: -0.70, hip: -0.20, pelvisY: 106.5, kneeL: -0.50, kneeR: -0.55), duration: 0.8),
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: -2.05, hip: -0.25, pelvisY: 141, kneeL: -0.55, kneeR: -0.55), duration: 0.9),
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: -0.70, hip: -0.20, pelvisY: 106.5, kneeL: -0.50, kneeR: -0.55), duration: 0.8)
            ]
        case .squat:
            return [
                Keyframe(pose: .riposo, duration: 0.5),
                Keyframe(pose: Pose(torsoPitch: 0.30, shoulderX: -1.50, elbow: 0.25, hip: -1.15, knee: -1.45), duration: 1.1),
                Keyframe(pose: .riposo, duration: 0.9)
            ]
        case .curl:
            return [
                Keyframe(pose: Pose(elbow: 0.10), duration: 0.7),
                Keyframe(pose: Pose(elbow: 2.40), duration: 0.8)
            ]
        case .row:
            let base = Pose(torsoPitch: 0.95, shoulderX: -0.15, hip: -0.25, knee: -0.45)
            return [
                Keyframe(pose: { var p = base; p.elbow = -0.15; return p }(), duration: 0.6),
                Keyframe(pose: { var p = base; p.elbow = -1.95; return p }(), duration: 0.7)
            ]
        case .bench:
            let base = Pose(bodyPitch: -1.40, hip: -0.34, knee: -0.21, pelvisY: 39.5)
            return [
                Keyframe(pose: { var p = base; p.shoulderX = 1.74; p.elbow = 0.05; return p }(), duration: 1.0),
                Keyframe(pose: { var p = base; p.shoulderX = 1.05; p.elbow = -0.90; return p }(), duration: 1.0)
            ]
        case .lateralRaise:
            return [
                Keyframe(pose: .riposo, duration: 0.4),
                Keyframe(pose: Pose(shoulderZ: -1.35, elbow: 0.20), duration: 0.9),
                Keyframe(pose: .riposo, duration: 0.9)
            ]
        case .lunge:
            return [
                Keyframe(pose: .riposo, duration: 0.5),
                Keyframe(pose: Pose(torsoPitch: 0.12, shoulderX: -0.35, elbow: 0.25, hipL: -0.85, hipR: 0.55, kneeL: -0.85, kneeR: -0.20), duration: 0.9),
                Keyframe(pose: .riposo, duration: 0.9)
            ]
        case .plank:
            return [Keyframe(pose: Pose(bodyPitch: 1.36, shoulderX: 1.36, elbow: 1.57, pelvisY: 27.1), duration: 3.0)]
        case .custom:
            return [
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: 1.40), duration: 1.2),
                Keyframe(pose: Pose(shoulderX: -2.90, elbow: -0.10), duration: 1.2)
            ]
        }
    }
}

// MARK: - Mesh loftate

struct AnelloLoft {
    let t: CGFloat
    let rx: CGFloat
    let rz: CGFloat
}

@MainActor
final class AvatarRig {
    let scene = SCNScene()
    let root = SCNNode()
    let cameraNode = SCNNode()

    private var pelvisNode = SCNNode()
    private var spineNode = SCNNode()
    private var spallaL = SCNNode()
    private var spallaR = SCNNode()
    private var gomitoL = SCNNode()
    private var gomitoR = SCNNode()
    private var cosciaL = SCNNode()
    private var cosciaR = SCNNode()
    private var ginocchioL = SCNNode()
    private var ginocchioR = SCNNode()
    private var manoL = SCNNode()
    private var manoR = SCNNode()
    private var nodoPetto = SCNNode()

    private var muscleNodes: [MuscleGroup: [SCNNode]] = [:]
    private var highlighted: [SCNMaterial] = []

    private var sbarraFissa: SCNNode?
    private var sbarraMani: SCNNode?
    private var pancaNodo: SCNNode?
    private var manubri: [SCNNode] = []
    private var demoTask: Task<Void, Never>?

    /// Mani inchiodate (sbarra o pavimento) durante gli esercizi di
    /// contatto: l'IK riporta sempre le mani qui, cosi' non scivolano.
    private struct AncoreMani {
        var sx: Punto2D
        var dx: Punto2D
        var ramoSx: Int
        var ramoDx: Int
    }
    private var ancore: AncoreMani?

    private let bodyH: CGFloat
    private let shoulderWidth: CGFloat
    private let scala: CGFloat
    private let thighLen: CGFloat
    private let shinLen: CGFloat
    private let footH: CGFloat
    private let vitaW: CGFloat
    private let torsoH: CGFloat
    private let upperLen: CGFloat
    private let foreLen: CGFloat
    private let glow = UIColor(hex: 0x00E5FF)

    init(measurements m: Measurements, appearance a: Appearance, fitness f: Double, faceMesh: FaceMeshData?, facePhoto: UIImage? = nil) {
        bodyH = max(m.heightCm, 120)
        scala = bodyH / 175
        shoulderWidth = max(m.shoulderCm / .pi, bodyH * 0.15)
        let legLen = min(max(m.legCm, bodyH * 0.30), bodyH * 0.58)
        thighLen = max(legLen * 0.55, bodyH * 0.15)
        shinLen = max(legLen * 0.45, bodyH * 0.12)
        footH = max(bodyH * 0.04 + CGFloat(m.shoeSize - 36) * 0.06, 2)
        vitaW = max(m.waistCm / .pi, bodyH * 0.11)
        let armLen = min(max(m.armCm, bodyH * 0.35), bodyH * 0.60) * 1.08
        upperLen = armLen * 0.55
        foreLen = armLen * 0.45
        torsoH = max((thighLen + shinLen) * 0.62, bodyH * 0.22)
        scene.background.contents = UIColor.clear
        scene.rootNode.addChildNode(root)
        build(measurements: m, appearance: a, fitness: f, faceMesh: faceMesh, facePhoto: facePhoto)
        addLightsAndCamera()
    }

    // MARK: costruzione

    private func build(measurements m: Measurements, appearance a: Appearance, fitness f: Double, faceMesh: FaceMeshData?, facePhoto: UIImage?) {
        let h = bodyH
        let legLen = thighLen + shinLen
        let headR = max(m.headCm / (2 * .pi), h * 0.05)
        let neckR = max((m.neckCm / .pi) * 0.62, headR * 0.30)
        let shoulderW = shoulderWidth
        let waistW = max(m.waistCm / .pi, h * 0.11)
        let hipW = max(m.hipCm / .pi, h * 0.12)
        let chestW = shoulderW * 0.96
        let bmi = m.bmi
        let thick = min(max(0.80 + (bmi - 18.5) * 0.055, 0.75), 1.70)
        let muscle = 1.0 + 0.30 * f
        let armR = max(shoulderW * 0.088, h * 0.026) * muscle
        let legR = max(hipW * 0.19, h * 0.034) * muscle

        let skinIndex = min(max(a.skinTone, 0), Appearance.skinTones.count - 1)
        let hairIndex = min(max(a.hairColor, 0), Appearance.hairColors.count - 1)
        let outfitIndex = min(max(a.outfitColor, 0), Appearance.outfitColors.count - 1)
        let skin = UIColor(hex: Appearance.skinTones[skinIndex].1)
        let hair = UIColor(hex: Appearance.hairColors[hairIndex].1)
        let outfit = UIColor(hex: Appearance.outfitColors[outfitIndex].1)
        let outfitScuro = outfit.blended(0.35, with: UIColor.black)
        let skinScuro = skin.blended(0.15, with: UIColor.black)
        let dark = UIColor(hex: 0x14181D)

        func mat(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.specular.contents = UIColor.white.withAlphaComponent(0.12)
            material.isDoubleSided = true
            return material
        }

        func geo(_ parent: SCNNode, _ geometry: SCNGeometry, _ material: SCNMaterial, _ pos: SCNVector3) -> SCNNode {
            let n = SCNNode(geometry: geometry)
            n.geometry?.firstMaterial = material
            n.position = pos
            parent.addChildNode(n)
            return n
        }

        func joint(_ parent: SCNNode, _ pos: SCNVector3) -> SCNNode {
            let n = SCNNode()
            n.position = pos
            parent.addChildNode(n)
            return n
        }

        let matSkin = mat(skin)
        let matSkinScuro = mat(skinScuro)
        let matHair = mat(hair)
        let matOutfit = mat(outfit)
        let matOutfitScuro = mat(outfitScuro)
        let matDark = mat(dark)

        // ---- bacino e busto ----
        root.addChildNode(pelvisNode)
        spineNode = joint(pelvisNode, v3(0, 4.5, 0))
        let profiloPelvi: [AnelloLoft] = [
            AnelloLoft(t: 0, rx: hipW * 0.58, rz: hipW * 0.50 * thick),
            AnelloLoft(t: 0.5, rx: hipW * 0.52, rz: hipW * 0.42 * thick),
            AnelloLoft(t: 1, rx: waistW * 0.55, rz: waistW * 0.40 * thick)
        ]
        let pelviGeo = geo(pelvisNode, AvatarRig.loft(da: v3(0, -1, 0), a: v3(0, 6.5, 0), anelli: profiloPelvi, bulge: 0, segmenti: 14, materiale: matOutfitScuro), matOutfitScuro, v3(0, 0, 0))
        let profiloBusto: [AnelloLoft] = [
            AnelloLoft(t: 0, rx: waistW * 0.52, rz: waistW * 0.38 * thick),
            AnelloLoft(t: 0.45, rx: chestW * 0.47, rz: waistW * 0.44 * thick),
            AnelloLoft(t: 1, rx: chestW * 0.50, rz: waistW * 0.33 * thick)
        ]
        let bustoGeo = geo(spineNode, AvatarRig.loft(da: v3(0, torsoH * 0.10, 0), a: v3(0, torsoH * 0.66, 0), anelli: profiloBusto, bulge: 0.04, segmenti: 14, materiale: matOutfit), matOutfit, v3(0, 0, 0))
        nodoPetto = joint(spineNode, v3(0, torsoH * 0.45, 0))

        var deltoidi: [SCNNode] = []
        for lato in [-1.0, 1.0] {
            let d = geo(spineNode, SCNSphere(radius: armR * 1.5), matSkinScuro, v3(CGFloat(lato) * shoulderW * 0.47, torsoH * 0.62, 0))
            d.scale = v3(1, 0.9, 0.9)
            deltoidi.append(d)
        }
        var pettorali: [SCNNode] = []
        for lato in [-1.0, 1.0] {
            let p = geo(spineNode, SCNSphere(radius: armR * 1.15), matOutfit, v3(CGFloat(lato) * chestW * 0.22, torsoH * 0.50, chestW * 0.235 * thick))
            p.scale = v3(1, 0.8, 0.75)
            pettorali.append(p)
        }
        let trapezio = geo(spineNode, SCNSphere(radius: armR * 1.55), matOutfit, v3(0, torsoH * 0.64, -chestW * 0.16 * thick))
        trapezio.scale = v3(1.15, 0.7, 0.8)

        // ---- collo e testa ----
        let colloAlto = torsoH + neckR * 0.7
        _ = geo(spineNode, SCNCapsule(capRadius: neckR, height: max(colloAlto - torsoH * 0.90 + neckR, 1)), matSkin, v3(0, (torsoH * 0.90 + colloAlto) / 2, 0))
        let neckJoint = joint(spineNode, v3(0, colloAlto, 0))
        let headJoint = joint(neckJoint, v3(0, headR, 0))
        // UNA testa sola: la mesh TrueDepth copre solo la faccia, senza
        // retro: messa sul 3D con i capelli sopra sembrava una seconda
        // testa che galleggia. La scansione resta salvata (per le misure
        // e per quando la rimetteremo a posto sul 3D), il volto visibile
        // sul 3D è quello della foto con maschera sfumata, se c'è.
        do {
            let cranio = geo(headJoint, SCNSphere(radius: headR * 0.96), matSkin, v3(0, 0, 0))
            cranio.scale = v3(1, 1.06, 0.96)
            let mascella = geo(headJoint, SCNSphere(radius: headR * 0.60), matSkin, v3(0, -headR * 0.50, headR * 0.26))
            mascella.scale = v3(0.86, 0.82, 0.92)
            for lato in [-1.0, 1.0] {
                _ = geo(headJoint, SCNSphere(radius: headR * 0.15), matSkinScuro, v3(CGFloat(lato) * headR * 0.94, 0, 0))
            }
            _ = geo(headJoint, SCNSphere(radius: headR * 0.11), matSkinScuro, v3(0, -headR * 0.20, headR * 0.92))
            let calotta = geo(headJoint, SCNSphere(radius: headR), matHair, v3(0, headR * 0.14, -headR * 0.20))
            calotta.scale = v3(1.03, 1.02, 1.02)
            let nuca = geo(headJoint, SCNSphere(radius: headR * 0.70), matHair, v3(0, headR * 0.50, -headR * 0.28))
            nuca.scale = v3(1.0, 0.92, 1.0)
        }
        // Volto dalla galleria (Memoji o selfie, ritagliato in cerchio): disco davanti
        // alla testa, luce costante perche' la foto deve restare leggibile.
        if let volto = facePhoto {
            let materialeVolto = SCNMaterial()
            materialeVolto.diffuse.contents = AvatarRig.voltoSfumato(volto)
            materialeVolto.lightingModel = .constant
            materialeVolto.isDoubleSided = false
            // appena davanti alla superficie della testa: all'altezza della
            // vecchia z = 0.82 headR il piano finiva DENTRO il cranio
            let lato = headR * 1.55
            let piano = SCNPlane(width: lato, height: lato)
            piano.firstMaterial = materialeVolto
            let nodoVolto = SCNNode(geometry: piano)
            nodoVolto.position = v3(0, -headR * 0.02, headR * 1.04)
            headJoint.addChildNode(nodoVolto)
        }

        // ---- braccia ----
        var omeri: [SCNNode] = []
        var avambracci: [SCNNode] = []
        for lato in [-1.0, 1.0] {
            let spalla = joint(spineNode, v3(CGFloat(lato) * shoulderW / 2, torsoH - 3.2, 0))
            let upperGeo = geo(spalla, AvatarRig.loftArto(da: v3(0, 0, 0), a: v3(0, -upperLen, 0), raggio: armR, bulge: 0.26, materiale: matSkin), matSkin, v3(0, 0, 0))
            let gomito = joint(spalla, v3(0, -upperLen, 0))
            let foreGeo = geo(gomito, AvatarRig.loftArto(da: v3(0, 0, 0), a: v3(0, -foreLen, 0), raggio: armR * 0.82, bulge: 0.09, materiale: matSkin), matSkin, v3(0, 0, 0))
            _ = geo(gomito, SCNSphere(radius: armR * 0.8), matSkin, v3(0, 0, 0))
            _ = geo(gomito, SCNSphere(radius: armR * 0.78), matSkin, v3(0, -foreLen * 1.1, 0))
            let mano = joint(gomito, v3(0, -foreLen, 0))
            if lato < 0 {
                spallaL = spalla
                gomitoL = gomito
                manoL = mano
            } else {
                spallaR = spalla
                gomitoR = gomito
                manoR = mano
            }
            omeri.append(upperGeo)
            avambracci.append(foreGeo)
        }

        // ---- gambe ----
        let footLen = legR * 3.4
        var cosce: [SCNNode] = []
        var stinchi: [SCNNode] = []
        for lato in [-1.0, 1.0] {
            let coscia = joint(pelvisNode, v3(CGFloat(lato) * hipW * 0.30, -3.5, 0))
            let cosciaGeo = geo(coscia, AvatarRig.loftArto(da: v3(0, 0, 0), a: v3(0, -thighLen, 0), raggio: legR, bulge: 0.17, materiale: matOutfit), matOutfit, v3(0, 0, 0))
            let ginocchio = joint(coscia, v3(0, -thighLen, 0))
            let stincoGeo = geo(ginocchio, AvatarRig.loftArto(da: v3(0, 0, 0), a: v3(0, -shinLen, 0), raggio: legR * 0.80, bulge: 0.09, materiale: matSkin), matSkin, v3(0, 0, 0))
            _ = geo(ginocchio, SCNSphere(radius: legR * 0.9), matOutfit, v3(0, 0, 0))
            _ = geo(ginocchio, SCNBox(width: legR * 2.2, height: footH, length: footLen, chamferRadius: footH * 0.45), matDark, v3(0, -shinLen - footH * 0.5, footH * 1.1))
            if lato < 0 {
                cosciaL = coscia
                ginocchioL = ginocchio
            } else {
                cosciaR = coscia
                ginocchioR = ginocchio
            }
            cosce.append(cosciaGeo)
            stinchi.append(stincoGeo)
        }

        // ---- mappa dei muscoli per l'evidenziazione ----
        muscleNodes[.spalle] = deltoidi + omeri
        muscleNodes[.braccia] = avambracci
        muscleNodes[.petto] = pettorali + [bustoGeo]
        muscleNodes[.dorso] = [bustoGeo, trapezio]
        muscleNodes[.core] = [bustoGeo, pelviGeo]
        muscleNodes[.gambe] = cosce + stinchi
        muscleNodes[.cardio] = [bustoGeo] + cosce + stinchi

        // ---- pedana e anello ----
        let platformR = max(shoulderW, hipW) * 1.25 + 8
        let platformMat = SCNMaterial()
        platformMat.diffuse.contents = dark
        platformMat.emission.contents = glow.withAlphaComponent(0.25)
        geo(root, SCNCylinder(radius: platformR, height: 1.6), platformMat, v3(0, -0.8, 0))
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents = dark
        ringMat.emission.contents = glow
        let ring = geo(root, SCNTorus(ringRadius: platformR, pipeRadius: 0.5), ringMat, v3(0, 0.2, 0))
        let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)
        ring.runAction(SCNAction.repeatForever(spin))
    }

    static func faceGeometry(from face: FaceMeshData) -> SCNGeometry? {
        guard face.positions.count % 3 == 0,
              !face.indices.isEmpty else { return nil }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(face.positions.count / 3)
        for i in stride(from: 0, to: face.positions.count, by: 3) {
            vertices.append(SCNVector3(face.positions[i], face.positions[i + 1], face.positions[i + 2]))
        }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        var sources: [SCNGeometrySource] = [vertexSource]
        if face.normals.count == face.positions.count {
            var normals: [SCNVector3] = []
            normals.reserveCapacity(face.normals.count / 3)
            for i in stride(from: 0, to: face.normals.count, by: 3) {
                normals.append(SCNVector3(face.normals[i], face.normals[i + 1], face.normals[i + 2]))
            }
            sources.append(SCNGeometrySource(normals: normals))
        }
        let element = SCNGeometryElement(indices: face.indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    // MARK: loft

    /// Tubo a sezione ellittica con profili per anello: gambe, busto, avambracci.
    /// Normali calcolate per vertice e orientate verso l'esterno.
    /// Volto con maschera ovale a bordo sfumato: si fonde col cranio
    /// invece di sembrare un adesivo ritagliato.
    nonisolated static func voltoSfumato(_ volto: UIImage) -> UIImage {
        let lato = max(volto.size.width, volto.size.height)
        let formato = UIGraphicsImageRendererFormat.default()
        formato.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: lato, height: lato), format: formato)
        let maschera: CGImage? = {
            guard let contestoMaschera = CGContext(
                data: nil,
                width: Int(lato.rounded()), height: Int(lato.rounded()),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            var posizioni: [CGFloat] = [0, 0.66, 1.0]
            let bianco = CGColor(gray: 1, alpha: 1)
            let nero = CGColor(gray: 0, alpha: 1)
            guard let gradiente = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [bianco, bianco, nero] as CFArray, locations: &posizioni) else { return nil }
            contestoMaschera.saveGState()
            contestoMaschera.translateBy(x: lato / 2, y: lato / 2)
            contestoMaschera.scaleBy(x: 1, y: 1.08)
            contestoMaschera.drawRadialGradient(
                gradiente,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: lato / 2,
                options: []
            )
            contestoMaschera.restoreGState()
            return contestoMaschera.makeImage()
        }()
        return renderer.image { contesto in
            if let maschera {
                contesto.cgContext.clip(
                    to: CGRect(x: 0, y: 0, width: lato, height: lato),
                    mask: maschera
                )
            }
            volto.draw(in: CGRect(x: (lato - volto.size.width) / 2, y: (lato - volto.size.height) / 2, width: volto.size.width, height: volto.size.height))
        }
    }

    nonisolated static func loft(da a: SCNVector3, a b: SCNVector3, anelli: [AnelloLoft], bulge: CGFloat, segmenti: Int, materiale: SCNMaterial) -> SCNGeometry {
        let ax = CGFloat(b.x - a.x), ay = CGFloat(b.y - a.y), az = CGFloat(b.z - a.z)
        let lunghezza = CGFloat(sqrt(Double(ax * ax + ay * ay + az * az)))
        if lunghezza < 0.0001 || anelli.count < 2 {
            return SCNSphere(radius: 0.5)
        }
        let zx = ax / lunghezza, zy = ay / lunghezza, zz = az / lunghezza
        var ux: CGFloat = 0, uy: CGFloat = 1, uz: CGFloat = 0
        if abs(zy) >= 0.9 {
            ux = 1
            uy = 0
        }
        var cx = uy * zz - uz * zy
        var cy = uz * zx - ux * zz
        var cz = ux * zy - uy * zx
        let l1 = CGFloat(sqrt(Double(cx * cx + cy * cy + cz * cz)))
        if l1 < 0.0001 { return SCNSphere(radius: 0.5) }
        cx /= l1; cy /= l1; cz /= l1
        let dx = zy * cz - zz * cy
        let dy = zz * cx - zx * cz
        let dz = zx * cy - zy * cx

        var vertici: [SCNVector3] = []
        var radiali: [SCNVector3] = []
        var indici: [Int32] = []
        for anello in anelli {
            let g = 1 + bulge * CGFloat(sin(Double(.pi * anello.t)))
            let px = CGFloat(a.x) + ax * anello.t
            let py = CGFloat(a.y) + ay * anello.t
            let pz = CGFloat(a.z) + az * anello.t
            for i in 0..<segmenti {
                let theta = 2 * CGFloat.pi * CGFloat(i) / CGFloat(segmenti)
                let c = CGFloat(cos(Double(theta)))
                let s = CGFloat(sin(Double(theta)))
                let ox = (cx * c * anello.rx + dx * s * anello.rz) * g
                let oy = (cy * c * anello.rx + dy * s * anello.rz) * g
                let oz = (cz * c * anello.rx + dz * s * anello.rz) * g
                vertici.append(SCNVector3(Float(px + ox), Float(py + oy), Float(pz + oz)))
                var rl = CGFloat(sqrt(Double(ox * ox + oy * oy + oz * oz)))
                if rl < 0.0001 { rl = 1 }
                radiali.append(SCNVector3(Float(ox / rl), Float(oy / rl), Float(oz / rl)))
            }
        }
        for i in 0..<(anelli.count - 1) {
            for j in 0..<segmenti {
                let j2 = (j + 1) % segmenti
                let p0 = i * segmenti + j
                let p1 = i * segmenti + j2
                let p2 = (i + 1) * segmenti + j
                let p3 = (i + 1) * segmenti + j2
                indici.append(contentsOf: [Int32(p0), Int32(p1), Int32(p2), Int32(p1), Int32(p3), Int32(p2)])
            }
        }
        var normAcc = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: vertici.count)
        for t in stride(from: 0, to: indici.count, by: 3) {
            let i0 = Int(indici[t]), i1 = Int(indici[t + 1]), i2 = Int(indici[t + 2])
            let v0 = vertici[i0], v1 = vertici[i1], v2 = vertici[i2]
            let e1x = v1.x - v0.x, e1y = v1.y - v0.y, e1z = v1.z - v0.z
            let e2x = v2.x - v0.x, e2y = v2.y - v0.y, e2z = v2.z - v0.z
            let nx = e1y * e2z - e1z * e2y
            let ny = e1z * e2x - e1x * e2z
            let nz = e1x * e2y - e1y * e2x
            for idx in [i0, i1, i2] {
                normAcc[idx].x += nx
                normAcc[idx].y += ny
                normAcc[idx].z += nz
            }
        }
        var normali: [SCNVector3] = []
        normali.reserveCapacity(vertici.count)
        for i in 0..<vertici.count {
            let acc = normAcc[i]
            let r = radiali[i]
            var nx = acc.x, ny = acc.y, nz = acc.z
            var l = sqrt(nx * nx + ny * ny + nz * nz)
            if l < 0.0001 {
                nx = r.x; ny = r.y; nz = r.z
                l = 1
            }
            nx /= l; ny /= l; nz /= l
            if nx * r.x + ny * r.y + nz * r.z < 0 {
                nx = -nx; ny = -ny; nz = -nz
            }
            normali.append(SCNVector3(nx, ny, nz))
        }
        let source = SCNGeometrySource(vertices: vertici)
        let normalSource = SCNGeometrySource(normals: normali)
        let element = SCNGeometryElement(indices: indici, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source, normalSource], elements: [element])
        geometry.firstMaterial = materiale
        return geometry
    }

    private static func loftArto(da a: SCNVector3, a b: SCNVector3, raggio: CGFloat, bulge: CGFloat, materiale: SCNMaterial) -> SCNGeometry {
        var anelli: [AnelloLoft] = []
        for i in 0...8 {
            let t = CGFloat(i) / 8
            anelli.append(AnelloLoft(t: t, rx: raggio, rz: raggio))
        }
        return loft(da: a, a: b, anelli: anelli, bulge: bulge, segmenti: 12, materiale: materiale)
    }

    // MARK: posa

    /// Altezza del bacino: esplicita (pose a terra o appese) o calcolata per
    /// tenere la gamba piu' corta con lo scarpone appoggiato al pavimento.
    func altezzaPelvi(_ p: Pose) -> CGFloat {
        if let y = p.pelvisY {
            return y * scala
        }
        func sotto(_ f: CGFloat, _ k: CGFloat) -> CGFloat {
            3.5 + thighLen * CGFloat(cos(Double(f))) + shinLen * CGFloat(cos(Double(f - k)))
        }
        let fL = p.hipL ?? p.hip
        let fR = p.hipR ?? p.hip
        let gL = p.kneeL ?? p.knee
        let gR = p.kneeR ?? p.knee
        return min(sotto(fL, gL), sotto(fR, gR)) + footH
    }

    /// Posizione (y,z) della spalla per una posa: la catena bacino→spina
    /// ruota solo attorno a X, quindi la vista laterale e' tutto quello che
    /// serve per le braccia.
    func spalla2D(p: Pose) -> Punto2D {
        let o1 = ruotaX(p.bodyPitch, Punto2D(y: 4.5, z: 0))
        let o2 = ruotaX(p.bodyPitch + p.torsoPitch, Punto2D(y: torsoH - 3.2, z: 0))
        return Punto2D(
            y: altezzaPelvi(p) - p.pelvisDrop + p.rootLift + o1.y + o2.y,
            z: o1.z + o2.z
        )
    }

    /// Posizione (y,z) della mano con i valori chiave della posa.
    func mano2D(p: Pose) -> Punto2D {
        let sp = spalla2D(p: p)
        let tetaspalla = p.bodyPitch + p.torsoPitch - p.shoulderX
        let tetagomito = tetaspalla - p.elbow
        let gomito = puntoBraccio(sp, angolo: tetaspalla, lunghezza: upperLen)
        return puntoBraccio(gomito, angolo: tetagomito, lunghezza: foreLen)
    }

    /// Quanto la posa metterebbe le mani fuori dalla portata dell'ancora
    /// (0 = presa perfetta possibile in tutto il ciclo).
    func scartoManiAncorate(_ p: Pose) -> CGFloat {
        guard let ancore else { return 0 }
        let sp = spalla2D(p: p)
        func fuori(_ bersaglio: Punto2D) -> CGFloat {
            let d = distanza2D(sp, bersaglio)
            let minD = abs(upperLen - foreLen) + 0.5
            let maxD = upperLen + foreLen - 0.5
            if d < minD { return minD - d }
            if d > maxD { return d - maxD }
            return 0
        }
        return max(fuori(ancore.sx), fuori(ancore.dx))
    }

    func applyPose(_ p: Pose) {
        pelvisNode.position = v3(0, altezzaPelvi(p) - p.pelvisDrop + p.rootLift, 0)
        pelvisNode.eulerAngles = v3(p.bodyPitch, 0, 0)
        spineNode.eulerAngles = v3(p.torsoPitch, 0, 0)
        if let ancore {
            // mani inchiodate: le spalle ruotano quel che serve per tenere
            // la presa su sbarra o pavimento per tutto il ciclo
            let base = p.bodyPitch + p.torsoPitch
            let sp = spalla2D(p: p)
            let aSx = angoliIk(spalla: sp, bersaglio: ancore.sx, l1: upperLen, l2: foreLen, ramo: ancore.ramoSx)
            let aDx = angoliIk(spalla: sp, bersaglio: ancore.dx, l1: upperLen, l2: foreLen, ramo: ancore.ramoDx)
            spallaL.eulerAngles = v3(aSx.spalla - base, 0, 0)
            spallaR.eulerAngles = v3(aDx.spalla - base, 0, 0)
            gomitoL.eulerAngles = v3(aSx.avambraccio - aSx.spalla, 0, 0)
            gomitoR.eulerAngles = v3(aDx.avambraccio - aDx.spalla, 0, 0)
        } else {
            spallaL.eulerAngles = v3(-p.shoulderX, 0, p.shoulderZ)
            spallaR.eulerAngles = v3(-p.shoulderX, 0, -p.shoulderZ)
            gomitoL.eulerAngles = v3(-p.elbow, 0, 0)
            gomitoR.eulerAngles = v3(-p.elbow, 0, 0)
        }
        cosciaL.eulerAngles = v3(-(p.hipL ?? p.hip), 0, 0)
        cosciaR.eulerAngles = v3(-(p.hipR ?? p.hip), 0, 0)
        ginocchioL.eulerAngles = v3(p.kneeL ?? p.knee, 0, 0)
        ginocchioR.eulerAngles = v3(p.kneeR ?? p.knee, 0, 0)
        if let barra = sbarraMani {
            let mL = manoL.worldPosition
            let mR = manoR.worldPosition
            barra.position = v3(0, CGFloat(mL.y + mR.y) / 2, CGFloat(mL.z + mR.z) / 2)
        }
    }

    /// Interpolazione ciclica: l'ultimo fotogramma si ricollega al primo.
    nonisolated static func posaA(_ t: CGFloat, keys: [Keyframe], total: CGFloat) -> Pose {
        var time = t.truncatingRemainder(dividingBy: max(total, 0.001))
        if time < 0 { time += max(total, 0.001) }
        var acc: Double = 0
        for (index, key) in keys.enumerated() {
            if time < acc + key.duration || index == keys.count - 1 {
                let local = min(max(CGFloat((Double(time) - acc) / max(key.duration, 0.001)), 0), 1)
                let eased = local * local * (3 - 2 * local)
                let precedente = index > 0 ? keys[index - 1].pose : (keys.last?.pose ?? .idle)
                return lerpPose(precedente, key.pose, eased)
            }
            acc += key.duration
        }
        return keys.last?.pose ?? .idle
    }

    // MARK: luci e camera

    private func addLightsAndCamera() {
        let h = bodyH

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.position = v3(h * 0.9, h * 1.7, h * 1.4)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = glow
        rim.light?.intensity = 650
        rim.position = v3(-h * 0.8, h * 0.9, -h * 1.6)
        scene.rootNode.addChildNode(rim)

        let camera = SCNCamera()
        camera.fieldOfView = 46
        // Il corpo è in centimetri: i piani depth di default (zFar = 100)
        // tagliavano via tutta la scena, con la camera a 2,2h il manichino
        // restava invisibile e sotto si vedeva il disegno 2D.
        camera.zNear = 1
        camera.zFar = h * 20
        cameraNode.camera = camera
        cameraNode.position = v3(0, h * 0.58, h * 2.2)
        let target = SCNNode()
        target.position = v3(0, h * 0.52, 0)
        cameraNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(target)
    }

    // MARK: animazione

    func play(_ movement: MovementType, muscles: [MuscleGroup]) {
        stop()
        CrashLog.append("demo avviata: \(movement.rawValue)")
        setHighlight(muscles)
        let keys = Keyframes.forMovement(movement)
        applyPose(keys.first?.pose ?? .riposo)
        mostraProp(movement)
        ancore = nil
        if movement == .pullUp || movement == .pushUp || movement == .plank {
            ancore = ancoraPer(keys.first?.pose ?? .riposo)
        }
        let total = CGFloat(max(keys.reduce(0.0) { $0 + $1.duration }, 0.001))
        // driver deterministico: un task a 30 fps aggiorna le pose sul main
        // actor, indipendente dal clock delle SCNAction
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            let inizio = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self else { return }
                let t = CGFloat(ProcessInfo.processInfo.systemUptime - inizio)
                self.applyPose(AvatarRig.posaA(t, keys: keys, total: total))
                try? await Task.sleep(for: .seconds(0.033))
            }
        }
    }

    /// Ancore della presa: le mani nel primo fotogramma. Il ramo del
    /// gomito si sceglie guardando la flessione del keyframe, cosi' il
    /// gomito resta piegato dalla parte giusta.
    private func ancoraPer(_ p: Pose) -> AncoreMani {
        let sp = spalla2D(p: p)
        let bersaglio = mano2D(p: p)
        let deltaKey = -p.elbow
        var migliore = -1
        var scarto = CGFloat.greatestFiniteMagnitude
        for ramo in [-1, 1] {
            let a = angoliIk(spalla: sp, bersaglio: bersaglio, l1: upperLen, l2: foreLen, ramo: ramo)
            let d = abs((a.avambraccio - a.spalla) - deltaKey)
            if d < scarto {
                scarto = d
                migliore = ramo
            }
        }
        return AncoreMani(sx: bersaglio, dx: bersaglio, ramoSx: migliore, ramoDx: migliore)
    }

    func stop() {
        demoTask?.cancel()
        demoTask = nil
        ancore = nil
        root.removeAction(forKey: "pulse")
        applyPose(.idle)
        clearHighlight()
        sbarraFissa?.removeFromParentNode()
        sbarraFissa = nil
        sbarraMani?.removeFromParentNode()
        sbarraMani = nil
        pancaNodo?.removeFromParentNode()
        pancaNodo = nil
        for m in manubri { m.removeFromParentNode() }
        manubri.removeAll()
    }

    func setHighlight(_ groups: [MuscleGroup]) {
        clearHighlight()
        for group in groups {
            for node in muscleNodes[group] ?? [] {
                if let material = node.geometry?.firstMaterial {
                    material.emission.contents = glow
                    highlighted.append(material)
                }
            }
        }
        guard !highlighted.isEmpty else { return }
        let materials = highlighted
        let pulse = SCNAction.customAction(duration: 1.0) { [weak self] _, t in
            guard let self else { return }
            let alpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi))
            for material in materials {
                material.emission.contents = self.glow.withAlphaComponent(alpha)
            }
        }
        root.runAction(SCNAction.repeatForever(pulse), forKey: "pulse")
    }

    private func clearHighlight() {
        for material in highlighted {
            material.emission.contents = UIColor.black
        }
        highlighted.removeAll()
    }

    // MARK: attrezzi

    private func mostraProp(_ movement: MovementType) {
        let shoulderW = shoulderWidth
        if movement == .pullUp {
            // Sbarra fissa nel mondo, all'altezza delle mani della fase appesa
            // (le keyframe sono progettate perche' le mani restino a quell'altezza).
            let materiale = SCNMaterial()
            materiale.diffuse.contents = UIColor(hex: 0x2A2F36)
            materiale.emission.contents = glow.withAlphaComponent(0.6)
            let barra = SCNNode(geometry: SCNCylinder(radius: 1.4 * scala, height: shoulderW * 2.6))
            barra.geometry?.firstMaterial = materiale
            barra.eulerAngles = v3(0, 0, .pi / 2)
            let mL = manoL.worldPosition
            let mR = manoR.worldPosition
            barra.position = v3(0, CGFloat(mL.y + mR.y) / 2, CGFloat(mL.z + mR.z) / 2)
            root.addChildNode(barra)
            sbarraFissa = barra
        }
        if movement == .bench {
            // Panca sotto il busto (il top tocca la schiena) e bilanciere che
            // segue le mani fase per fase.
            let petto = nodoPetto.worldPosition
            let top = CGFloat(petto.y) - vitaW * 0.46
            let materialePanca = SCNMaterial()
            materialePanca.diffuse.contents = UIColor(hex: 0x1A1E24)
            materialePanca.specular.contents = UIColor.white.withAlphaComponent(0.05)
            let cavalletto = SCNNode()
            let tavola = SCNNode(geometry: SCNBox(width: shoulderW * 1.7, height: 36 * scala, length: 64 * scala, chamferRadius: 1.5 * scala))
            tavola.geometry?.firstMaterial = materialePanca
            tavola.position = v3(0, top - 18 * scala, CGFloat(petto.z) - 12 * scala)
            cavalletto.addChildNode(tavola)
            let base = SCNNode(geometry: SCNBox(width: shoulderW * 1.5, height: 4 * scala, length: 46 * scala, chamferRadius: 1 * scala))
            base.geometry?.firstMaterial = materialePanca
            base.position = v3(0, top - 37 * scala, CGFloat(petto.z) - 12 * scala)
            cavalletto.addChildNode(base)
            root.addChildNode(cavalletto)
            pancaNodo = cavalletto

            let materialeFerro = SCNMaterial()
            materialeFerro.diffuse.contents = UIColor(hex: 0x364052)
            materialeFerro.specular.contents = UIColor.white.withAlphaComponent(0.2)
            let gruppo = SCNNode()
            let bilanciere = SCNNode(geometry: SCNCylinder(radius: 1.1 * scala, height: shoulderW * 2.4))
            bilanciere.geometry?.firstMaterial = materialeFerro
            bilanciere.eulerAngles = v3(0, 0, .pi / 2)
            gruppo.addChildNode(bilanciere)
            for lato in [-1.0, 1.0] {
                let disco = SCNNode(geometry: SCNCylinder(radius: 4.5 * scala, height: 3 * scala))
                disco.geometry?.firstMaterial = materialeFerro
                disco.eulerAngles = v3(0, 0, .pi / 2)
                disco.position = v3(CGFloat(lato) * (shoulderW * 1.2 - 1.5 * scala), 0, 0)
                gruppo.addChildNode(disco)
            }
            root.addChildNode(gruppo)
            sbarraMani = gruppo
            let mL = manoL.worldPosition
            let mR = manoR.worldPosition
            gruppo.position = v3(0, CGFloat(mL.y + mR.y) / 2, CGFloat(mL.z + mR.z) / 2)
        }
        if movement == .curl || movement == .row || movement == .lateralRaise || movement == .custom {
            for mano in [manoL, manoR] {
                let gruppo = SCNNode()
                let materialeFerro = SCNMaterial()
                materialeFerro.diffuse.contents = UIColor(hex: 0x364052)
                materialeFerro.specular.contents = UIColor.white.withAlphaComponent(0.2)
                let manico = SCNNode(geometry: SCNCapsule(capRadius: 1.2 * scala, height: 7 * scala))
                manico.geometry?.firstMaterial = materialeFerro
                manico.eulerAngles = v3(0, 0, .pi / 2)
                gruppo.addChildNode(manico)
                for lato in [-1.0, 1.0] {
                    let testa = SCNNode(geometry: SCNSphere(radius: 3.0 * scala))
                    testa.geometry?.firstMaterial = materialeFerro
                    testa.scale = v3(0.55, 1, 1)
                    testa.position = v3(CGFloat(lato) * 3.9 * scala, 0, 0)
                    gruppo.addChildNode(testa)
                }
                mano.addChildNode(gruppo)
                manubri.append(gruppo)
            }
        }
    }
}

private extension UIColor {
    func blended(_ frazione: CGFloat, with other: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * frazione,
            green: g1 + (g2 - g1) * frazione,
            blue: b1 + (b2 - b1) * frazione,
            alpha: a1
        )
    }
}
