import Foundation

enum CrashLog {
    static let url: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("AvatarFit/crash.log")
    }()

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            append("CRASH \(Date().ISO8601Format()): \(exception.name.rawValue) — \(exception.reason ?? "")")
        }
    }

    static func append(_ line: String) {
        guard let url else { return }
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func tail(_ maxLines: Int = 30) -> String {
        guard let url,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return "Nessun crash registrato." }
        return text.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
    }
}
