import Foundation
import Observation

@Observable
@MainActor
final class AppStore {
    var measurements = Measurements() { didSet { save() } }
    var appearance = Appearance() { didSet { save() } }
    var smoke = SmokeSettings() { didSet { save() } }
    var events: [CalendarEvent] = [] { didSet { save() } }
    var workouts: [WorkoutEntry] = [] { didSet { save() } }
    var trackers: [CustomTracker] = [] { didSet { save() } }
    var faceMesh: FaceMeshData? { didSet { save() } }

    private(set) var photoData: Data?

    private let documents: URL
    private var dataURL: URL { documents.appendingPathComponent("dati.json") }
    private var photoURL: URL { documents.appendingPathComponent("foto-riferimento.jpg") }

    private struct Snapshot: Codable {
        var measurements: Measurements
        var appearance: Appearance
        var smoke: SmokeSettings
        var events: [CalendarEvent]
        var workouts: [WorkoutEntry]
        var trackers: [CustomTracker]
        var faceMesh: FaceMeshData?
    }

    init() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            documents = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AvatarFit")
            photoData = nil
            seed()
            return
        }
        documents = dir.appendingPathComponent("AvatarFit", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dataURL),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            measurements = snap.measurements
            appearance = snap.appearance
            smoke = snap.smoke
            events = snap.events
            workouts = snap.workouts
            trackers = snap.trackers
            faceMesh = snap.faceMesh
        } else {
            seed()
        }
        photoData = try? Data(contentsOf: photoURL)
    }

    private func seed() {
        trackers = [
            CustomTracker(name: "Acqua", symbol: "💧", unit: "L", goal: 2, step: 0.25),
            CustomTracker(name: "Sonno", symbol: "😴", unit: "h", goal: 8, step: 0.5),
            CustomTracker(name: "Passi", symbol: "🚶", unit: "passi", goal: 10000, step: 500)
        ]
    }

    private func save() {
        let snap = Snapshot(
            measurements: measurements,
            appearance: appearance,
            smoke: smoke,
            events: events,
            workouts: workouts,
            trackers: trackers,
            faceMesh: faceMesh
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: dataURL, options: .atomic)
    }

    var fitness: Double {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let volume = workouts.filter { $0.date >= cutoff }.reduce(0.0) { acc, w in
            if w.kind == .pesi { return acc + w.weightKg * Double(w.reps) }
            return acc + Double(w.durationMin) * 25
        }
        return min(1, volume / 20000)
    }

    func setPhoto(_ data: Data) {
        photoData = data
        try? data.write(to: photoURL)
    }

    func clearPhoto() {
        photoData = nil
        try? FileManager.default.removeItem(at: photoURL)
    }

    func setFaceMesh(_ mesh: FaceMeshData) {
        faceMesh = mesh
    }

    func clearFaceMesh() {
        faceMesh = nil
    }

    func toggleEvent(_ id: UUID) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].isDone.toggle()
    }

    func bump(_ id: UUID, by: Double) {
        guard let i = trackers.firstIndex(where: { $0.id == id }) else { return }
        if !Calendar.current.isDateInToday(trackers[i].lastReset) {
            trackers[i].value = 0
            trackers[i].lastReset = Date()
        }
        trackers[i].value = max(0, trackers[i].value + by)
    }

    func resetTracker(_ id: UUID) {
        guard let i = trackers.firstIndex(where: { $0.id == id }) else { return }
        trackers[i].value = 0
        trackers[i].lastReset = Date()
    }

    func removeTracker(_ id: UUID) {
        trackers.removeAll { $0.id == id }
    }

    func todayValue(_ t: CustomTracker) -> Double {
        Calendar.current.isDateInToday(t.lastReset) ? t.value : 0
    }
}
