import ARKit
import AVFoundation
import Foundation
import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var showEditor = false
    @State private var showFaceScan = false
    @State private var faceAlert: String?

    private var demoExercise: Exercise? {
        store.exercises.first { $0.id == store.demoExerciseId } ?? store.exercises.first
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                let avatarH = min(320, max(230, geo.size.height * 0.36))
                VStack(spacing: 12) {
                    ZStack {
                        if store.use3D {
                            AvatarSceneView(
                                measurements: store.measurements,
                                appearance: store.appearance,
                                fitness: store.fitness,
                                faceMesh: store.faceMesh,
                                facePhoto: store.faceImage,
                                demoMovement: demoExercise?.movement,
                                demoMuscles: demoExercise.map { [$0.muscle] } ?? []
                            )
                        } else {
                            // il disegno 2D è una VISTA alternativa, non un
                            // sottofondo: sotto al 3D si vedeva e non ruotava
                            Avatar2DView(
                                measurements: store.measurements,
                                appearance: store.appearance,
                                fitness: store.fitness,
                                facePhoto: store.faceImage
                            )
                        }
                    }
                    .frame(height: avatarH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Label("Ruota 360° · zoom", systemImage: "rotate.3d")
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(12)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            haptic(.medium)
                            store.use3D.toggle()
                        } label: {
                            Label(store.use3D ? "2D" : "3D", systemImage: store.use3D ? "square.fill" : "cube.fill")
                                .font(.caption2.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .padding(12)
                        .accessibilityLabel("Cambia vista 3D/2D")
                    }
                    .padding(.horizontal)

                    AggiornamentiBanner()
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        StatChip(title: "BMI", value: String(format: "%.1f", store.measurements.bmi), icon: "scalemass.fill", tint: Theme.accent)
                        StatChip(title: "Peso", value: "\(Int(store.measurements.weightKg)) kg", icon: "dumbbell.fill", tint: Theme.gold)
                        StatChip(title: "Forma", value: "\(Int(store.fitness * 100))%", icon: "figure.run", tint: Theme.accent)
                    }
                    .padding(.horizontal)

                    VStack(spacing: 10) {
                        Button {
                            haptic(.medium)
                            showEditor = true
                        } label: {
                            Label("Le mie misure", systemImage: "ruler.fill")
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)

                        Button {
                            startFaceScan()
                        } label: {
                            Label(store.faceMesh == nil ? "Scansiona il viso (TrueDepth)" : "Viso scansionato ✓", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.gold)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Demo 3D esercizio").font(.headline)
                        Picker("Esercizio", selection: Binding(
                            get: { demoExercise?.id },
                            set: { id in
                                if let id {
                                    store.demoExerciseId = id
                                    haptic()
                                }
                            }
                        )) {
                            ForEach(store.exercises) { ex in
                                Text(ex.name).tag(Optional(ex.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accent)
                        if let demoExercise {
                            Text("Muscolo target: \(demoExercise.muscle.rawValue) · \(demoExercise.movement.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .card()
                    .padding(.horizontal)

                    PhotoCard()
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("AVATAR OS")
        .background(Color.black)
        .sheet(isPresented: $showEditor) { MeasurementsEditorView() }
        .sheet(isPresented: $showFaceScan) { FaceScanSheet() }
        .alert("Scansione viso", isPresented: Binding(
            get: { faceAlert != nil },
            set: { if !$0 { faceAlert = nil } }
        )) {
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(faceAlert ?? "")
        }
    }

    private func startFaceScan() {
        haptic()
        guard ARFaceTrackingConfiguration.isSupported else {
            faceAlert = "Questo iPhone non ha la fotocamera frontale TrueDepth (serve iPhone X o successivo, esclusi i modelli SE): la scansione del viso non è disponibile. L'avatar 3D usa la testa parametrica calibrata sulla misura 'Testa' in Le mie misure."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showFaceScan = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showFaceScan = true
                    } else {
                        faceAlert = "Permesso fotocamera negato: senza accesso alla fotocamera frontale la scansione viso non può partire."
                    }
                }
            }
        case .denied, .restricted:
            faceAlert = "Permesso fotocamera non concesso. Vai in Impostazioni → AvatarFit → Fotocamera e attivalo, poi riprova."
        @unknown default:
            faceAlert = "Stato permesso fotocamera non gestito: riprova o controlla Impostazioni → AvatarFit → Fotocamera."
        }
    }
}

struct StatChip: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(value)
                .font(.headline.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
    }
}
