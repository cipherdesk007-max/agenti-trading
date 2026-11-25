import Charts
import Foundation
import SwiftUI

struct WorkoutView: View {
    @Environment(AppStore.self) private var store
    @State private var chartExerciseId: UUID?

    private var sortedWorkouts: [WorkoutEntry] {
        store.workouts.sorted { $0.date > $1.date }
    }

    private var chartExercise: Exercise? {
        store.exercises.first { $0.id == chartExerciseId } ?? store.exercises.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                formaCard

                NavigationLink {
                    ExerciseLibraryView()
                } label: {
                    Label("Libreria esercizi", systemImage: "list.bullet.rectangle.portrait.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                if !store.sessionIds.isEmpty {
                    NavigationLink {
                        ActiveWorkoutView(ids: store.sessionIds)
                    } label: {
                        Label("Workout in corso · \(store.sessionIds.count) esercizi", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.gold)
                }

                chartCard
                historySection
            }
            .padding()
        }
        .navigationTitle("WORKOUT PRO")
        .background(Color.black)
    }

    private var formaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Forma fisica (30 giorni)").font(.headline)
                Spacer()
                Text("\(Int(store.fitness * 100))%").bold().foregroundStyle(Theme.accent)
            }
            ProgressView(value: store.fitness)
                .tint(Theme.accent)
            Text("Alimenta la definizione muscolare dell'avatar 3D nella Home.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Progresso forza · 1RM stimato (Epley)").font(.headline)
            Picker("Esercizio", selection: Binding(
                get: { chartExercise?.id },
                set: { if let id = $0 { chartExerciseId = id } }
            )) {
                ForEach(store.exercises) { ex in
                    Text(ex.name).tag(Optional(ex.id))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.gold)
            if let ex = chartExercise, !ex.history.isEmpty {
                Chart(ex.history.sorted { $0.date < $1.date }) { log in
                    BarMark(
                        x: .value("Data", log.date, unit: .day),
                        y: .value("1RM kg", epley1RM(log.weight, log.reps))
                    )
                    .foregroundStyle(Theme.accent)
                }
                .frame(height: 160)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            } else {
                Text("Completa delle serie in un workout attivo per vedere il grafico dei progressi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STORICO SESSIONI").font(.headline).padding(.horizontal, 4)
            if sortedWorkouts.isEmpty {
                Text("Nessuna serie registrata: avvia un workout dalla libreria.")
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
                                Text(w.kind == .pesi ? "\(Int(w.weightKg)) kg × \(w.reps) rip. · 1RM \(Int(epley1RM(w.weightKg, w.reps))) kg" : "\(w.durationMin) min cardio")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(w.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.black)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
                        }
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
