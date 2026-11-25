import ARKit
import Foundation
import SwiftUI

struct FaceScanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var captured = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if ARFaceTrackingConfiguration.isSupported {
                    if captured || store.faceMesh != nil {
                        Label("Viso acquisito: l'avatar 3D usa la tua mesh reale", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Guarda la fotocamera frontale e resta fermo: acquisisco la geometria del viso con TrueDepth. La scansione resta solo su questo iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    FaceScanView(captured: $captured)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(height: 380)
                    if store.faceMesh != nil {
                        Button("Rimuovi scansione viso", role: .destructive) {
                            store.clearFaceMesh()
                            captured = false
                        }
                    }
                } else {
                    Text("Questo iPhone non ha la fotocamera TrueDepth: la scansione viso non è disponibile. L'avatar userà la testa parametrica dalle tue misure.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Scansione viso")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

struct FaceScanView: UIViewRepresentable {
    @Environment(AppStore.self) private var store
    @Binding var captured: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        context.coordinator.onCapture = { mesh in
            store.setFaceMesh(mesh)
            captured = true
        }
        let configuration = ARFaceTrackingConfiguration()
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        var onCapture: ((FaceMeshData) -> Void)?

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard let onCapture,
                  let anchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
            let geometry = anchor.geometry
            var positions: [Float] = []
            positions.reserveCapacity(geometry.vertices.count * 3)
            for v in geometry.vertices {
                positions.append(contentsOf: [v.x, v.y, v.z])
            }
            let mesh = FaceMeshData(
                positions: positions,
                normals: [],
                indices: geometry.triangleIndices.map { Int32($0) }
            )
            onCapture(mesh)
            self.onCapture = nil
        }
    }
}
