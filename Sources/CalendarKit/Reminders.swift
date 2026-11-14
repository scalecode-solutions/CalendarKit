import Foundation
import UserNotifications

/// One local notification to schedule.
public struct CalReminder: Equatable, Sendable {
    /// Stable: "calendarkit.<occurrence id>.<minutes>", so re-planning is a diff.
    public let id: String
    public let fireAt: Date
    public let title: String
    public let body: String
}

/// Decides which reminders should be pending now. Pure: tested without
/// notifications.
///
/// - An occurrence's reminders are its own event's, else its series' (an
///   exception inherits the series' unless it has its own).
/// - Timed: `minutes` before the start. All-day: before 00:00 of the first
///   day in the viewer's zone (900 = 9:00 the day before, -540 = 9:00 that day).
/// - Only the soonest `budget` that haven't fired yet. iOS keeps at most 64
///   pending requests per app, shared with the host's own, so the kit takes a
///   share (default 32) and the engine re-plans on every sync and foreground.
public enum ReminderPlanner {
    public static let prefix = "calendarkit."

    public static func plan(occurrences: [CalOccurrence], alerts: [UUID: [Int]], now: Date,
                            zone: TimeZone, budget: Int = 32,
                            me: UUID? = nil, defaults: CalAlertDefaults = CalAlertDefaults()) -> [CalReminder] {
        var out: [CalReminder] = []
        for o in occurrences {
            let minutes = effective(o, alerts: alerts, me: me, defaults: defaults)
            guard !minutes.isEmpty else { continue }
            let start: Date
            switch o.when {
            case .allDay(let s, _): start = CalRecurrenceExpander.wallClock(s, hour: 0, minute: 0, second: 0, in: zone)
            case .timed(let s, _, _): start = s
            }
            for m in Set(minutes) {
                let fire = start.addingTimeInterval(-Double(m) * 60)
                guard fire > now else { continue }
                out.append(CalReminder(id: "\(prefix)\(o.id).\(m)", fireAt: fire, title: o.title,
                                       body: body(o, zone: zone)))
            }
        }
        return Array(out.sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }.prefix(max(0, budget)))
    }

    /// The person's reminders for an occurrence: their own for the event, else
    /// for its series; with neither, their defaults if someone else added it
    /// (the product call, R20: a partner's events remind you like your own do).
    /// Anything set explicitly wins, including none.
    public static func effective(_ o: CalOccurrence, alerts: [UUID: [Int]], me: UUID?, defaults: CalAlertDefaults) -> [Int] {
        if let m = alerts[o.event.id] ?? o.seriesID.flatMap({ alerts[$0] }) { return m }
        guard let me, o.author != me else { return [] } // judged by the series' maker (Frond)
        return o.isAllDay ? defaults.allDay : defaults.timed
    }

    static func body(_ o: CalOccurrence, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = .current
        switch o.when {
        case .allDay(let s, let e):
            f.dateStyle = .full
            f.timeStyle = .none
            let first = f.string(from: CalRecurrenceExpander.wallClock(s, hour: 12, minute: 0, second: 0, in: zone))
            return s.days(to: e) > 1 ? "From \(first), all day" : "\(first), all day"
        case .timed(let s, _, _):
            f.dateStyle = .full
            f.timeStyle = .short
            let at = f.string(from: s)
            return o.event.fields.location.isEmpty ? at : "\(at) · \(o.event.fields.location)"
        }
    }
}

/// The slice of UNUserNotificationCenter the scheduler uses (faked in tests).
public protocol ReminderCenter: Sendable {
    func pendingIDs() async -> [String]
    func add(_ r: CalReminder) async throws
    func remove(_ ids: [String]) async
}

/// Makes the pending notifications match a plan: removes CalendarKit's that
/// aren't in it, adds the missing ones, and never touches the host's own.
public struct ReminderScheduler: Sendable {
    let center: any ReminderCenter

    public init(center: any ReminderCenter = SystemReminderCenter()) { self.center = center }

    /// Returns (added, removed).
    @discardableResult
    public func apply(_ plan: [CalReminder]) async -> (Int, Int) {
        let ours = Set(await center.pendingIDs().filter { $0.hasPrefix(ReminderPlanner.prefix) })
        let wanted = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stale = ours.subtracting(wanted.keys)
        if !stale.isEmpty { await center.remove(Array(stale)) }
        var added = 0
        for (id, r) in wanted where !ours.contains(id) {
            if (try? await center.add(r)) != nil { added += 1 }
        }
        return (added, stale.count)
    }

    /// Remove every CalendarKit reminder (sign-out, or reminders turned off).
    public func clear() async {
        let ours = await center.pendingIDs().filter { $0.hasPrefix(ReminderPlanner.prefix) }
        if !ours.isEmpty { await center.remove(ours) }
    }
}

/// The real notification center.
public struct SystemReminderCenter: ReminderCenter {
    public init() {}

    public func pendingIDs() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    public func add(_ r: CalReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = r.title
        content.body = r.body
        content.sound = .default
        content.threadIdentifier = "calendarkit"
        // An interval, not calendar components: components fire at a wall clock
        // in whatever zone the phone is in by then, an interval at the instant.
        let wait = r.fireAt.timeIntervalSinceNow
        guard wait > 1 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
    }

    public func remove(_ ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

private func < (a: (Date, String), b: (Date, String)) -> Bool { a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
