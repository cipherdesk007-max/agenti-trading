import Foundation
import SwiftUI

struct CustomTrackersView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.trackers) { tracker in
                    TrackerCard(tracker: tracker)
                }
                Button {
                    showAdd = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.largeTitle)
                        Text("Nuovo tracker")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .foregroundStyle(Theme.accent)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding()
        }
        .navigationTitle("Tracker personali")
        .background(Color.black)
        .sheet(isPresented: $showAdd) { AddTrackerView() }
    }
}

struct TrackerCard: View {
    @Environment(AppStore.self) private var store
    let tracker: CustomTracker

    private var value: Double { store.todayValue(tracker) }
    private var progress: Double {
        tracker.goal > 0 ? min(1, value / tracker.goal) : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(tracker.symbol)
                .font(.title2)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(progress >= 1 ? .green : Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(formatNumber(value))
                        .font(.headline.bold())
                        .monospacedDigit()
                    Text(tracker.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            Text(tracker.name)
                .font(.subheadline.bold())
            Text("obiettivo \(formatNumber(tracker.goal)) \(tracker.unit)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    store.bump(tracker.id, by: -tracker.step)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .disabled(value <= 0)
                Button {
                    store.bump(tracker.id, by: tracker.step)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            Button("Azzera oggi") { store.resetTracker(tracker.id) }
            Button("Elimina", role: .destructive) { store.removeTracker(tracker.id) }
        }
    }

    private func formatNumber(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(v))" }
        return String(format: "%.2f", v)
    }
}

struct AddTrackerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "⭐"
    @State private var unit = "unità"
    @State private var goal = 1.0

    private let templates: [(String, String, String, Double, Double)] = [
        ("Acqua", "💧", "L", 2, 0.25),
        ("Sonno", "😴", "h", 8, 0.5),
        ("Dieta", "🍏", "kcal", 2000, 100),
        ("Passi", "🚶", "passi", 10000, 500),
        ("Lettura", "📖", "min", 30, 5)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Modelli rapidi") {
                    ForEach(templates, id: \.0) { template in
                        Button {
                            store.trackers.append(CustomTracker(
                                name: template.0,
                                symbol: template.1,
                                unit: template.2,
                                goal: template.3,
                                step: template.4
                            ))
                            dismiss()
                        } label: {
                            HStack {
                                Text(template.1)
                                Text(template.0)
                                Spacer()
                                Text("obiettivo \(Int(template.3)) \(template.2)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Personalizzato") {
                    TextField("Nome", text: $name)
                    TextField("Emoji", text: $symbol)
                    TextField("Unità", text: $unit)
                    Stepper("Obiettivo: \(Int(goal))", value: $goal, in: 1...100000, step: 1)
                    Button("Crea tracker") {
                        let clean = name.trimmingCharacters(in: .whitespaces)
                        guard !clean.isEmpty else { return }
                        store.trackers.append(CustomTracker(
                            name: clean,
                            symbol: symbol.isEmpty ? "⭐" : symbol,
                            unit: unit,
                            goal: goal
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Nuovo tracker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}
