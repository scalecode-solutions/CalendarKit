import SwiftUI
import CalendarKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        #if DEBUG
        if let dev = DevSignIn.fromEnvironment() {
            CalendarLabHost(userID: dev.user, server: .local, tokenProvider: { dev.token }, signOut: {})
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
/// hosts it the way a chat app does (`LabShell`: tabs, conversations, a home
/// tile). `LabSession` runs the engine while a calendar is on screen and the
/// app is in the foreground; sign-out wipes it, as a production host does.
struct CalendarLabHost: View {
    let userID: String
    let server: LabServer
    let signOut: () -> Void
    @State private var session: LabSession
    @Environment(\.scenePhase) private var phase

    init(userID: String, server: LabServer, tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping () -> Void) {
        self.userID = userID
        self.server = server
        self.signOut = signOut
        let config = CalendarConfig(baseURL: server.calendarBaseURL,
                                    currentUserID: UUID(uuidString: userID) ?? UUID(),
                                    tokenProvider: tokenProvider)
        _session = State(initialValue: LabSession(engine: CalendarEngine(config: config)))
    }

    var body: some View {
        LabShell(session: session) { account }
            .onChange(of: phase, initial: true) { _, p in
                session.setForeground(p != .background)
            }
    }

    /// CalendarLab's own rows, appended to the kit's settings.
    private var account: some View {
        Section("Account") {
            LabeledContent("User ID") { Text(userID).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Server", value: server.rawValue)
            Button("Sync now") { Task { await session.engine.refresh() } }
            // Sign-out wipes this account's cache and queued writes (production hosts do the same).
            Button("Sign out", role: .destructive) {
                session.wipe()
                signOut()
            }
        }
    }
}
