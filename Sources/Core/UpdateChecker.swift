import Foundation

/// Aggiornamenti dall'app: legge la sorgente pubblica (formato AltStore,
/// compatibile con LiveContainer e SideStore) e, se c'è una build più nuova,
/// la installa con il link di LiveContainer `livecontainer://install?url=…`.
/// Il codice resta nel repository privato; quello pubblico contiene solo IPA.
enum UpdateChecker {
    static let releasesRepo = "cipherdesk007-max/quantswarm-releases"
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/\(releasesRepo)/main/apps.json")!
    static let bundleIdentifier = "com.quantswarm.alphazero"

    struct Release: Sendable, Equatable {
        let version: String
        let build: Int
        let downloadURL: URL
        let notes: String
    }

    /// Ultima versione dichiarata nella sorgente per questa app (nil se la
    /// sorgente non c'è ancora o non contiene l'app).
    static func latest(from data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == bundleIdentifier }),
              let versions = app["versions"] as? [[String: Any]] else { return nil }
        let releases = versions.compactMap { v -> Release? in
            guard let version = v["version"] as? String,
                  let buildText = (v["buildVersion"] as? String) ?? (v["buildVersion"] as? Int).map(String.init),
                  let build = Int(buildText),
                  let urlText = v["downloadURL"] as? String, let url = URL(string: urlText),
                  url.scheme == "https" else { return nil }
            return Release(version: version, build: build, downloadURL: url,
                           notes: v["localizedDescription"] as? String ?? "")
        }
        return releases.max { $0.build < $1.build }
    }

    /// C'è da aggiornare? Solo se la build pubblicata è più nuova di quella installata.
    static func isNewer(_ release: Release, than installedBuild: Int?) -> Bool {
        guard let installedBuild else { return false }
        return release.build > installedBuild
    }

    static var installedBuild: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// Link che fa installare l'IPA a LiveContainer (aggiorna l'app esistente
    /// mantenendo dati e impostazioni).
    static func liveContainerInstallURL(for release: Release) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = release.downloadURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "livecontainer://install?url=\(encoded)")
    }

    /// Link che aggiunge la sorgente a LiveContainer (aggiornamenti nella scheda Sources).
    static var liveContainerSourceURL: URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "livecontainer://source?url=\(encoded)")
    }

    static func fetchLatest() async -> Release? {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return latest(from: data)
    }
}
