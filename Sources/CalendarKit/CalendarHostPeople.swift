import SwiftUI

/// What the host knows about people, for the kit's views: the name it shows
/// and the photo it draws. Every field is optional; a nil answer (or no host
/// at all, `.none`) falls back to the server's people directory, exactly as
/// without a host.
///
/// The closures run while a view draws, so reading observable host state there
/// keeps open screens live. Nothing a host returns is sent to the server, and
/// a pair's own name (what someone typed for that calendar) still beats the
/// host's name for the person. Calendar doesn't show presence; the field is
/// carried so every kit's hook has one shape.
public struct CalendarHostPeople: Sendable {
    /// The person's display name, already formatted by the host. nil or
    /// empty: the directory's name.
    public var name: @MainActor @Sendable (UUID) -> String?
    /// A short form for tight spots (the focus chips). nil: the host's name
    /// whole; the kit never splits a host's name.
    public var shortName: @MainActor @Sendable (UUID) -> String?
    /// The host draws the person's photo itself, at `size` points (the kit
    /// clips it to a circle). nil: the directory's photo, else initials.
    public var avatar: @MainActor @Sendable (UUID, CGFloat) -> AnyView?
    /// Not shown by Calendar.
    public var presence: @MainActor @Sendable (UUID) -> CalendarHostPresence?

    public init(name: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                shortName: @escaping @MainActor @Sendable (UUID) -> String? = { _ in nil },
                avatar: @escaping @MainActor @Sendable (UUID, CGFloat) -> AnyView? = { _, _ in nil },
                presence: @escaping @MainActor @Sendable (UUID) -> CalendarHostPresence? = { _ in nil }) {
        self.name = name
        self.shortName = shortName
        self.avatar = avatar
        self.presence = presence
    }

    /// No host: the directory alone.
    public static let none = CalendarHostPeople()

    /// The host's name for `id`, if it has a non-empty one.
    @MainActor func hostName(_ id: UUID) -> String? {
        name(id).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A person's presence as the host shows it (carried for the shared shape;
/// Calendar doesn't display it).
public enum CalendarHostPresence: Sendable, Equatable {
    case active
    case background(lastSeen: Date?)
    case lastSeen(Date?)
}

extension EnvironmentValues {
    @Entry public var calendarHostPeople: CalendarHostPeople = .none
}

public extension View {
    /// Show people in the kit's views as the host does: its names and photos.
    /// Fields left nil keep the kit's own.
    func calendarHostPeople(_ people: CalendarHostPeople) -> some View {
        environment(\.calendarHostPeople, people)
    }
}

// MARK: - Names, host first (view-side only)

extension CalendarEngine {
    /// What to call a pair in a view: its own name, else the host's name for the
    /// other person, else the directory's, else "Someone". The engine's own
    /// `displayName(_:)` (no host) keeps its sort order, and with it the saved
    /// auto colours, independent of host renames.
    public func displayName(_ c: CalCalendar, host: CalendarHostPeople) -> String {
        if !c.name.isEmpty { return c.name }
        if let n = host.hostName(c.otherID) { return n }
        return displayName(c)
    }

    /// A short name for a pair (the focus chips): its own name's first word, as
    /// before; else the host's short name, or the host's name whole (never
    /// split); else the directory's first word.
    public func shortName(_ c: CalCalendar, host: CalendarHostPeople) -> String {
        if c.name.isEmpty, host.hostName(c.otherID) != nil {
            if let s = host.shortName(c.otherID), !s.isEmpty { return s }
            return host.hostName(c.otherID)!
        }
        let full = displayName(c)
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// A person's name, host first, then the directory; nil when neither knows
    /// them (a friend no longer, an account gone).
    public func personName(_ id: UUID, host: CalendarHostPeople) -> String? {
        if let n = host.hostName(id) { return n }
        return people[id].flatMap { $0.name.isEmpty ? nil : $0.name }
    }
}
