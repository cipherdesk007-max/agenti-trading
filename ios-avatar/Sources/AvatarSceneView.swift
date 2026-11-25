import Foundation
import SwiftUI
import SceneKit

struct AvatarSceneView: UIViewRepresentable {
    var measurements: Measurements
    var appearance: Appearance
    var fitness: Double
    var faceMesh: FaceMeshData?
    var demoMovement: MovementType?
    var demoMuscles: [MuscleGroup]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        let rig = AvatarRig(
            measurements: measurements,
            appearance: appearance,
            fitness: fitness,
            faceMesh: faceMesh
        )
        context.coordinator.rig = rig
        view.scene = rig.scene
        view.pointOfView = rig.cameraNode
        if let movement = demoMovement {
            rig.play(movement, muscles: demoMuscles)
            context.coordinator.lastMovement = movement
            context.coordinator.lastMuscles = demoMuscles
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        let signature = "\(measurements)|\(appearance)|\(fitness)|face:\(faceMesh != nil)"
        if signature != c.lastSignature {
            let rig = AvatarRig(
                measurements: measurements,
                appearance: appearance,
                fitness: fitness,
                faceMesh: faceMesh
            )
            c.rig = rig
            uiView.scene = rig.scene
            uiView.pointOfView = rig.cameraNode
            c.lastSignature = signature
            if let movement = demoMovement {
                rig.play(movement, muscles: demoMuscles)
            }
            c.lastMovement = demoMovement
            c.lastMuscles = demoMuscles
        } else if demoMovement != c.lastMovement {
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
        var rig: AvatarRig?
        var lastSignature = ""
        var lastMovement: MovementType?
        var lastMuscles: [MuscleGroup] = []
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
}
