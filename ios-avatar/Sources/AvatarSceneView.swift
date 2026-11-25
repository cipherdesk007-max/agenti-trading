import Foundation
import SwiftUI
import SceneKit

struct AvatarSceneView: UIViewRepresentable {
    var measurements: Measurements
    var appearance: Appearance
    var fitness: Double
    var faceMesh: FaceMeshData?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = Self.buildScene(
            measurements: measurements,
            appearance: appearance,
            fitness: fitness,
            faceMesh: faceMesh
        )
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if context.lastMeasurements != measurements
            || context.lastAppearance != appearance
            || abs(context.lastFitness - fitness) > 0.001
            || context.lastFaceMesh != nil && faceMesh == nil
            || context.lastFaceMesh == nil && faceMesh != nil {
            uiView.scene = Self.buildScene(
                measurements: measurements,
                appearance: appearance,
                fitness: fitness,
                faceMesh: faceMesh
            )
            context.lastMeasurements = measurements
            context.lastAppearance = appearance
            context.lastFitness = fitness
            context.lastFaceMesh = faceMesh
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastMeasurements: Measurements?
        var lastAppearance: Appearance?
        var lastFitness: Double = -1
        var lastFaceMesh: FaceMeshData?
    }

    static func geometry(from face: FaceMeshData) -> SCNGeometry? {
        guard face.positions.count % 3 == 0,
              face.positions.count == face.normals.count,
              !face.indices.isEmpty else { return nil }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(face.positions.count / 3)
        for i in stride(from: 0, to: face.positions.count, by: 3) {
            vertices.append(SCNVector3(face.positions[i], face.positions[i + 1], face.positions[i + 2]))
        }
        var normals: [SCNVector3] = []
        normals.reserveCapacity(face.normals.count / 3)
        for i in stride(from: 0, to: face.normals.count, by: 3) {
            normals.append(SCNVector3(face.normals[i], face.normals[i + 1], face.normals[i + 2]))
        }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: face.indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }

    static func buildScene(measurements m: Measurements, appearance a: Appearance, fitness f: Double, faceMesh: FaceMeshData?) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.black

        let h = max(m.heightCm, 120)
        let headR = max(m.headCm / (2 * .pi), h * 0.05)
        let neckLen = h * 0.035
        let legLen = min(max(m.legCm, h * 0.30), h * 0.58)
        let torsoLen = max(h - legLen - neckLen - 2 * headR, h * 0.25)
        let shoulderW = max(m.shoulderCm / .pi, h * 0.15)
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

        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        func mat(_ color: UIColor, emission: UIColor? = nil) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.specular.contents = UIColor.white.withAlphaComponent(0.12)
            if let emission {
                material.emission.contents = emission
                material.emissionIntensity = 1.5
            }
            return material
        }

        func add(_ geometry: SCNGeometry, _ material: SCNMaterial, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNNode {
            let node = SCNNode(geometry: geometry)
            node.geometry?.firstMaterial = material
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
            return node
        }

        let footH = h * 0.04 + CGFloat(m.shoeSize - 36) * 0.06
        let legR = max(hipW * 0.17, h * 0.034) * muscle
        let legLenC = max(legLen - footH - legR, h * 0.1)
        let legY = footH + legR + legLenC / 2
        let legX = hipW * 0.24

        for side in [-1.0, 1.0] {
            add(SCNCapsule(radius: legR, height: legLenC), mat(outfit), CGFloat(side) * legX, legY, 0)
            add(SCNBox(width: legR * 2.1, height: footH, depth: legR * 3.4, chamferRadius: footH * 0.4), mat(dark), CGFloat(side) * legX, footH / 2, legR * 1.1)
        }

        let pelvisH = torsoLen * 0.24
        let abdomenH = torsoLen * 0.30
        let chestH = torsoLen * 0.40
        add(SCNBox(width: hipW, height: pelvisH, depth: hipW * 0.52 * thick, chamferRadius: pelvisH * 0.3), mat(outfit), 0, legLen + pelvisH / 2, 0)
        let midW = (hipW + waistW) / 2
        add(SCNBox(width: midW, height: abdomenH, depth: midW * 0.48 * thick, chamferRadius: abdomenH * 0.3), mat(outfit), 0, legLen + pelvisH + abdomenH / 2, 0)
        let chestY = legLen + pelvisH + abdomenH + chestH / 2
        add(SCNBox(width: shoulderW, height: chestH, depth: chestD * thick, chamferRadius: chestH * 0.3), mat(outfit), 0, chestY, 0)

        let torsoTop = legLen + pelvisH + abdomenH + chestH
        add(SCNCylinder(radius: neckR, height: neckLen), mat(skin), 0, torsoTop + neckLen / 2, 0)
        let headY = torsoTop + neckLen + headR * 0.9
        if let faceMesh, let faceGeometry = geometry(from: faceMesh) {
            let head = add(faceGeometry, mat(skin), 0, headY, 0)
            let scale = CGFloat(2 * headR) / 0.20
            head.scale = SCNVector3(scale, scale, scale)
            head.eulerAngles.y = .pi
        } else {
            add(SCNSphere(radius: headR), mat(skin), 0, headY, 0)
            let hairNode = add(SCNSphere(radius: headR * 1.04), mat(hair), 0, headY + headR * 0.28, -headR * 0.18)
            hairNode.scale = SCNVector3(1, 0.72, 1)
        }

        let jointY = torsoTop - chestH * 0.25
        let armR = max(shoulderW * 0.085, h * 0.026) * muscle
        for side in [-1.0, 1.0] {
            let x = CGFloat(side) * (shoulderW / 2 + armR * 0.55)
            add(SCNSphere(radius: armR * 1.2), mat(outfit), CGFloat(side) * shoulderW / 2, jointY, 0)
            let arm = add(SCNCapsule(radius: armR, height: armLen), mat(skin), x, jointY - armLen / 2, 0)
            arm.eulerAngles.z = CGFloat(side) * -0.10
            add(SCNSphere(radius: armR * 0.95), mat(skin), x, jointY - armLen - armR * 0.3, 0)
        }

        let platformR = max(shoulderW, hipW) * 1.25 + 8
        add(SCNCylinder(radius: platformR, height: 1.6), mat(dark, emission: UIColor(hex: 0x2EB8FF)), 0, -0.8, 0)
        let ring = add(SCNTorus(ringRadius: platformR, tubeRadius: 0.5), mat(dark, emission: UIColor(hex: 0x2EB8FF)), 0, 0.2, 0)
        let spin = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 6)
        ring.runAction(.repeatForever(spin))

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 1100
        key.position = SCNVector3(h * 0.9, h * 1.7, h * 1.4)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = UIColor(hex: 0x2EB8FF)
        rim.light?.intensity = 650
        rim.position = SCNVector3(-h * 0.8, h * 0.9, -h * 1.6)
        scene.rootNode.addChildNode(rim)

        let camera = SCNCamera()
        camera.fieldOfView = 42
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, h * 0.60, h * 1.85)
        let target = SCNNode()
        target.position = SCNVector3(0, h * 0.47, 0)
        camNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(camNode)
        scene.rootNode.addChildNode(target)
        scene.pointOfView = camNode

        return scene
    }
}
