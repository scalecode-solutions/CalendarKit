import SwiftUI
import CalendarKit

/// CalendarLab hosted the way a chat app hosts the kit, so its entry points are
/// proven here before any host takes a new kit version:
///
/// - **Home**: a tile opening the all-calendars view (every pair on one grid).
/// - **Chats**: a conversation per friend. A 1:1 conversation's header has a
///   calendar button that PUSHES the calendar for the two of you, inside the
///   conversation's own navigation stack: backing out lands in the chat, and
///   the tab never changes. Tapping the name opens the conversation's
///   settings, where the pair calendar's own settings live (labels, activity,
///   privacy).
/// - **Settings**: the kit's settings with the Lab's account rows.
///
/// The tab bar floats over the bottom of every screen, as a host's does, so a
/// layout that only fits without it fails here first.
struct LabShell<Account: View>: View {
    let session: LabSession
    @ViewBuilder let account: () -> Account
    @State private var tab: LabTab = LabStart.fromEnvironment == .calendar ? .home : .chats
    @State private var hostPeople = LabHostPeople()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: LabTab.home) {
                LabHomeView(session: session, opensCalendar: LabStart.fromEnvironment == .calendar)
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: LabTab.chats) {
                LabChatsView(session: session)
            }
            Tab("Settings", systemImage: "gearshape", value: LabTab.settings) {
                NavigationStack {
                    CalendarSettingsView(engine: session.engine) {
                        account()
                        if LabHostPeople.on {
                            Section("Host people") {
                                Toggle("Host people", isOn: Binding(get: { hostPeople.enabled }, set: { hostPeople.enabled = $0 }))
                                    .accessibilityIdentifier("lab.host.toggle")
                                Button("Rename friend") { hostPeople.renames += 1 }
                                    .accessibilityIdentifier("lab.host.rename")
                            }
                        }
                    }
                        .navigationTitle("Settings")
                }
            }
        }
        .calendarHostPeople(hostPeople.people)
        // For the UI tests: whether the engine is running right now. Invisible,
        // and not hit-testable; VoiceOver users never land on it.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("lab.running")
                .accessibilityValue(session.isRunning ? "running" : "stopped")
        }
    }
}

enum LabTab: Hashable {
    case home, chats, settings
}

/// Where the Lab opens. Normally on Chats, as a chat host does. The kit's UI
/// tests set the launch environment `LAB_START=calendar` to open straight on
/// the calendar (Home → Calendar, pushed), so every test starts on the
/// calendar's own screen without driving the shell first.
enum LabStart: String {
    case calendar

    static var fromEnvironment: LabStart? {
        ProcessInfo.processInfo.environment["LAB_START"].flatMap(LabStart.init(rawValue:))
    }
}

// MARK: - Home

/// The home screen: tiles, the first of which is the all-calendars view.
struct LabHomeView: View {
    let session: LabSession
    @State private var path: [LabHomeRoute]

    init(session: LabSession, opensCalendar: Bool = false) {
        self.session = session
        _path = State(initialValue: opensCalendar ? [.calendar] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: LabHomeRoute.calendar) {
                        LabTile(title: "Calendar", subtitle: "Everyone you share with", symbol: "calendar")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.calendar")
                }
                .padding(16)
            }
            .navigationTitle("Home")
            .navigationDestination(for: LabHomeRoute.self) { route in
                switch route {
                case .calendar: LabCalendarScreen(session: session, title: "Calendar")
                }
            }
        }
    }
}

enum LabHomeRoute: Hashable {
    case calendar
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
                .accessibilityIdentifier("chat.\(friend.id.uuidString.lowercased())")
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
    @State private var showSettings = false

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
            // The name opens the conversation's settings, as a chat host's
            // header does: everything about the two of you lives there.
            ToolbarItem(placement: .principal) {
                Button {
                    showSettings = true
                } label: {
                    Text(friend.name).font(.headline).foregroundStyle(.primary)
                }
                .accessibilityLabel("\(friend.name), settings")
                .accessibilityIdentifier("conversation.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCalendar = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Calendar with \(friend.name)")
                .accessibilityIdentifier("conversation.calendar")
            }
        }
        .navigationDestination(isPresented: $showCalendar) {
            // The two of you's pair calendar: focused on this friend, so the
            // kit's picker hides (MVCALE-36).
            LabCalendarScreen(session: session, title: friend.name, focus: .person(friend.id))
        }
        .navigationDestination(isPresented: $showSettings) {
            LabConversationSettings(session: session, friend: friend)
        }
    }
}

/// A stand-in for a chat host's conversation settings (tap the name): the
/// pair calendar's own settings (labels, activity, privacy) live here, not in
/// the calendar's personal settings.
struct LabConversationSettings: View {
    let session: LabSession
    let friend: CalContact
    /// The pair's settings read and write through the engine, so it runs
    /// while this page (or the pair page pushed over it) is on screen, as on a
    /// calendar screen (Leaf's review: cold, the page waited forever).
    @State private var hold = LabCalendarHold()

    var body: some View {
        List {
            Section {
                LabeledContent("Messages", value: "A host's own rows go here")
                    .foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    PairSettingsView(engine: session.engine, otherID: friend.id)
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
                .accessibilityIdentifier("conversation.settings.calendar")
            } footer: {
                Text("Labels, activity and privacy for the calendar you two share.")
            }
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hold.arm(session) }
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
    /// A conversation's pair; nil for the all-calendars view (the kit's picker).
    var focus: CalFocus? = nil
    @State private var hold = LabCalendarHold()

    var body: some View {
        CalendarView(engine: session.engine, focus: focus.map { .constant($0) })
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The calendar's settings, pushed from its own screen as a
                // host's gear does (the kit's UI tests reach them here).
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CalendarSettingsView(engine: session.engine) { EmptyView() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            .onAppear { hold.arm(session) }
    }
}

/// The Lab as a host that knows its own names and photos (LAB_HOST_PEOPLE=1):
/// it calls LAB_FRIEND "Lab Host Friend" and draws a photo for them, through
/// `calendarHostPeople`. Observable, so a rename or turning it off in Settings
/// redraws the kit's open screens. Unset, the Lab is a host with no people.
@MainActor @Observable
final class LabHostPeople {
    static var on: Bool { ProcessInfo.processInfo.environment["LAB_HOST_PEOPLE"] == "1" }
    static var friend: UUID? { ProcessInfo.processInfo.environment["LAB_FRIEND"].flatMap(UUID.init(uuidString:)) }

    var enabled = true
    var renames = 0

    var people: CalendarHostPeople {
        guard Self.on, let friend = Self.friend else { return .none }
        return CalendarHostPeople(
            name: { [self] id in
                guard enabled, id == friend else { return nil }
                return renames == 0 ? "Lab Host Friend" : "Lab Host Friend \(renames + 1)"
            },
            avatar: { [self] id, size in
                guard enabled, id == friend else { return nil }
                return AnyView(LabHostPhoto(size: size))
            })
    }
}

/// The Lab's stand-in for a host's photo: unmistakable, and findable by tests.
private struct LabHostPhoto: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Color.purple
            Image(systemName: "star.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Host photo")
        .accessibilityIdentifier("lab.host.avatar")
    }
}
