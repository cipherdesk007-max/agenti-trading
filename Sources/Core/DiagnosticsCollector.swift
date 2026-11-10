import Foundation
import MetricKit

/// Raccolta automatica di crash e blocchi tramite MetricKit (Apple).
/// iOS consegna i rapporti al massimo una volta al giorno, al riavvio
/// dell'app successivo al problema. Il riepilogo finisce nel report di
/// sessione: niente più ricerche manuali nelle Impostazioni.
/// Nota: dentro LiveContainer i rapporti possono arrivare all'app ospite.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()
    private static let fileName = "quantswarm-diagnostica.txt"
    private let lock = NSLock()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var lines: [String] = []
        let stamp = ISO8601DateFormatter()
        for payload in payloads {
            let day = stamp.string(from: payload.timeStampEnd)
            for crash in payload.crashDiagnostics ?? [] {
                let type = crash.exceptionType.map { "eccezione \($0)" } ?? ""
                let signal = crash.signal.map { "segnale \($0)" } ?? ""
                let reason = crash.terminationReason ?? ""
                let version = crash.metaData.applicationBuildVersion
                lines.append("\(day) CRASH build \(version) \(type) \(signal) \(reason)"
                    .replacingOccurrences(of: "  ", with: " "))
            }
            for hang in payload.hangDiagnostics ?? [] {
                lines.append("\(day) BLOCCO di \(hang.hangDuration.description) build \(hang.metaData.applicationBuildVersion)")
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                lines.append("\(day) CPU eccessiva build \(cpu.metaData.applicationBuildVersion)")
            }
        }
        guard !lines.isEmpty else { return }
        append(lines)
    }

    /// Ultime righe di diagnostica (nil se non c'è nulla).
    static func recentSummary(limit: Int = 10) -> [String]? {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return lines.isEmpty ? nil : Array(lines.suffix(limit))
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    private func append(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = Self.fileURL else { return }
        var existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        existing.append(contentsOf: lines)
        let kept = existing.suffix(50).joined(separator: "\n")
        try? Data(kept.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }
}
