import SwiftUI

/// CalendarLab — the harness app for CalendarKit. Logs into mvServer (real JWT
/// via MvAuth), then hosts the kit the way a production host does: engine built
/// with an injected token provider, started while the calendar is on screen,
/// wiped on sign-out. All calendar UI development happens here.
@main
struct CalendarLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.indigo)
        }
    }
}
