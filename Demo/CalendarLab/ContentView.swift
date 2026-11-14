import SwiftUI
import UserNotifications
import CalendarKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        #if DEBUG
        if let dev = DevSignIn.fromEnvironment() {
            CalendarLabHost(userID: dev.user, server: .local, tokenProvider: { dev.token }, signOut: {}, askNotifications: false)
        } else {
            signedIn
        }
        #else
        signedIn
        #endif
    }

    @ViewBuilder private var signedIn: some View {
        switch auth.state {
        case .loggedIn(let profile):
            CalendarLabHost(userID: profile.userID, server: auth.server,
                            tokenProvider: { [auth] in await auth.accessToken() },
                            signOut: { auth.logOut() })
                .id(profile.userID) // a fresh engine per identity
        default:
            LoginView(auth: auth)
        }
    }
}

#if DEBUG
/// Debug-only: skip the login with a token minted from the LOCAL key
/// (launch environment CAL_DEV_TOKEN + CAL_DEV_USER). Only meaningful against
/// the local stack; compiled out of release builds.
struct DevSignIn {
    let token: String
    let user: String

    static func fromEnvironment() -> DevSignIn? {
        let e = ProcessInfo.processInfo.environment
        guard let t = e["CAL_DEV_TOKEN"], let u = e["CAL_DEV_USER"], UUID(uuidString: u) != nil else { return nil }
        return DevSignIn(token: t, user: u)
    }
}
#endif

/// The dev host: builds a `CalendarEngine` with the Lab's token provider and
/// drives start/stop/wipe — the same seam a production host uses.
struct CalendarLabHost: View {
    let userID: String
    let server: LabServer
    let signOut: () -> Void
    let askNotifications: Bool
    @State private var engine: CalendarEngine
    @Environment(\.scenePhase) private var phase

    init(userID: String, server: LabServer, tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping () -> Void,
         askNotifications: Bool = true) {
        self.askNotifications = askNotifications
        self.userID = userID
        self.server = server
        self.signOut = signOut
        let config = CalendarConfig(baseURL: server.calendarBaseURL,
                                    currentUserID: UUID(uuidString: userID) ?? UUID(),
                                    tokenProvider: tokenProvider)
        _engine = State(initialValue: CalendarEngine(config: config))
    }

    var body: some View {
        // Hosted the way a production host does: the host owns the
        // bar — a big leading title, and a trailing button pushing the kit's
        // settings with the host's own section appended.
        NavigationStack {
            CalendarView(engine: engine)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Text("Calendar").font(.system(size: 28, weight: .bold)).fixedSize().padding(.horizontal, 8)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            CalendarSettingsView(engine: engine) { account }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Account")
                    }
                }
        }
        .task {
            engine.start()
            if askNotifications {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
        .onDisappear { engine.stop() }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: engine.start(); Task { await engine.replanReminders() }
            case .background: engine.stop()
            default: break
            }
        }
    }

    /// CalendarLab's own rows, appended to the kit's settings.
    private var account: some View {
        Section("Account") {
            LabeledContent("User ID") { Text(userID).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Server", value: server.rawValue)
            Button("Sync now") { Task { await engine.refresh() } }
            // Sign-out wipes this account's cache and queued writes (production hosts do the same).
            Button("Sign out", role: .destructive) {
                engine.wipeLocalStore()
                signOut()
            }
        }
    }
}
