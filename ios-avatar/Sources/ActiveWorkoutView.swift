import Foundation
import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ids: [UUID]

    @State private var index = 0
    @State private var setNumber = 1
    @State private var repsDone = 0
    @State private var weight: Double = 0
    @State private var restTotal = 90
    @State private var restRemaining = 0
    @State private var resting = false
    @State private var loggedCount = 0

    private var current: Exercise? {
        guard ids.indices.contains(index) else { return nil }
        return store.exercises.first { $0.id == ids[index] }
    }

    private var oneRM: Double {
        epley1RM(weight, max(repsDone, 1))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let ex = current {
                        AvatarSceneView(
                            measurements: store.measurements,
                            appearance: store.appearance,
                            fitness: store.fitness,
                            faceMesh: store.faceMesh,
                            demoMovement: ex.movement,
                            demoMuscles: [ex.muscle]
                        )
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        exerciseCard(ex)
                        controlsCard(ex)
                        restCard
                    } else {
                        doneCard
                    }
                }
                .padding()
            }
            .navigationTitle("WORKOUT ATTIVO")
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .onAppear {
                if let ex = current { weight = ex.defaultWeight }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if resting && restRemaining > 0 {
                    restRemaining -= 1
                    if restRemaining == 0 { resting = false }
                }
            }
        }
    }

    private func exerciseCard(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ex.name).font(.title3.bold())
                    Text("\(ex.muscle.rawValue) · \(ex.equipment) · esercizio \(index + 1)/\(ids.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Serie \(min(setNumber, ex.defaultSets))/\(ex.defaultSets)")
                        .font(.headline.bold())
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("1RM stimato ora").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(oneRM)) kg").font(.title3.bold()).foregroundStyle(Theme.gold)
                }
                VStack(alignment: .leading) {
                    Text("Record 1RM").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(ex.best1RM)) kg").font(.title3.bold())
                }
            }
        }
        .card()
    }

    private func controlsCard(_ ex: Exercise) -> some View {
        VStack(spacing: 12) {
            Stepper("Carico: \(Int(weight)) kg", value: $weight, in: 0...400, step: 2.5)
            HStack(spacing: 20) {
                Button {
                    repsDone = max(0, repsDone - 1)
                    haptic()
                } label: {
                    Image(systemName: "minus.circle.fill").font(.largeTitle)
                }
                .disabled(repsDone <= 0)
                Text("\(repsDone) / \(ex.defaultReps)")
                    .font(.system(.title2, design: .rounded).bold())
                    .monospacedDigit()
                    .frame(minWidth: 110)
                Button {
                    repsDone += 1
                    haptic()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                }
            }
            Button {
                completeSet(ex)
            } label: {
                Label("Serie completa ✓", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .card()
    }

    private var restCard: some View {
        VStack(spacing: 10) {
            Text("Recupero intelligente").font(.headline)
            Text(String(format: "%02d:%02d", restRemaining / 60, restRemaining % 60))
                .font(.system(size: 40, design: .rounded).bold())
                .monospacedDigit()
                .foregroundStyle(resting ? Theme.gold : .primary)
            Stepper("Durata recupero: \(restTotal) s", value: $restTotal, in: 15...600, step: 15)
                .disabled(resting)
            HStack(spacing: 12) {
                Button(resting ? "Pausa" : "Avvia recupero") {
                    haptic()
                    if resting {
                        resting = false
                    } else {
                        restRemaining = restTotal
                        resting = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Salta") {
                    haptic()
                    resting = false
                    restRemaining = 0
                }
                .buttonStyle(.bordered)
                .disabled(!resting && restRemaining == 0)
            }
        }
        .card()
    }

    private var doneCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Workout completato").font(.title2.bold())
            Text("\(loggedCount) serie registrate. L'avatar 3D si aggiorna con la nuova forma fisica.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Chiudi") {
                haptic(.medium)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .card()
        .padding(.top, 40)
    }

    private func completeSet(_ ex: Exercise) {
        haptic(.medium)
        let reps = max(repsDone, 1)
        store.logSet(exerciseId: ex.id, weight: weight, reps: reps)
        loggedCount += 1
        repsDone = 0
        if setNumber >= ex.defaultSets {
            index += 1
            setNumber = 1
            if let next = current { weight = next.defaultWeight }
        } else {
            setNumber += 1
            restRemaining = restTotal
            resting = true
        }
    }
}
