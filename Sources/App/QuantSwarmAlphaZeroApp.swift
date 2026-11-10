import SwiftUI
import SwiftData

@MainActor
@main
struct QuantSwarmAlphaZeroApp: App {
    @StateObject private var engine: QuantSwarmEngine
    private let container: ModelContainer

    init() {
        DiagnosticsCollector.shared.start()
        let keychain = KeychainManager()
        if let stored = try? ModelContainer(for: TradeRecord.self, DecisionSample.self) {
            container = stored
        } else {
            // Store corrotto o migrazione fallita: si azzera il database locale
            // (solo statistiche/dataset, mai credenziali o ordini) e si riprova.
            Self.wipePersistentStore()
            if let retried = try? ModelContainer(for: TradeRecord.self, DecisionSample.self) {
                container = retried
            } else {
                // Ultima spiaggia: store in memoria, nessun I/O su disco,
                // quindi non può fallire. L'app resta utilizzabile per il
                // trading anche se il database locale non si apre.
                // NOTA: con i modelli variadici, configurations è variadico
                // (non un array): le parentesi quadre rompono la compilazione.
                container = try! ModelContainer(
                    for: TradeRecord.self, DecisionSample.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            }
        }
        let engine = QuantSwarmEngine(
            keychain: keychain,
            container: container
        )
        _engine = StateObject(wrappedValue: engine)
    }

    /// Rimuove i file dello store SwiftData di default (Application Support).
    private static func wipePersistentStore() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .modelContainer(container)
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine

    /// Solo build di debug con argomento -QSPreview: dati di esempio per gli
    /// screenshot automatici della CI (nessuna rete, nessuna credenziale).
    static var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-QSPreview")
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if engine.isConfigured || Self.isPreview {
                TerminalDashboardView()
            } else {
                LoginView()
            }
        }
        .task {
            if Self.isPreview {
                #if DEBUG
                engine.loadPreviewState()
                #endif
                return
            }
            await engine.restoreCredentials()
            WidgetStatusBridge.write(engine: engine, force: true)
        }
        .onReceive(engine.$statusMessage) { _ in
            WidgetStatusBridge.write(engine: engine)
        }
        .onReceive(engine.$isRunning) { _ in
            WidgetStatusBridge.write(engine: engine, force: true)
        }
        .onReceive(engine.$account) { _ in
            WidgetStatusBridge.write(engine: engine)
        }
        .onReceive(engine.$positions) { _ in
            WidgetStatusBridge.write(engine: engine)
        }
        .onReceive(engine.$strategyConfig) { _ in
            WidgetStatusBridge.write(engine: engine, force: true)
        }
    }
}
