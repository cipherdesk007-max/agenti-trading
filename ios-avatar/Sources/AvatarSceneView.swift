import Foundation
import SwiftUI
@preconcurrency import SceneKit

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
}
