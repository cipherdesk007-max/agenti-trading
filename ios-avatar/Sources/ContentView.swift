import SwiftUI

enum AppTab: String, CaseIterable, Sendable {
    case home, giornata, nosmoke, workout, tracker, sistema

    /// Tab iniziale dall'argomento di lancio --tab=<nome> (usato dalla demo/screenshot in CI).
    /// Input non fidato: whitelist dei nomi, tutto il resto ricade su Home (fail-safe).
    static func tab(fromArgs args: [String]) -> AppTab {
        guard let arg = args.first(where: { $0.hasPrefix("--tab=") }) else { return .home }
        let raw = String(arg.dropFirst("--tab=".count)).lowercased()
        return AppTab(rawValue: raw) ?? .home
    }
}

struct ContentView: View {
    @State private var selectedTab = AppTab.tab(fromArgs: CommandLine.arguments)

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            NavigationStack { CalendarView() }
                .tabItem { Label("Giornata", systemImage: "clock.fill") }
                .tag(AppTab.giornata)
            NavigationStack { SmokeTrackerView() }
                .tabItem { Label("No Smoke", systemImage: "lungs.fill") }
                .tag(AppTab.nosmoke)
            NavigationStack { WorkoutView() }
                .tabItem { Label("Workout", systemImage: "figure.run") }
                .tag(AppTab.workout)
            NavigationStack { CustomTrackersView() }
                .tabItem { Label("Tracker", systemImage: "plus.square.on.square.fill") }
                .tag(AppTab.tracker)
            NavigationStack { SystemView() }
                .tabItem { Label("Sistema", systemImage: "gearshape.fill") }
                .tag(AppTab.sistema)
        }
        .tint(Theme.accent)
    }
}
