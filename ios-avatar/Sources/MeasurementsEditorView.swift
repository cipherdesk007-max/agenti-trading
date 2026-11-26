import Foundation
import SwiftUI

struct MeasurementsEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Corpo") {
                    measureRow("Altezza", unit: "cm", value: m(\.heightCm), range: 120...220, step: 1)
                    measureRow("Peso", unit: "kg", value: m(\.weightKg), range: 35...200, step: 1)
                    Stepper("Scarpe EU \(store.measurements.shoeSize)", value: mInt(\.shoeSize), in: 35...50)
                    measureRow("Testa", unit: "cm", value: m(\.headCm), range: 48...66, step: 1)
                    measureRow("Collo", unit: "cm", value: m(\.neckCm), range: 28...55, step: 1)
                    measureRow("Spalle", unit: "cm", value: m(\.shoulderCm), range: 80...160, step: 1)
                    measureRow("Petto", unit: "cm", value: m(\.chestCm), range: 60...150, step: 1)
                    measureRow("Braccia", unit: "cm", value: m(\.armCm), range: 40...90, step: 1)
                    measureRow("Vita", unit: "cm", value: m(\.waistCm), range: 50...140, step: 1)
                    measureRow("Fianchi", unit: "cm", value: m(\.hipCm), range: 60...150, step: 1)
                    measureRow("Gambe", unit: "cm", value: m(\.legCm), range: 60...130, step: 1)
                }
                Section("Aspetto") {
                    swatchRow("Pelle", options: Appearance.skinTones, selection: a(\.skinTone))
                    swatchRow("Capelli", options: Appearance.hairColors, selection: a(\.hairColor))
                    swatchRow("Outfit", options: Appearance.outfitColors, selection: a(\.outfitColor))
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

    private func m(_ keyPath: WritableKeyPath<Measurements, Double>) -> Binding<Double> {
        Binding(get: { store.measurements[keyPath: keyPath] },
                set: { store.measurements[keyPath: keyPath] = $0 })
    }

    private func mInt(_ keyPath: WritableKeyPath<Measurements, Int>) -> Binding<Int> {
        Binding(get: { store.measurements[keyPath: keyPath] },
                set: { store.measurements[keyPath: keyPath] = $0 })
    }

    private func a(_ keyPath: WritableKeyPath<Appearance, Int>) -> Binding<Int> {
        Binding(get: { store.appearance[keyPath: keyPath] },
                set: { store.appearance[keyPath: keyPath] = $0 })
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
