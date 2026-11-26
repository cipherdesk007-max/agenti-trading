import SwiftUI

@main
struct AvatarFitApp: App {
    @State private var store = AppStore()

    init() {
        CrashLog.install()
        UserDefaults.standard.set(Date().ISO8601Format(), forKey: "ultimoAvvio")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
