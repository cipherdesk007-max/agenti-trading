import Foundation
import SceneKit

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

    static let idle = Pose()
}

struct Keyframe {
    let pose: Pose
    let duration: Double
}

func lerpCG(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
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
        knee: lerpCG(a.knee, b.knee, t)
    )
}

func v3(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
    SCNVector3(Float(x), Float(y), Float(z))
}

enum Keyframes {
    static func forMovement(_ movement: MovementType) -> [Keyframe] {
        switch movement {
        case .pushUp:
            return [
                Keyframe(pose: Pose(bodyPitch: -1.35, elbow: 0.25), duration: 1.0),
                Keyframe(pose: Pose(bodyPitch: -1.02, elbow: 1.55), duration: 1.0)
            ]
        case .pullUp:
            return [
                Keyframe(pose: Pose(rootLift: 0, shoulderX: -2.9, elbow: 0.6), duration: 0.9),
                Keyframe(pose: Pose(rootLift: 15, shoulderX: -2.9, elbow: 2.7), duration: 0.9)
            ]
        case .squat:
            return [
                Keyframe(pose: .idle, duration: 0.6),
                Keyframe(pose: Pose(torsoPitch: -0.35, pelvisDrop: 15, hip: 1.25, knee: 1.4), duration: 1.0),
                Keyframe(pose: .idle, duration: 1.0)
            ]
        case .curl:
            return [
                Keyframe(pose: Pose(elbow: 0.15), duration: 0.8),
                Keyframe(pose: Pose(elbow: 2.5), duration: 0.8)
            ]
        case .row:
            return [
                Keyframe(pose: Pose(torsoPitch: -0.55, elbow: 0.3), duration: 0.6),
                Keyframe(pose: Pose(torsoPitch: -0.55, elbow: 2.5), duration: 0.6),
                Keyframe(pose: Pose(torsoPitch: -0.55, elbow: 0.3), duration: 0.7),
                Keyframe(pose: .idle, duration: 0.4)
            ]
        case .bench:
            return [
                Keyframe(pose: Pose(bodyPitch: -1.45, shoulderX: -1.25, elbow: 1.7), duration: 1.0),
                Keyframe(pose: Pose(bodyPitch: -1.45, shoulderX: -1.25, elbow: 0.25), duration: 1.0)
            ]
        case .lateralRaise:
            return [
                Keyframe(pose: .idle, duration: 0.4),
                Keyframe(pose: Pose(shoulderZ: 1.35), duration: 0.9),
                Keyframe(pose: .idle, duration: 0.9)
            ]
        case .lunge:
            return [
                Keyframe(pose: .idle, duration: 0.5),
                Keyframe(pose: Pose(torsoPitch: -0.15, pelvisDrop: 10, hip: 1.3, knee: 1.4), duration: 0.9),
                Keyframe(pose: .idle, duration: 0.9)
            ]
        case .plank:
            return [Keyframe(pose: Pose(bodyPitch: -1.35), duration: 3.0)]
        case .custom:
            return [
                Keyframe(pose: Pose(shoulderX: -0.5, elbow: 0.4), duration: 1.2),
                Keyframe(pose: Pose(shoulderX: -1.3, elbow: 1.8), duration: 1.2)
            ]
        }
    }
}

final class AvatarRig {
    let scene = SCNScene()
    let root = SCNNode()
    let cameraNode = SCNNode()

    private var pelvisNode = SCNNode()
    private var spineNode = SCNNode()
    private var shoulderL = SCNNode()
    private var shoulderR = SCNNode()
    private var forearmL = SCNNode()
    private var forearmR = SCNNode()
    private var thighL = SCNNode()
    private var thighR = SCNNode()
    private var shinL = SCNNode()
    private var shinR = SCNNode()

    private var muscleNodes: [MuscleGroup: [SCNNode]] = [:]
    private var basePelvisY: CGFloat = 0
    private var highlighted: [SCNMaterial] = []
    private var barNode: SCNNode?
    private var benchNode: SCNNode?

    private let bodyH: CGFloat
    private let shoulderWidth: CGFloat
    private let glow = UIColor(hex: 0x00E5FF)

    init(measurements m: Measurements, appearance a: Appearance, fitness f: Double, faceMesh: FaceMeshData?) {
        bodyH = max(m.heightCm, 120)
        shoulderWidth = max(m.shoulderCm / .pi, bodyH * 0.15)
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(root)
        build(measurements: m, appearance: a, fitness: f, faceMesh: faceMesh)
        addLightsAndCamera()
    }

    private func build(measurements m: Measurements, appearance a: Appearance, fitness f: Double, faceMesh: FaceMeshData?) {
        let h = bodyH
        let headR = max(m.headCm / (2 * .pi), h * 0.05)
        let neckLen = h * 0.035
        let legLen = min(max(m.legCm, h * 0.30), h * 0.58)
        let torsoLen = max(h - legLen - neckLen - 2 * headR, h * 0.25)
        let shoulderW = shoulderWidth
        let waistW = max(m.waistCm / .pi, h * 0.11)
        let hipW = max(m.hipCm / .pi, h * 0.12)
        let neckR = max((m.neckCm / .pi) * 0.28, headR * 0.30)
        let chestD = max((m.chestCm / .pi) * 0.30, shoulderW * 0.30)
        let armLen = min(max(m.armCm, h * 0.35), h * 0.60)
        let bmi = m.bmi
        let thick = min(max(0.80 + (bmi - 18.5) * 0.055, 0.75), 1.70)
        let muscle = 1.0 + 0.30 * f

        let skinIndex = min(max(a.skinTone, 0), Appearance.skinTones.count - 1)
        let hairIndex = min(max(a.hairColor, 0), Appearance.hairColors.count - 1)
        let outfitIndex = min(max(a.outfitColor, 0), Appearance.outfitColors.count - 1)
        let skin = UIColor(hex: Appearance.skinTones[skinIndex].1)
        let hair = UIColor(hex: Appearance.hairColors[hairIndex].1)
        let outfit = UIColor(hex: Appearance.outfitColors[outfitIndex].1)
        let dark = UIColor(hex: 0x14181D)

        func mat(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.specular.contents = UIColor.white.withAlphaComponent(0.12)
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
        let matHair = mat(hair)
        let matOutfit = mat(outfit)
        let matDark = mat(dark)

        let footH = h * 0.04 + CGFloat(m.shoeSize - 36) * 0.06
        let legR = max(hipW * 0.17, h * 0.034) * muscle
        let thighLen = max(legLen * 0.55, h * 0.15)
        let shinLen = max(legLen - thighLen - footH, h * 0.12)
        let legX = hipW * 0.24

        var legGeos: [SCNNode] = []
        for side in [-1.0, 1.0] {
            let thigh = joint(root, v3(CGFloat(side) * legX, legLen, 0))
            let thighGeo = geo(thigh, SCNCapsule(capRadius: legR, height: thighLen), matOutfit, v3(0, -thighLen / 2, 0))
            let shin = joint(thigh, v3(0, -thighLen, 0))
            let shinGeo = geo(shin, SCNCapsule(capRadius: legR * 0.85, height: shinLen), matOutfit, v3(0, -shinLen / 2, 0))
            geo(shin, SCNBox(width: legR * 2.1, height: footH, length: legR * 3.4, chamferRadius: footH * 0.4), matDark, v3(0, -shinLen - footH / 2, legR * 1.1))
            legGeos.append(contentsOf: [thighGeo, shinGeo])
            if side < 0 { thighL = thigh; shinL = shin }
            else { thighR = thigh; shinR = shin }
        }

        let pelvisH = torsoLen * 0.24
        let abdomenH = torsoLen * 0.30
        let chestH = torsoLen * 0.40

        root.addChildNode(pelvisNode)
        pelvisNode.position = v3(0, legLen, 0)
        basePelvisY = legLen
        let pelvisGeo = geo(pelvisNode, SCNBox(width: hipW, height: pelvisH, length: hipW * 0.52 * thick, chamferRadius: pelvisH * 0.3), matOutfit, v3(0, pelvisH / 2, 0))

        pelvisNode.addChildNode(spineNode)
        let midW = (hipW + waistW) / 2
        let abdomenGeo = geo(spineNode, SCNBox(width: midW, height: abdomenH, length: midW * 0.48 * thick, chamferRadius: abdomenH * 0.3), matOutfit, v3(0, abdomenH / 2, 0))
        let chestGeo = geo(spineNode, SCNBox(width: shoulderW, height: chestH, length: chestD * thick, chamferRadius: chestH * 0.3), matOutfit, v3(0, abdomenH + chestH / 2, 0))
        geo(spineNode, SCNCylinder(radius: neckR, height: neckLen), matSkin, v3(0, abdomenH + chestH + neckLen / 2, 0))
        let headJoint = joint(spineNode, v3(0, abdomenH + chestH + neckLen + headR * 0.9, 0))
        if let faceMesh, let faceGeometry = AvatarSceneView.geometry(from: faceMesh) {
            let head = geo(headJoint, faceGeometry, matSkin, v3(0, 0, 0))
            let scale = CGFloat(2 * headR) / 0.20
            head.scale = v3(scale, scale, scale)
            head.eulerAngles = v3(0, .pi, 0)
        } else {
            geo(headJoint, SCNSphere(radius: headR), matSkin, v3(0, 0, 0))
            let hairNode = geo(headJoint, SCNSphere(radius: headR * 1.04), matHair, v3(0, headR * 0.28, -headR * 0.18))
            hairNode.scale = v3(1, 0.72, 1)
        }

        let shoulderY = abdomenH + chestH * 0.75
        let armR = max(shoulderW * 0.085, h * 0.026) * muscle
        let upperLen = armLen * 0.55
        let foreLen = armLen * 0.45

        for side in [-1.0, 1.0] {
            let shoulder = joint(spineNode, v3(CGFloat(side) * shoulderW / 2, shoulderY, 0))
            let shoulderGeo = geo(shoulder, SCNSphere(radius: armR * 1.2), matOutfit, v3(0, 0, 0))
            let upper = joint(shoulder, v3(0, -armR * 0.6, 0))
            let upperGeo = geo(upper, SCNCapsule(capRadius: armR, height: upperLen), matSkin, v3(0, -upperLen / 2, 0))
            let forearm = joint(upper, v3(0, -upperLen, 0))
            let foreGeo = geo(forearm, SCNCapsule(capRadius: armR * 0.85, height: foreLen), matSkin, v3(0, -foreLen / 2, 0))
            geo(forearm, SCNSphere(radius: armR * 0.95), matSkin, v3(0, -foreLen - armR * 0.4, 0))
            if side < 0 {
                shoulderL = shoulder
                forearmL = forearm
            } else {
                shoulderR = shoulder
                forearmR = forearm
            }
            muscleNodes[.spalle, default: []].append(shoulderGeo)
            muscleNodes[.braccia, default: []].append(contentsOf: [upperGeo, foreGeo])
        }

        muscleNodes[.petto] = [chestGeo]
        muscleNodes[.dorso] = [chestGeo, abdomenGeo]
        muscleNodes[.core] = [abdomenGeo, pelvisGeo]
        muscleNodes[.gambe] = legGeos
        muscleNodes[.cardio] = [chestGeo] + legGeos

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
        key.light?.intensity = 1100
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
        camera.fieldOfView = 42
        cameraNode.camera = camera
        cameraNode.position = v3(0, h * 0.60, h * 1.85)
        let target = SCNNode()
        target.position = v3(0, h * 0.47, 0)
        cameraNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(target)
    }

    func applyPose(_ p: Pose) {
        root.eulerAngles = v3(p.bodyPitch, 0, 0)
        root.position.y = Float(p.rootLift)
        pelvisNode.position.y = Float(basePelvisY - p.pelvisDrop)
        spineNode.eulerAngles = v3(p.torsoPitch, 0, 0)
        shoulderL.eulerAngles = v3(p.shoulderX, 0, p.shoulderZ)
        shoulderR.eulerAngles = v3(p.shoulderX, 0, -p.shoulderZ)
        forearmL.eulerAngles = v3(-p.elbow, 0, 0)
        forearmR.eulerAngles = v3(-p.elbow, 0, 0)
        thighL.eulerAngles = v3(-p.hip, 0, 0)
        thighR.eulerAngles = v3(-p.hip, 0, 0)
        shinL.eulerAngles = v3(p.knee, 0, 0)
        shinR.eulerAngles = v3(p.knee, 0, 0)
    }

    private func poseAt(_ t: CGFloat, keys: [Keyframe], total: CGFloat) -> Pose {
        var time = t.truncatingRemainder(dividingBy: max(total, 0.001))
        if time < 0 { time += total }
        var acc: Double = 0
        for (index, key) in keys.enumerated() {
            if time < acc + key.duration || index == keys.count - 1 {
                let local = min(max(CGFloat((Double(time) - acc) / max(key.duration, 0.001)), 0), 1)
                let eased = local * local * (3 - 2 * local)
                let previous = index > 0 ? keys[index - 1].pose : .idle
                return lerpPose(previous, key.pose, eased)
            }
            acc += key.duration
        }
        return keys.last?.pose ?? .idle
    }

    func play(_ movement: MovementType, muscles: [MuscleGroup]) {
        stop()
        setHighlight(muscles)
        showProp(movement)
        let keys = Keyframes.forMovement(movement)
        let total = max(keys.reduce(0.0) { $0 + $1.duration }, 0.001)
        let action = SCNAction.customAction(duration: total) { [weak self] _, elapsed in
            guard let self else { return }
            self.applyPose(self.poseAt(CGFloat(elapsed), keys: keys, total: CGFloat(total)))
        }
        root.runAction(SCNAction.repeatForever(action), forKey: "demo")
    }

    func stop() {
        root.removeAction(forKey: "demo")
        root.removeAction(forKey: "pulse")
        applyPose(.idle)
        clearHighlight()
        barNode?.removeFromParentNode()
        barNode = nil
        benchNode?.removeFromParentNode()
        benchNode = nil
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

    private func showProp(_ movement: MovementType) {
        if movement == .pullUp {
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(hex: 0x2A2F36)
            material.emission.contents = glow.withAlphaComponent(0.6)
            let bar = SCNNode(geometry: SCNCylinder(radius: 1.4, height: shoulderWidth * 1.8))
            bar.geometry?.firstMaterial = material
            bar.eulerAngles = v3(0, 0, .pi / 2)
            bar.position = v3(0, bodyH * 1.0, 0)
            root.addChildNode(bar)
            barNode = bar
        }
        if movement == .bench {
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(hex: 0x1A1E24)
            let bench = SCNNode(geometry: SCNBox(width: shoulderWidth * 1.5, height: 5, length: bodyH * 0.55, chamferRadius: 1.5))
            bench.geometry?.firstMaterial = material
            bench.position = v3(0, bodyH * 0.20, bodyH * 0.30)
            root.addChildNode(bench)
            benchNode = bench
        }
    }
}
