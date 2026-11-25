import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SystemView: View {
    @Environment(AppStore.self) private var store
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showImport = false
    @State private var alertMessage: String?
    @State private var showResetAlert = false

    var body: some View {
        List {
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
                Text("Privacy: tutto resta solo su questo iPhone (sandbox dell'app). Nessun server, nessuna rete, nessun account.")
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
