import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AppStore {
    var measurements = Measurements() { didSet { save() } }
    var appearance = Appearance() { didSet { save() } }
    var smoke = SmokeSettings() { didSet { save() } }
    var events: [CalendarEvent] = [] { didSet { save() } }
    var workouts: [WorkoutEntry] = [] { didSet { save() } }
    var trackers: [CustomTracker] = [] { didSet { save() } }
    var exercises: [Exercise] = [] { didSet { save() } }
    var demoExerciseId: UUID? { didSet { save() } }
    var sessionIds: [UUID] = [] { didSet { save() } }
    var use3D = true { didSet { save() } }
    var usePersonalAvatar = false { didSet { save() } }
    var usePersonaggio = true { didSet { save() } }
    var avatarPersonaleEstensione: String? { didSet { save() } }
    var autoGalleryFace = false { didSet { save() } }
    var faceMesh: FaceMeshData? { didSet { save() } }

    private(set) var photoData: Data?

    /// Volto dell'avatar ritagliato in cerchio, solo in RAM (il file resta foto-riferimento.jpg).
    private(set) var faceImage: UIImage?

    private let documents: URL
    private var dataURL: URL { documents.appendingPathComponent("dati.json") }
    private var photoURL: URL { documents.appendingPathComponent("foto-riferimento.jpg") }

    /// Dove vive il modello 3D importato dall'utente (beta).
    var urlAvatarPersonale: URL? {
        guard let e = avatarPersonaleEstensione else { return nil }
        return documents.appendingPathComponent("avatar-personale.\(e)")
    }

    struct Snapshot: Codable {
        var measurements: Measurements
        var appearance: Appearance
        var smoke: SmokeSettings
        var events: [CalendarEvent]
        var workouts: [WorkoutEntry]
        var trackers: [CustomTracker]
        var exercises: [Exercise]
        var demoExerciseId: UUID?
        var sessionIds: [UUID]
        var use3D: Bool?
        var usePersonalAvatar: Bool?
        var usePersonaggio: Bool?
        var avatarPersonaleEstensione: String?
        var autoGalleryFace: Bool?
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
            exercises = snap.exercises
            demoExerciseId = snap.demoExerciseId
            sessionIds = snap.sessionIds
            use3D = snap.use3D ?? true
            usePersonalAvatar = snap.usePersonalAvatar ?? false
            usePersonaggio = snap.usePersonaggio ?? true
            avatarPersonaleEstensione = snap.avatarPersonaleEstensione
            autoGalleryFace = snap.autoGalleryFace ?? false
            faceMesh = snap.faceMesh
        } else {
            seed()
        }
        photoData = try? Data(contentsOf: photoURL)
        ricaricaVolto()
        // coerenza: il flag senza il file non vale (il modello non entra
        // nei backup, dopo un ripristino va reimportato)
        if let url = urlAvatarPersonale, !FileManager.default.fileExists(atPath: url.path) {
            avatarPersonaleEstensione = nil
            usePersonalAvatar = false
        }
    }

    /// Ridisegna il volto ritagliato partendo dal file locale.
    private func ricaricaVolto() {
        faceImage = photoData
            .flatMap { UIImage(data: $0) }
            .flatMap { RitaglioViso.cerchio($0) }
    }

    private func seed() {
        trackers = [
            CustomTracker(name: "Acqua", symbol: "💧", unit: "L", goal: 2, step: 0.25),
            CustomTracker(name: "Sonno", symbol: "😴", unit: "h", goal: 8, step: 0.5),
            CustomTracker(name: "Passi", symbol: "🚶", unit: "passi", goal: 10000, step: 500)
        ]
        exercises = [
            Exercise(name: "Trazioni (pull-up)", muscle: .dorso, equipment: "Sbarra", movement: .pullUp, defaultSets: 4, defaultReps: 8),
            Exercise(name: "Chin-up", muscle: .dorso, equipment: "Sbarra", movement: .pullUp, defaultSets: 4, defaultReps: 8),
            Exercise(name: "Flessioni", muscle: .petto, equipment: "Corpo libero", movement: .pushUp, defaultSets: 4, defaultReps: 12),
            Exercise(name: "Flessioni diamante", muscle: .petto, equipment: "Corpo libero", movement: .pushUp, defaultSets: 3, defaultReps: 10),
            Exercise(name: "Panca piana", muscle: .petto, equipment: "Bilanciere", movement: .bench, defaultSets: 4, defaultReps: 8, defaultWeight: 40),
            Exercise(name: "Rematore con manubrio", muscle: .dorso, equipment: "Manubri", movement: .row, defaultSets: 4, defaultReps: 10, defaultWeight: 12),
            Exercise(name: "Curl manubri", muscle: .braccia, equipment: "Manubri", movement: .curl, defaultSets: 3, defaultReps: 12, defaultWeight: 8),
            Exercise(name: "Alzate laterali", muscle: .spalle, equipment: "Manubri", movement: .lateralRaise, defaultSets: 3, defaultReps: 12, defaultWeight: 5),
            Exercise(name: "Squat", muscle: .gambe, equipment: "Corpo libero", movement: .squat, defaultSets: 4, defaultReps: 12),
            Exercise(name: "Affondi", muscle: .gambe, equipment: "Corpo libero", movement: .lunge, defaultSets: 3, defaultReps: 10),
            Exercise(name: "Plank", muscle: .core, equipment: "Corpo libero", movement: .plank, defaultSets: 3, defaultReps: 30)
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
            exercises: exercises,
            demoExerciseId: demoExerciseId,
            sessionIds: sessionIds,
            use3D: use3D,
            usePersonalAvatar: usePersonalAvatar,
            usePersonaggio: usePersonaggio,
            avatarPersonaleEstensione: avatarPersonaleEstensione,
            autoGalleryFace: autoGalleryFace,
            faceMesh: faceMesh
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: dataURL, options: .atomic)
    }

    func exportBackup() -> URL? {
        let snap = Snapshot(
            measurements: measurements,
            appearance: appearance,
            smoke: smoke,
            events: events,
            workouts: workouts,
            trackers: trackers,
            exercises: exercises,
            demoExerciseId: demoExerciseId,
            sessionIds: sessionIds,
            use3D: use3D,
            usePersonalAvatar: usePersonalAvatar,
            usePersonaggio: usePersonaggio,
            avatarPersonaleEstensione: avatarPersonaleEstensione,
            autoGalleryFace: autoGalleryFace,
            faceMesh: faceMesh
        )
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvatarFit-backup-\(Int(Date().timeIntervalSince1970)).json")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func importBackup(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        measurements = snap.measurements
        appearance = snap.appearance
        smoke = snap.smoke
        events = snap.events
        workouts = snap.workouts
        trackers = snap.trackers
        exercises = snap.exercises
        demoExerciseId = snap.demoExerciseId
        sessionIds = snap.sessionIds
        use3D = snap.use3D ?? true
        usePersonalAvatar = snap.usePersonalAvatar ?? false
        avatarPersonaleEstensione = snap.avatarPersonaleEstensione
        autoGalleryFace = snap.autoGalleryFace ?? false
        faceMesh = snap.faceMesh
        if let url = urlAvatarPersonale, !FileManager.default.fileExists(atPath: url.path) {
            avatarPersonaleEstensione = nil
            usePersonalAvatar = false
        }
        return true
    }

    func resetAll() {
        measurements = Measurements()
        appearance = Appearance()
        smoke = SmokeSettings()
        events = []
        workouts = []
        sessionIds = []
        demoExerciseId = nil
        use3D = true
        usePersonalAvatar = false
        avatarPersonaleEstensione = nil
        autoGalleryFace = false
        faceMesh = nil
        clearPhoto()
        seed()
    }

    /// Copia il modello 3D scelto dentro l'app e lo attiva. Ritorna nil se
    /// tutto è andato bene, altrimenti il messaggio di errore da mostrare.
    @discardableResult
    func importaAvatarPersonale(from url: URL) -> String? {
        guard let e = AvatarPersonale.estensioneValida(url) else {
            return "Formato non supportato: servono .usdz, .usda, .dae oppure .obj (il .glTF non si apre su iPhone)."
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        for vecchia in AvatarPersonale.estensioniValide where vecchia != e {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("avatar-personale.\(vecchia)"))
        }
        let dest = documents.appendingPathComponent("avatar-personale.\(e)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return "Copia non riuscita: il file non si è potuto salvare nell'app."
        }
        avatarPersonaleEstensione = e
        usePersonalAvatar = true
        return nil
    }

    /// Toglie il modello 3D importato (il manichino torna quello di sempre).
    func rimuoviAvatarPersonale() {
        if let url = urlAvatarPersonale {
            try? FileManager.default.removeItem(at: url)
        }
        avatarPersonaleEstensione = nil
        usePersonalAvatar = false
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
        ricaricaVolto()
    }

    func clearPhoto() {
        photoData = nil
        faceImage = nil
        try? FileManager.default.removeItem(at: photoURL)
    }

    func setFaceMesh(_ mesh: FaceMeshData) {
        faceMesh = mesh
    }

    func clearFaceMesh() {
        faceMesh = nil
    }

    func toggleEvent(_ id: UUID) {
        haptic()
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].isDone.toggle()
    }

    func toggleSession(_ id: UUID) {
        haptic()
        if let i = sessionIds.firstIndex(of: id) {
            sessionIds.remove(at: i)
        } else {
            sessionIds.append(id)
        }
    }

    func logSet(exerciseId: UUID, weight: Double, reps: Int) {
        guard let i = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        exercises[i].history.append(ExerciseLog(date: Date(), weight: weight, reps: reps))
        // "weight" qui è il carico TOTALE (peso corporeo incluso per gli esercizi a corpo libero):
        // il defaultWeight della prox sessione resta il solo carico extra.
        let bodyLoad = exercises[i].movement.bodyweightFraction * measurements.weightKg
        exercises[i].defaultWeight = max(0, weight - bodyLoad)
        workouts.append(WorkoutEntry(
            date: Date(),
            name: exercises[i].name,
            kind: .pesi,
            weightKg: weight,
            reps: reps
        ))
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
