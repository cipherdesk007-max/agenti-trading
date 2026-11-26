import Foundation
import SwiftUI

// MARK: - Controllo aggiornamenti
//
// La CI pubblica accanto all'IPA anche "versione.json" con l'ultima build.
// L'app lo legge e mostra un banner su Home (solo se c'è una versione più
// recente della installata) e la scheda AGGIORNAMENTI in SISTEMA, con il
// bottone che apre il download dell'IPA. Nessun dato dell'utente lascia
// l'iPhone: si scarica solo il numero di versione.

/// Versione pubblicata dalla CI sul branch bozza-ipa-avatarfit.
struct VersionePubblicata: Equatable, Decodable, Sendable {
    let versione: String
    let build: Int
    let data: String
    let url: String

    /// Parsing tollerante: niente se il testo non è il JSON atteso.
    static func da(_ testo: String) -> VersionePubblicata? {
        guard let dati = testo.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VersionePubblicata.self, from: dati)
    }

    /// Confronto numerico per componenti: "1.2.10" viene dopo "1.2.9",
    /// "1.1" e "1.1.0" sono uguali.
    static func confronta(_ a: String, _ b: String) -> ComparisonResult {
        let numeriA = a.split(separator: ".").compactMap { Int($0) }
        let numeriB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(numeriA.count, numeriB.count) {
            let x = i < numeriA.count ? numeriA[i] : 0
            let y = i < numeriB.count ? numeriB[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Indirizzo del file versione pubblicato dalla CI.
private let urlVersione = "https://raw.githubusercontent.com/cipherdesk007-max/agenti-trading/bozza-ipa-avatarfit/versione.json"

/// Banner per Home: appare solo se sul canale c'è una build più recente.
struct AggiornamentiBanner: View {
    @State private var remota: VersionePubblicata?

    private var versioneInstallata: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    private var aggiornamento: VersionePubblicata? {
        guard let remota,
              VersionePubblicata.confronta(remota.versione, versioneInstallata) == .orderedDescending
        else { return nil }
        return remota
    }

    var body: some View {
        Group {
            if let agg = aggiornamento, let url = URL(string: agg.url) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Nuova versione \(agg.versione) · build \(agg.build)")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Link("Scarica", destination: url)
                        .font(.footnote.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task { await cerca() }
    }

    private func cerca() async {
        guard let url = URL(string: urlVersione) else { return }
        var richiesta = URLRequest(url: url)
        richiesta.timeoutInterval = 10
        if let (dati, risposta) = try? await URLSession.shared.data(for: richiesta),
           (risposta as? HTTPURLResponse)?.statusCode == 200,
           let testo = String(data: dati, encoding: .utf8) {
            remota = VersionePubblicata.da(testo)
        }
    }
}

/// Scheda AGGIORNAMENTI per SISTEMA: versione installata, ultima build
/// disponibile, bottone di download sempre raggiungibile.
struct AggiornamentiCard: View {
    @State private var remota: VersionePubblicata?
    @State private var errore = false
    @State private var inCorso = false

    private var versioneInstallata: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "sconosciuta"
    }

    private var isAggiornamento: Bool {
        guard let remota else { return false }
        return VersionePubblicata.confronta(remota.versione, versioneInstallata) == .orderedDescending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Versione installata", value: versioneInstallata)
            if let agg = remota {
                LabeledContent("Ultima disponibile", value: "\(agg.versione) · build \(agg.build)")
                if isAggiornamento {
                    Label("Aggiornamento disponibile: scarica l'IPA e importalo in LiveContainer (prima esporta il backup).", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                } else {
                    Label("Sei aggiornato all'ultima build pubblicata.", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: agg.url) {
                    Link(destination: url) {
                        Label("Scarica l'IPA (build \(agg.build))", systemImage: "arrow.down.app.fill")
                    }
                }
            } else if errore {
                Label("Controllo non riuscito: serve una connessione. Riprova con il bottone sotto.", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(inCorso ? "Controllo in corso…" : "Nessun dato sul canale.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                haptic()
                Task { await controlla() }
            } label: {
                Label("Controlla adesso", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .task { await controlla() }
    }

    private func controlla() async {
        errore = false
        guard let url = URL(string: urlVersione) else { return }
        var richiesta = URLRequest(url: url)
        richiesta.timeoutInterval = 10
        inCorso = true
        if let (dati, risposta) = try? await URLSession.shared.data(for: richiesta),
           (risposta as? HTTPURLResponse)?.statusCode == 200,
           let testo = String(data: dati, encoding: .utf8),
           let v = VersionePubblicata.da(testo) {
            remota = v
        } else if remota == nil {
            errore = true
        }
        inCorso = false
    }
}
