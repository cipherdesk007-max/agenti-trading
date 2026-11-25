import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { CalendarView() }
                .tabItem { Label("Giornata", systemImage: "clock.fill") }
            NavigationStack { SmokeTrackerView() }
                .tabItem { Label("No Smoke", systemImage: "lungs.fill") }
            NavigationStack { WorkoutView() }
                .tabItem { Label("Workout", systemImage: "figure.run") }
            NavigationStack { CustomTrackersView() }
                .tabItem { Label("Tracker", systemImage: "plus.square.on.square.fill") }
            NavigationStack { SystemView() }
                .tabItem { Label("Sistema", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
    }
}
