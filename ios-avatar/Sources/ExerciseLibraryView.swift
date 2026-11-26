import Foundation
import SwiftUI

struct ExerciseLibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false
    @State private var showSession = false
    @State private var istruzioniEsercizio: Exercise?

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
        .sheet(item: $istruzioniEsercizio) { ex in
            IstruzioniEsercizioView(exercizio: ex)
        }
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
                haptic()
                istruzioniEsercizio = ex
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.gold)
            }
            .accessibilityLabel("Come si esegue")
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

/// Guida di esecuzione: dizionario standard del movimento + note personali.
struct IstruzioniEsercizioView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let exercizio: Exercise

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let ist = exercizio.movement.istruzioniStandardi {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Muscoli coinvolti", systemImage: "figure.strengthtraining.functional")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text(ist.muscoli).font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Esecuzione", systemImage: "list.number")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            ForEach(Array(ist.passi.enumerated()), id: \.offset) { i, passo in
                                Text("\(i + 1). \(passo)")
                                    .font(.subheadline)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Respirazione", systemImage: "wind")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text(ist.respirazione).font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Errori da evitare", systemImage: "exclamationmark.triangle")
                                .font(.caption.bold()).foregroundStyle(Theme.gold)
                            ForEach(ist.erroriComuni, id: \.self) { errore in
                                Text("• \(errore)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Movimento libero", systemImage: "figure.jumprope")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            Text("Questo esercizio non ha una guida standard: scrivi qui sotto come lo esegui tu, così la scheda resta nella libreria.")
                                .font(.subheadline)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Le mie note", systemImage: "square.and.pencil")
                            .font(.caption.bold()).foregroundStyle(Theme.accent)
                        TextField("Come lo esegui tu, appunti, riferimenti...", text: legameNota, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle(exercizio.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto") { dismiss() }
                }
            }
        }
    }

    /// Lega il campo alle note dell'esercizio dentro lo store (cercato per id,
    /// perché la copia ricevuta nel sheet non si aggiorna da sola).
    private var legameNota: Binding<String> {
        Binding(
            get: {
                store.exercises.first { $0.id == exercizio.id }?.note ?? ""
            },
            set: { nuovo in
                if let i = store.exercises.firstIndex(where: { $0.id == exercizio.id }) {
                    store.exercises[i].note = nuovo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nuovo
                }
            }
        )
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
    @State private var note = ""

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
                Section("Come si esegue (opzionale)") {
                    TextField("Note su esecuzione, appunti, riferimenti...", text: $note, axis: .vertical)
                        .lineLimit(2...5)
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
                            custom: true,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
