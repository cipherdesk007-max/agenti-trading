import Foundation
import UIKit

/// Aggiornamenti dall'app: legge la sorgente pubblica (formato AltStore,
/// compatibile con LiveContainer e SideStore) e, se c'è una build più nuova,
/// apre il gestore GIUSTO: chi gira dentro LiveContainer usa
/// `livecontainer://install?url=…`, chi è installato da SideStore usa
/// `sidestore://install?url=…` (così l'aggiornamento finisce sulla copia
/// giusta e non "sopra" l'altro gestore).
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

    /// Come è gestita questa copia dell'app.
    enum Store: Sendable, Equatable {
        case liveContainer   // gira dentro LiveContainer
        case sideStore       // sideloaded con SideStore
        case download        // nessun gestore riconosciuto: si scarica l'IPA

        var name: String {
            switch self {
            case .liveContainer: return "LiveContainer"
            case .sideStore: return "SideStore"
            case .download: return "Safari"
            }
        }
    }

    /// True se l'app gira dentro LiveContainer: le classi dell'host
    /// (LCAppInfo e simili) sono caricate nello stesso processo del guest.
    static var isRunningInLiveContainer: Bool {
        NSClassFromString("LCAppInfo") != nil || NSClassFromString("LCSharedUtils") != nil
    }

    /// Il gestore di QUESTA installazione. `canOpenScheme` dice se uno schema
    /// URL è apribile: iOS lo permette solo per gli schemi dichiarati in
    /// LSApplicationQueriesSchemes (project.yml: livecontainer, sidestore).
    /// MainActor perché interroga UIApplication.
    @MainActor
    static func currentStore(canOpenScheme: @MainActor (String) -> Bool
        = { UIApplication.shared.canOpenURL(URL(string: "\($0)://")!) }) -> Store {
        if isRunningInLiveContainer { return .liveContainer }
        if canOpenScheme("sidestore") { return .sideStore }
        return .download
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

    /// URL nel formato `schema://azione?url=…` con l'URL codificato intero
    /// (il & dell'URL reale non deve spezzare la query).
    static func actionURL(scheme: String, action: String, url: URL) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://\(action)?url=\(encoded)")
    }

    /// Link che fa installare l'IPA a LiveContainer (aggiorna l'app esistente
    /// mantenendo dati e impostazioni). Usato solo se si gira DENTRO LC.
    static func liveContainerInstallURL(for release: Release) -> URL? {
        actionURL(scheme: "livecontainer", action: "install", url: release.downloadURL)
    }

    /// Link che fa installare l'IPA a SideStore, che la firma e la installa
    /// sopra l'app esistente (schema ufficiale sidestore://install?url=…).
    static func sideStoreInstallURL(for release: Release) -> URL? {
        actionURL(scheme: "sidestore", action: "install", url: release.downloadURL)
    }

    /// L'azione "Aggiorna" per come è installata questa copia: il downloadURL
    /// diretto (Safari) quando nessun gestore è riconosciuto.
    @MainActor
    static func installURL(for release: Release, store: Store? = nil) -> URL? {
        switch store ?? currentStore() {
        case .liveContainer: return liveContainerInstallURL(for: release)
        case .sideStore: return sideStoreInstallURL(for: release)
        case .download: return release.downloadURL
        }
    }

    /// Link che aggiunge la sorgente a LiveContainer (aggiornamenti nella scheda Sources).
    static var liveContainerSourceURL: URL? {
        actionURL(scheme: "livecontainer", action: "source", url: sourceURL)
    }

    /// Link che aggiunge la sorgente a SideStore (schema ufficiale sidestore://source?url=…).
    static var sideStoreSourceURL: URL? {
        actionURL(scheme: "sidestore", action: "source", url: sourceURL)
    }

    /// L'azione "Aggiungi sorgente" per come è installata questa copia:
    /// con il gestore che possiede l'app, così gli aggiornamenti arrivano lì.
    @MainActor
    static func storeSourceURL(for store: Store? = nil) -> URL? {
        switch store ?? currentStore() {
        case .liveContainer: return liveContainerSourceURL
        case .sideStore: return sideStoreSourceURL
        case .download: return sourceURL
        }
    }

    static func fetchLatest() async -> Release? {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return latest(from: data)
    }
}
