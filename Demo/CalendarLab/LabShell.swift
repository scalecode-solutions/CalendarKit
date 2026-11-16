import SwiftUI
import CalendarKit

/// CalendarLab hosted the way a chat app hosts the kit, so its entry points are
/// proven here before any host takes a new kit version:
///
/// - **Home**: a tile opening the all-calendars view (every pair on one grid).
/// - **Chats**: a conversation per friend. A 1:1 conversation's header has a
///   calendar button that PUSHES the calendar for the two of you, inside the
///   conversation's own navigation stack: backing out lands in the chat, and
///   the tab never changes.
/// - **Settings**: the kit's settings with the Lab's account rows.
///
/// The tab bar floats over the bottom of every screen, as a host's does, so a
/// layout that only fits without it fails here first.
struct LabShell<Account: View>: View {
    let session: LabSession
    @ViewBuilder let account: () -> Account
    @State private var tab: LabTab = .chats

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: LabTab.home) {
                LabHomeView(session: session)
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: LabTab.chats) {
                LabChatsView(session: session)
            }
            Tab("Settings", systemImage: "gearshape", value: LabTab.settings) {
                NavigationStack {
                    CalendarSettingsView(engine: session.engine) { account() }
                        .navigationTitle("Settings")
                }
            }
        }
    }
}

enum LabTab: Hashable {
    case home, chats, settings
}

// MARK: - Home

/// The home screen: tiles, the first of which is the all-calendars view.
struct LabHomeView: View {
    let session: LabSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink {
                        LabCalendarScreen(session: session, title: "Calendar")
                    } label: {
                        LabTile(title: "Calendar", subtitle: "Everyone you share with", symbol: "calendar")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.calendar")
                }
                .padding(16)
            }
            .navigationTitle("Home")
        }
    }
}

struct LabTile: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chats

/// One conversation per friend, from the calendar server's contact list (the
/// same friends a host's chat list would show).
struct LabChatsView: View {
    let session: LabSession
    @State private var friends: [CalContact] = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List(friends) { friend in
                NavigationLink {
                    LabConversationView(session: session, friend: friend)
                } label: {
                    Label(friend.name, systemImage: "person.circle")
                }
            }
            .overlay {
                if friends.isEmpty {
                    ContentUnavailableView(failed ? "Couldn't load friends" : "No friends yet",
                                           systemImage: "person.2")
                }
            }
            .navigationTitle("Chats")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            let me = session.engine.config.currentUserID
            friends = try await session.engine.contacts().filter { $0.id != me }
            failed = false
        } catch {
            failed = true
        }
    }
}

/// A stand-in conversation: a few placeholder bubbles, and the header button
/// that opens the two of you's calendar (pushed, like a host's map or calendar
/// button: backing out returns here).
struct LabConversationView: View {
    let session: LabSession
    let friend: CalContact
    @State private var showCalendar = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                LabBubble(text: "Here's where the conversation would be.", mine: false)
                LabBubble(text: "The calendar button is up top.", mine: true)
            }
            .padding(16)
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCalendar = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Calendar with \(friend.name)")
            }
        }
        .navigationDestination(isPresented: $showCalendar) {
            // The pair focus plugs in here once the kit has it (MVCALE-36):
            // this screen shows the calendar the two of you share.
            LabCalendarScreen(session: session, title: friend.name)
        }
    }
}

struct LabBubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 18))
                .foregroundStyle(mine ? .white : .primary)
            if !mine { Spacer(minLength: 40) }
        }
    }
}

// MARK: - The calendar, pushed

/// The kit's calendar as a pushed screen: a host's navigation stack above it
/// (the day view pushes onto the same stack), held while it's on screen.
struct LabCalendarScreen: View {
    let session: LabSession
    let title: String

    var body: some View {
        CalendarView(engine: session.engine)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .holdsCalendar(session)
    }
}
