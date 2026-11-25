import Foundation
import SwiftUI

struct ExerciseLibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false
    @State private var showSession = false

    var body: some View {
        List {
            ForEach(MuscleGroup.allCases, id: \.self) { group in
                let items = store.exercises.filter { $0.muscle == group }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { ex in
                            exerciseRow(ex)
                        }
                    } header: {
                        Text(group.rawValue.uppercased())
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Libreria esercizi")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    haptic(.medium)
                    showAdd = true
                } label: {
                    Label("Crea nuovo esercizio", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.sessionIds.isEmpty {
                Button {
                    haptic(.medium)
                    showSession = true
                } label: {
                    Label("Avvia workout · \(store.sessionIds.count) esercizi", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding()
                .background(.black)
            }
        }
        .sheet(isPresented: $showAdd) { AddExerciseView() }
        .sheet(isPresented: $showSession) { ActiveWorkoutView(ids: store.sessionIds) }
    }

    private func exerciseRow(_ ex: Exercise) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name).font(.subheadline.bold())
                Text("\(ex.equipment) · \(ex.movement.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(ex.defaultSets)×\(ex.defaultReps)" + (ex.defaultWeight > 0 ? " · \(Int(ex.defaultWeight)) kg" : "") + (ex.best1RM > 0 ? " · 1RM \(Int(ex.best1RM)) kg" : ""))
                    .font(.caption2)
                    .foregroundStyle(Theme.gold)
            }
            Spacer()
            Button {
                store.demoExerciseId = ex.id
                haptic()
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Demo 3D in Home")
            Button {
                store.toggleSession(ex.id)
            } label: {
                Image(systemName: store.sessionIds.contains(ex.id) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(store.sessionIds.contains(ex.id) ? .green : .secondary)
            }
            .accessibilityLabel("Aggiungi alla sessione")
        }
    }
}

struct AddExerciseView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var muscle: MuscleGroup = .petto
    @State private var equipment = "Manubri"
    @State private var movement: MovementType = .custom
    @State private var sets = 3
    @State private var reps = 10
    @State private var weight = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Esercizio") {
                    TextField("Nome (es. trazioni al cavo...)", text: $name)
                    Picker("Gruppo muscolare", selection: $muscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Attrezzatura", text: $equipment)
                    Picker("Movimento 3D", selection: $movement) {
                        ForEach(MovementType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Schema di default") {
                    Stepper("Serie: \(sets)", value: $sets, in: 1...10)
                    Stepper("Ripetizioni: \(reps)", value: $reps, in: 1...100)
                    Stepper("Carico: \(Int(weight)) kg", value: $weight, in: 0...400, step: 2.5)
                }
            }
            .navigationTitle("Nuovo esercizio")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") {
                        let clean = name.trimmingCharacters(in: .whitespaces)
                        guard !clean.isEmpty else { return }
                        haptic(.medium)
                        store.exercises.append(Exercise(
                            name: clean,
                            muscle: muscle,
                            equipment: equipment,
                            movement: movement,
                            defaultSets: sets,
                            defaultReps: reps,
                            defaultWeight: weight,
                            custom: true
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
