import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { CalendarView() }
                .tabItem { Label("Calendario", systemImage: "calendar") }
            NavigationStack { SmokeTrackerView() }
                .tabItem { Label("No Smoke", systemImage: "lungs.fill") }
            NavigationStack { WorkoutView() }
                .tabItem { Label("Workout", systemImage: "figure.run") }
            NavigationStack { CustomTrackersView() }
                .tabItem { Label("Tracker", systemImage: "plus.square.on.square.fill") }
        }
        .tint(Theme.accent)
    }
}
