import Foundation
import SwiftUI

struct MeasurementsEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Corpo") {
                    measureRow("Altezza", unit: "cm", value: $store.measurements.heightCm, range: 120...220, step: 1)
                    measureRow("Peso", unit: "kg", value: $store.measurements.weightKg, range: 35...200, step: 1)
                    Stepper("Scarpe EU \(store.measurements.shoeSize)", value: $store.measurements.shoeSize, in: 35...50)
                    measureRow("Testa", unit: "cm", value: $store.measurements.headCm, range: 48...66, step: 1)
                    measureRow("Collo", unit: "cm", value: $store.measurements.neckCm, range: 28...55, step: 1)
                    measureRow("Spalle", unit: "cm", value: $store.measurements.shoulderCm, range: 80...160, step: 1)
                    measureRow("Petto", unit: "cm", value: $store.measurements.chestCm, range: 60...150, step: 1)
                    measureRow("Braccia", unit: "cm", value: $store.measurements.armCm, range: 40...90, step: 1)
                    measureRow("Vita", unit: "cm", value: $store.measurements.waistCm, range: 50...140, step: 1)
                    measureRow("Fianchi", unit: "cm", value: $store.measurements.hipCm, range: 60...150, step: 1)
                    measureRow("Gambe", unit: "cm", value: $store.measurements.legCm, range: 60...130, step: 1)
                }
                Section("Aspetto") {
                    swatchRow("Pelle", options: Appearance.skinTones, selection: $store.appearance.skinTone)
                    swatchRow("Capelli", options: Appearance.hairColors, selection: $store.appearance.hairColor)
                    swatchRow("Outfit", options: Appearance.outfitColors, selection: $store.appearance.outfitColor)
                }
                Section {
                    Text("Il modello 3D si aggiorna in tempo reale a ogni modifica.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Le mie misure")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func measureRow(_ title: String, unit: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").bold()
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.accent)
        }
    }

    private func swatchRow(_ title: String, options: [(String, UInt32)], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            HStack(spacing: 10) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Circle()
                        .fill(hexColor(option.1))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Circle()
                                .stroke(selection.wrappedValue == index ? Color.white : Color.clear, lineWidth: 3)
                        }
                        .onTapGesture { selection.wrappedValue = index }
                        .accessibilityLabel(option.0)
                }
            }
        }
    }
}
