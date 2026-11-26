import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SystemView: View {
    @Environment(AppStore.self) private var store
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showImport = false
    @State private var showImportaAvatar = false
    @State private var alertMessage: String?
    @State private var showResetAlert = false

    var body: some View {
        List {
            Section {
                AggiornamentiCard()
            } header: {
                Text("Aggiornamenti".uppercased()).foregroundStyle(Theme.accent)
            } footer: {
                Text("Il controllo legge solo il numero di versione pubblicato su GitHub: nessun tuo dato lascia l'iPhone. Il bottone scarica l'ultima build dell'IPA da importare in LiveContainer.")
            }

            Section {
                Toggle("Personaggio 3D (beta)", isOn: Binding(
                    get: { store.usePersonaggio },
                    set: { v in
                        store.usePersonaggio = v
                        haptic()
                    }
                ))
            } header: {
                Text("Avatar · beta".uppercased()).foregroundStyle(Theme.accent)
            } footer: {
                Text("Personaggio rigged CC0 (Quaternius Superhero Male, licenza CC0 1.0 nel bundle): i 10 esercizi lo animano con il driver verificato dallo studio 3D (distanza mano-bersaglio max ~8 cm). Non ancora implementati su di lui: viso-foto, effetto misure sulle ossa, auto-camera e bagliore muscolare. Il manichino resta disponibile disattivando questa opzione.")
            }

            Section {
                if store.avatarPersonaleEstensione != nil {
                    LabeledContent("Modello importato", value: ".\(store.avatarPersonaleEstensione ?? "")")
                    Toggle("Usa al posto del manichino", isOn: Binding(
                        get: { store.usePersonalAvatar },
                        set: { v in
                            store.usePersonalAvatar = v
                            haptic()
                        }
                    ))
                    Button("Rimuovi modello", role: .destructive) {
                        store.rimuoviAvatarPersonale()
                        haptic(.light)
                    }
                } else {
                    Text("Nessun modello importato.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    haptic()
                    showImportaAvatar = true
                } label: {
                    Label("Importa avatar 3D (.usdz, .dae…)", systemImage: "cube.transparent")
                }
            } header: {
                Text("Avatar personale · beta".uppercased()).foregroundStyle(Theme.accent)
            } footer: {
                Text("Sperimentale: un tuo modello 3D (es. un avatar .usdz) sostituisce il manichino nell'Home e ruota col dito, ma gli esercizi non lo animano ancora. Il file non entra nei backup: dopo un ripristino reimportalo. Il .glTF non si apre su iPhone senza conversione.")
            }

            Section {
                Button {
                    haptic(.medium)
                    if let url = store.exportBackup() {
                        shareURL = url
                        showShare = true
                    } else {
                        alertMessage = "Export non riuscito."
                    }
                } label: {
                    Label("Esporta backup (JSON)", systemImage: "square.and.arrow.up")
                }
                Button {
                    haptic()
                    showImport = true
                } label: {
                    Label("Importa backup (JSON)", systemImage: "square.and.arrow.down")
                }
                Text("Il backup contiene misure, aspetto, scansione viso, esercizi e storico, sessioni, calendario, protocollo fumo e tracker. Importarlo sostituisce i dati attuali: usalo quando aggiorni l'IPA su LiveContainer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("BACKUP".uppercased()).foregroundStyle(Theme.accent)
            }

            Section {
                LabeledContent("Esercizi in libreria", value: "\(store.exercises.count)")
                LabeledContent("Serie registrate", value: "\(store.workouts.count)")
                LabeledContent("Eventi in calendario", value: "\(store.events.count)")
                LabeledContent("Tracker attivi", value: "\(store.trackers.count)")
                LabeledContent("Foto di riferimento", value: store.photoData == nil ? "no" : "sì · solo locale")
                LabeledContent("Scansione viso", value: store.faceMesh == nil ? "no" : "sì · solo locale")
            } header: {
                Text("Dati locali".uppercased()).foregroundStyle(Theme.accent)
            }

            Section {
                Button("Azzera tutti i dati", role: .destructive) {
                    showResetAlert = true
                }
            } footer: {
                Text("Privacy: i tuoi dati restano solo su questo iPhone (sandbox dell'app), nessun account. Unica rete usata dall'app: il controllo aggiornamenti, che legge solo il numero di versione.")
            }

            Section {
                LabeledContent("Modello", value: deviceIdentifier())
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Ultimo avvio", value: UserDefaults.standard.string(forKey: "ultimoAvvio") ?? "—")
                Text(CrashLog.tail())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("Diagnostica".uppercased()).foregroundStyle(Theme.accent)
            } footer: {
                Text("Se l'app va in crash o resta nera, copia qui il testo e mandamelo.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("SISTEMA")
        .alert("Azzerare tutti i dati locali?", isPresented: $showResetAlert) {
            Button("Annulla", role: .cancel) {}
            Button("Azzera", role: .destructive) {
                store.resetAll()
                haptic(.heavy)
            }
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") {}
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ActivityView(activityItems: [shareURL])
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                alertMessage = store.importBackup(from: url) ? "Backup importato: dati ripristinati." : "File non valido: backup non importato."
                haptic(.medium)
            case .failure:
                alertMessage = "Importazione annullata."
            }
        }
        .fileImporter(isPresented: $showImportaAvatar, allowedContentTypes: AvatarPersonale.tipiFile) { result in
            switch result {
            case .success(let url):
                if let errore = store.importaAvatarPersonale(from: url) {
                    alertMessage = errore
                } else {
                    alertMessage = "Avatar personale importato: lo vedi nell'Home, ruota col dito."
                }
                haptic(.medium)
            case .failure:
                alertMessage = "Importazione annullata."
            }
        }
    }
}

private func deviceIdentifier() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    return withUnsafePointer(to: &sysinfo.machine) { ptr in
        String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
