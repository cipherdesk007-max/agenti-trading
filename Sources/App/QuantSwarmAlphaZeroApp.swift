import SwiftUI
import SwiftData

@MainActor
@main
struct QuantSwarmAlphaZeroApp: App {
    @StateObject private var engine: QuantSwarmEngine
    private let container: ModelContainer

    init() {
        let keychain = KeychainManager()
        let background = BackgroundPersistenceManager()
        background.registerBackgroundTasks()
        do {
            container = try ModelContainer(for: TradeRecord.self)
            let engine = QuantSwarmEngine(
                keychain: keychain,
                background: background,
                container: container
            )
            _engine = StateObject(wrappedValue: engine)
        } catch {
            fatalError("Impossibile inizializzare SwiftData: \(error.localizedDescription)")
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

    var body: some View {
        Group {
            if engine.isConfigured {
                TerminalDashboardView()
            } else {
                LoginView()
            }
        }
        .task {
            await engine.restoreCredentials()
        }
    }
}
