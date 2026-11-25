import Foundation

func epley1RM(_ weight: Double, _ reps: Int) -> Double {
    guard reps > 1 else { return weight }
    return weight * (1 + Double(reps) / 30)
}

struct Measurements: Codable, Equatable, Sendable {
    var heightCm: Double = 175
    var weightKg: Double = 72
    var shoeSize: Int = 42
    var headCm: Double = 56
    var neckCm: Double = 37
    var shoulderCm: Double = 112
    var chestCm: Double = 96
    var armCm: Double = 62
    var waistCm: Double = 82
    var hipCm: Double = 96
    var legCm: Double = 92

    var bmi: Double {
        let h = heightCm / 100
        guard h > 0 else { return 0 }
        return weightKg / (h * h)
    }
}

struct Appearance: Codable, Equatable, Sendable {
    var skinTone: Int = 2
    var hairColor: Int = 2
    var outfitColor: Int = 0

    static let skinTones: [(String, UInt32)] = [
        ("Chiarissima", 0xF5D5C0), ("Chiara", 0xE8B98D), ("Media", 0xC68863),
        ("Olivastra", 0x9C6644), ("Scura", 0x6F4A30), ("Profonda", 0x4A3121)
    ]
    static let hairColors: [(String, UInt32)] = [
        ("Nero", 0x1B1B1F), ("Castano", 0x4A2F1D), ("Biondo", 0xC9A25E),
        ("Rosso", 0x8C3A1E), ("Grigio", 0x9A9A9A), ("Bianco", 0xE8E8E8)
    ]
    static let outfitColors: [(String, UInt32)] = [
        ("Ciano neon", 0x00E5FF), ("Oro", 0xFFD60A), ("Violetto", 0x8B5CF6),
        ("Verde", 0x34D399), ("Arancio", 0xFB923C), ("Antracite", 0x6B7280)
    ]
}

struct FaceMeshData: Codable, Sendable {
    var positions: [Float]
    var normals: [Float]
    var indices: [Int32]
}

enum MuscleGroup: String, Codable, CaseIterable, Sendable {
    case petto = "Petto"
    case dorso = "Dorso"
    case spalle = "Spalle"
    case braccia = "Braccia"
    case gambe = "Gambe"
    case core = "Core"
    case cardio = "Cardio"
}

enum MovementType: String, Codable, CaseIterable, Sendable {
    case pullUp = "Trazioni alla sbarra"
    case pushUp = "Piegamenti (push-up)"
    case bench = "Panca piana"
    case squat = "Squat"
    case lunge = "Affondi"
    case row = "Rematore"
    case curl = "Curl manubri"
    case lateralRaise = "Alzate laterali"
    case plank = "Plank"
    case custom = "Movimento libero"
}

struct ExerciseLog: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var weight: Double
    var reps: Int
}

struct Exercise: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var muscle: MuscleGroup
    var equipment: String
    var movement: MovementType
    var defaultSets: Int = 3
    var defaultReps: Int = 10
    var defaultWeight: Double = 0
    var custom: Bool = false
    var history: [ExerciseLog] = []

    var best1RM: Double {
        history.reduce(0) { max($0, epley1RM($1.weight, $1.reps)) }
    }
}

extension MovementType {
    /// Frazione del peso corporeo sollevata dall'esercizio (0 = solo carico esterno).
    /// Stime standard: trazioni 100%, piegamenti ~64%, squat/affondi ~65%, plank ~50%.
    var bodyweightFraction: Double {
        switch self {
        case .pullUp: return 1.0
        case .pushUp: return 0.64
        case .squat, .lunge: return 0.65
        case .plank: return 0.5
        case .bench, .row, .curl, .lateralRaise, .custom: return 0
        }
    }

    /// Vero se l'esercizio solleva (anche) il peso del corpo.
    var usesBodyweight: Bool { bodyweightFraction > 0 }
}

/// Carico totale sollevato in una ripetizione: frazione del peso corporeo + carico extra aggiunto.
func effectiveLoad(movement: MovementType, bodyWeightKg: Double, addedKg: Double) -> Double {
    let body = movement.bodyweightFraction * max(0, bodyWeightKg)
    return body + max(0, addedKg)
}

struct SmokeSettings: Codable, Sendable {
    var enabled: Bool = false
    var quitDate: Date = Date()
    var cigarettesPerDay: Int = 20
    var packPrice: Double = 5.50
    var cigarettesPerPack: Int = 20
}

struct HealthMilestone: Identifiable, Sendable {
    let id = UUID()
    let minutes: Double
    let title: String
    let detail: String
    let icon: String
}

extension HealthMilestone {
    static let all: [HealthMilestone] = [
        HealthMilestone(minutes: 20, title: "Cuore e pressione", detail: "Frequenza cardiaca e pressione sanguigna tornano normali", icon: "heart.fill"),
        HealthMilestone(minutes: 8 * 60, title: "Sangue pulito", detail: "Il monossido di carbonio viene eliminato dal sangue", icon: "drop.fill"),
        HealthMilestone(minutes: 24 * 60, title: "Rischio infarto", detail: "Inizia a scendere il rischio di infarto", icon: "waveform.path.ecg"),
        HealthMilestone(minutes: 48 * 60, title: "Gusto e olfatto", detail: "I sensi di gusto e olfatto migliorano", icon: "nose.fill"),
        HealthMilestone(minutes: 14 * 24 * 60, title: "Circolazione", detail: "Circolazione e funzione polmonare migliorano", icon: "lungs.fill"),
        HealthMilestone(minutes: 90 * 24 * 60, title: "Capacita' polmonare", detail: "La funzione polmonare puo' aumentare fino al 30%", icon: "lungs.fill"),
        HealthMilestone(minutes: 365 * 24 * 60, title: "Cuore protetto", detail: "Il rischio di malattie cardiache si dimezza", icon: "heart.text.square"),
        HealthMilestone(minutes: 10 * 365 * 24 * 60, title: "Rischio tumore", detail: "Il rischio di tumore al polmone si dimezza", icon: "checkmark.shield.fill")
    ]
}

struct CalendarEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var date: Date
    var reminder: Bool = false
    var isDone: Bool = false
}

enum WorkoutKind: String, Codable, CaseIterable, Sendable {
    case pesi = "Pesi"
    case cardio = "Cardio"
}

struct WorkoutEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var name: String
    var kind: WorkoutKind
    var weightKg: Double = 0
    var reps: Int = 0
    var durationMin: Int = 0
}

struct CustomTracker: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var unit: String
    var goal: Double
    var value: Double = 0
    var step: Double = 1
    var lastReset: Date = Date()
}
