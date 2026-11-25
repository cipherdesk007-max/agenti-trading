import Foundation
import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var showEditor = false
    @State private var showFaceScan = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack(alignment: .topTrailing) {
                    AvatarSceneView(
                        measurements: store.measurements,
                        appearance: store.appearance,
                        fitness: store.fitness,
                        faceMesh: store.faceMesh
                    )
                    .frame(height: 440)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Label("Ruota 360° · pizzica per zoom", systemImage: "rotate.3d")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(12)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    StatChip(title: "BMI", value: String(format: "%.1f", store.measurements.bmi), icon: "scalemass.fill")
                    StatChip(title: "Peso", value: "\(Int(store.measurements.weightKg)) kg", icon: "dumbbell.fill")
                    StatChip(title: "Forma", value: "\(Int(store.fitness * 100))%", icon: "figure.run")
                }
                .padding(.horizontal)

                VStack(spacing: 10) {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Le mie misure", systemImage: "ruler.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Button {
                        showFaceScan = true
                    } label: {
                        Label(store.faceMesh == nil ? "Scansiona il viso (TrueDepth)" : "Viso scansionato ✓", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent2)
                }
                .padding(.horizontal)

                PhotoCard()
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Avatar 3D")
        .background(Color.black)
        .sheet(isPresented: $showEditor) { MeasurementsEditorView() }
        .sheet(isPresented: $showFaceScan) { FaceScanSheet() }
    }
}

struct StatChip: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.headline.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
