import Foundation
import SwiftUI

struct WorkoutView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false
    @State private var restTotal = 90
    @State private var restRemaining = 90
    @State private var restRunning = false

    private var sortedWorkouts: [WorkoutEntry] {
        store.workouts.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                formaCard
                timerCard
                Button {
                    showAdd = true
                } label: {
                    Label("Aggiungi allenamento", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                historySection
            }
            .padding()
        }
        .navigationTitle("Workout")
        .background(Color.black)
        .sheet(isPresented: $showAdd) { AddWorkoutView() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if restRunning && restRemaining > 0 {
                restRemaining -= 1
                if restRemaining == 0 { restRunning = false }
            }
        }
    }

    private var formaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Forma fisica").font(.headline)
                Spacer()
                Text("\(Int(store.fitness * 100))%").bold()
            }
            ProgressView(value: store.fitness)
                .tint(Theme.accent)
            Text("Ultimi 30 giorni di allenamento: alimenta la muscolatura dell'avatar 3D nella Home.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var timerCard: some View {
        VStack(spacing: 12) {
            Text("Recupero tra serie").font(.headline)
            Text(String(format: "%02d:%02d", restRemaining / 60, restRemaining % 60))
                .font(.system(size: 46, design: .rounded).bold())
                .monospacedDigit()
            Stepper("Durata: \(restTotal) s", value: $restTotal, in: 15...600, step: 15)
                .disabled(restRunning)
            HStack(spacing: 12) {
                Button(restRunning ? "Pausa" : (restRemaining == restTotal ? "Avvia" : "Riprendi")) {
                    restRunning.toggle()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(restRemaining == 0)
                Button("Azzera") {
                    restRunning = false
                    restRemaining = restTotal
                }
                .buttonStyle(.bordered)
                .disabled(restRunning)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
        .onChange(of: restTotal) { _, newValue in
            if !restRunning { restRemaining = newValue }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storico").font(.headline).padding(.horizontal, 4)
            if sortedWorkouts.isEmpty {
                Text("Nessun allenamento registrato. Tocca 'Aggiungi allenamento'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                VStack(spacing: 8) {
                    ForEach(sortedWorkouts) { w in
                        HStack {
                            Image(systemName: w.kind == .pesi ? "dumbbell.fill" : "figure.run")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.name).font(.subheadline.bold())
                                Text(w.kind == .pesi ? "\(Int(w.weightKg)) kg × \(w.reps) rip." : "\(w.durationMin) min cardio")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(w.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contextMenu {
                            Button("Elimina", role: .destructive) {
                                store.workouts.removeAll { $0.id == w.id }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AddWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: WorkoutKind = .pesi
    @State private var weight = 40.0
    @State private var reps = 10
    @State private var duration = 30

    var body: some View {
        NavigationStack {
            Form {
                TextField("Esercizio (es. squat, corsa...)", text: $name)
                Picker("Tipo", selection: $kind) {
                    ForEach(WorkoutKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                if kind == .pesi {
                    Stepper("Peso: \(Int(weight)) kg", value: $weight, in: 0...400, step: 2.5)
                    Stepper("Ripetizioni: \(reps)", value: $reps, in: 1...200)
                } else {
                    Stepper("Durata: \(duration) min", value: $duration, in: 1...300)
                }
            }
            .navigationTitle("Nuovo allenamento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let clean = name.trimmingCharacters(in: .whitespaces)
                        guard !clean.isEmpty else { return }
                        store.workouts.append(WorkoutEntry(
                            date: Date(),
                            name: clean,
                            kind: kind,
                            weightKg: weight,
                            reps: reps,
                            durationMin: duration
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
