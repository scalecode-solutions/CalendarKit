import Foundation

// The kit's own types: what hosts and views use. The generated protobuf types
// stay inside the transport.

/// A calendar day with no time or zone (all-day events, repeat ends).
public struct CalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Gregorian calendar fixed to UTC: day arithmetic never meets a DST change.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 00:00 UTC of the day (arithmetic and comparison only).
    var utcMidnight: Date {
        CalDate.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    init(utcMidnight d: Date) {
        let c = CalDate.utc.dateComponents([.year, .month, .day], from: d)
        self.init(c.year!, c.month!, c.day!)
    }

    /// The day `instant` falls on in `zone`.
    public init(_ instant: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: instant)
        self.init(c.year!, c.month!, c.day!)
    }

    /// Whether it's a real day (Feb 30 isn't).
    public var isValid: Bool {
        guard (1900...2200).contains(year), (1...12).contains(month), day >= 1 else { return false }
        return CalDate(utcMidnight: utcMidnight) == self
    }

    public func adding(days: Int) -> CalDate {
        CalDate(utcMidnight: CalDate.utc.date(byAdding: .day, value: days, to: utcMidnight)!)
    }

    /// Days from self to other (positive when other is later).
    public func days(to other: CalDate) -> Int {
        CalDate.utc.dateComponents([.day], from: utcMidnight, to: other.utcMidnight).day!
    }

    /// 1 = Monday ... 7 = Sunday (ISO).
    public var isoWeekday: Int {
        let w = CalDate.utc.component(.weekday, from: utcMidnight) // 1 = Sunday
        return (w + 5) % 7 + 1
    }

    public static func < (a: CalDate, b: CalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// What the caller may do with a calendar.
public enum CalRole: String, Sendable, Codable {
    case owner, edit, view
    public var canWrite: Bool { self != .view }
}

/// The color palette (`none` = no color set). Hosts map tokens to light and
/// dark colors; `CalColor+UI` has the kit's defaults.
public enum CalColor: String, CaseIterable, Sendable, Codable {
    case none = ""
    case red, orange, yellow, green, mint, teal, cyan, sky, blue, indigo, purple, pink, brown, gray
}

/// A calendar the caller can see: their own, or one shared with them.
public struct CalCalendar: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let ownerID: UUID
    /// "" = the host shows the owner's name.
    public var name: String
    public var color: CalColor
    public var role: CalRole
    /// The newest change on the server (the sync cursor's target).
    public var rev: Int64
    /// For a shared calendar: when the share ends (nil = never).
    public var grantExpiresAt: Date?
    /// The caller's own display preference.
    public var visible: Bool
    public var prefColor: CalColor

    /// What the engine draws it in when neither this person nor the owner chose
    /// a color: one apart from the person's own and the other calendars', from
    /// the owner's id (`CalCalendar.assignAutoColors`). Kept in this device's
    /// store so it doesn't move when friends come and go; never synced.
    public internal(set) var autoColor: CalColor? = nil

    public var isOwn: Bool { role == .owner }
    /// The color to draw it in for this person: their override, else the
    /// owner's, else the automatic one.
    public var displayColor: CalColor {
        prefColor != .none ? prefColor : color != .none ? color : autoColor ?? .none
    }
}

extension CalCalendar {
    /// The colors a calendar can be given automatically, ordered so that
    /// neighbours are far apart in hue: walking on from a taken one lands on a
    /// clearly different color. Gray and brown are left out (they read as
    /// "off"), and indigo comes last (it's the default for one's own).
    static let autoPalette: [CalColor] = [.orange, .teal, .pink, .green, .purple, .yellow,
                                          .sky, .red, .mint, .blue, .cyan, .indigo]

    /// Gives every other calendar without a color an automatic one; anything
    /// chosen (by this person or the owner) is left alone.
    ///
    /// - Colors in use are taken first: the person's own (indigo when unset)
    ///   and every chosen one. The two beside the person's own on the hue
    ///   wheel are skipped while anything else is free.
    /// - A calendar keeps the automatic color it already has (`autoColor`, as
    ///   the store remembers it) while that color is still free. So adding a
    ///   friend never recolors another one. What can: a color being chosen (it
    ///   gives way), or one beside the person's own being kept while a better
    ///   one is free (after the person changes their color, or a friend goes).
    /// - Each calendar left starts at a place in `autoPalette` from its owner's
    ///   id (stable across launches; Swift's `hashValue` isn't) and walks on to
    ///   the first free color, in owner-id order.
    /// - Once every color is taken, colors repeat: a calendar keeps the one it
    ///   had, else takes its id's slot.
    static func assignAutoColors(_ cals: [CalCalendar]) -> [CalCalendar] {
        var out = cals
        var taken: Set<CalColor> = []
        let ownChosen = out.first { $0.isOwn }?.displayColor ?? CalColor.none
        let own = ownChosen == .none ? CalColor.indigo : ownChosen
        taken.insert(own)
        let near = neighbours(of: own)
        func needsOne(_ c: CalCalendar) -> Bool { !c.isOwn && c.prefColor == .none && c.color == .none }
        for c in out where !needsOne(c) && !c.isOwn { taken.insert(c.displayColor) }
        let open = out.indices.filter { needsOne(out[$0]) }
            .sorted { (out[$0].ownerID.uuidString, out[$0].id.uuidString) < (out[$1].ownerID.uuidString, out[$1].id.uuidString) }
        // Those that already have one keep it first, so a newcomer can't take it.
        // One beside the person's own is kept only while nothing better is free
        // (it was given out when everything else was taken).
        var newcomers: [Int] = []
        var beside: [Int] = []
        for i in open {
            guard let kept = out[i].autoColor, autoPalette.contains(kept), !taken.contains(kept) else {
                newcomers.append(i); continue
            }
            if near.contains(kept) { beside.append(i) } else { taken.insert(kept) }
        }
        let betterFree = autoPalette.contains { !taken.contains($0) && !near.contains($0) }
        for i in beside {
            let kept = out[i].autoColor!
            if betterFree || taken.contains(kept) { newcomers.append(i) } else { taken.insert(kept) }
        }
        let n = autoPalette.count
        for i in newcomers {
            let start = stableIndex(out[i].ownerID, n)
            let walk = (0..<n).lazy.map { autoPalette[(start + $0) % n] }
            // Nothing free (more friends than colors): keep what it had, even
            // shared, so a full palette doesn't reshuffle on every pass.
            let had = out[i].autoColor.flatMap { autoPalette.contains($0) ? $0 : nil }
            let pick = walk.first { !taken.contains($0) && !near.contains($0) }
                ?? walk.first { !taken.contains($0) } ?? had ?? autoPalette[start]
            out[i].autoColor = pick
            taken.insert(pick)
        }
        // A calendar that has a color now (chosen) forgets its automatic one.
        for i in out.indices where !needsOne(out[i]) { out[i].autoColor = nil }
        return out
    }

    /// The colors either side of this one round the hue wheel (indigo: blue
    /// and purple). Too close to tell apart at a glance, so a friend gets them
    /// only once everything else is taken. Gray and brown have none.
    static func neighbours(of c: CalColor) -> Set<CalColor> {
        let wheel: [CalColor] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .sky, .blue, .indigo, .purple, .pink]
        guard let i = wheel.firstIndex(of: c) else { return [] }
        return [wheel[(i + wheel.count - 1) % wheel.count], wheel[(i + 1) % wheel.count]]
    }

    /// FNV-1a over the id's bytes, mod `n`: the same on every launch and device.
    static func stableIndex(_ id: UUID, _ n: Int) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        return Int(h % UInt64(n))
    }
}

/// A named tag on a calendar.
public struct CalLabel: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    public var name: String
    public var color: CalColor
    public var rev: Int64
}

/// When an event happens.
public enum CalWhen: Equatable, Sendable, Codable {
    /// All-day: [start, end), end exclusive (one day = d, d+1).
    case allDay(start: CalDate, end: CalDate)
    /// Timed: instants, plus the IANA zone the event was made in (repeats are
    /// expanded there, so 9:00 stays 9:00 across DST).
    case timed(start: Date, end: Date, timeZone: String)

    public var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    /// The day the event starts on, in its own zone.
    public var firstDay: CalDate {
        switch self {
        case .allDay(let s, _): return s
        case .timed(let s, _, let tz): return CalDate(s, in: TimeZone(identifier: tz) ?? .gmt)
        }
    }
}

public enum CalFrequency: String, Sendable, Codable, CaseIterable {
    case daily, weekly, monthly, yearly
}

/// Which day of each month a monthly series lands on, read from its start.
public enum CalMonthlyMode: String, Sendable, Codable {
    /// The 15th (months without that day are skipped).
    case dayOfMonth
    /// The 2nd Tuesday (n from the start; months without an n-th are skipped).
    case nthWeekday
    /// The last Friday.
    case lastWeekday
}

/// How a series repeats: the v1 subset of an RFC 5545 RRULE.
public struct CalRecurrence: Equatable, Sendable, Codable {
    public var frequency: CalFrequency
    public var interval: Int
    /// Weekly: ISO weekdays (1 = Monday ... 7 = Sunday). Empty = the start's.
    public var weekdays: [Int]
    public var monthly: CalMonthlyMode
    /// Inclusive last day, in the event's zone.
    public var until: CalDate?
    /// Number of occurrences (cancelled ones count).
    public var count: Int?

    public init(_ frequency: CalFrequency, interval: Int = 1, weekdays: [Int] = [],
                monthly: CalMonthlyMode = .dayOfMonth, until: CalDate? = nil, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.monthly = monthly
        self.until = until
        self.count = count
    }
}

/// What a writer sets on an event.
public struct CalEventFields: Equatable, Sendable, Codable {
    public var title: String
    public var notes: String
    public var location: String
    public var when: CalWhen
    public var labelID: UUID?
    public var color: CalColor
    public var recurrence: CalRecurrence?

    public init(title: String, notes: String = "", location: String = "", when: CalWhen,
                labelID: UUID? = nil, color: CalColor = .none, recurrence: CalRecurrence? = nil) {
        self.title = title
        self.notes = notes
        self.location = location
        self.when = when
        self.labelID = labelID
        self.color = color
        self.recurrence = recurrence
    }
}

/// The occurrence an exception replaces: its ORIGINAL start.
public enum CalOriginalStart: Hashable, Sendable, Codable {
    case date(CalDate)  // of an all-day series
    case instant(Date)  // of a timed series
}

/// One entry on a calendar: a single event, a series, or an exception to one
/// occurrence of a series.
public struct CalEvent: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    public var fields: CalEventFields
    public var masterID: UUID?
    public var originalStart: CalOriginalStart?
    public var cancelled: Bool
    public var createdBy: UUID
    public var updatedBy: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var rev: Int64
    /// A tombstone (only `id` and `rev` are meaningful).
    public var deleted: Bool

    public var isSeries: Bool { fields.recurrence != nil && masterID == nil }
    public var isException: Bool { masterID != nil }
}

/// The caller's reminders for one event (minutes before the start; all-day:
/// before 00:00 of the first day, so 900 = 9:00 the day before).
public struct CalAlert: Equatable, Sendable, Codable {
    public let eventID: UUID
    public var minutesBefore: [Int]
    public var rev: Int64
}

public struct CalAlertDefaults: Equatable, Sendable, Codable {
    public var timed: [Int]
    public var allDay: [Int]
    public init(timed: [Int] = [], allDay: [Int] = []) {
        self.timed = timed
        self.allDay = allDay
    }
}

/// A person the caller may share with.
public struct CalContact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let avatar: Data?
}

/// The owner sharing their calendar with one person.
public struct CalGrant: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let granteeID: UUID
    public var role: CalRole
    public var createdAt: Date
    public var expiresAt: Date?
    public var label: String
}

/// One row of the owner's history.
public struct CalActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// share | unshare | event_added | event_changed | event_deleted
    public let kind: String
    public let actorID: UUID?
    public let at: Date
    public let detail: String
    public let eventID: UUID?
}

/// Where this device is in one calendar: the server's rev it has seen, and,
/// while a paged full load is under way, the rev that load started at (the
/// server judges purges against it; 0 otherwise).
public struct CalCursor: Equatable, Sendable {
    public var rev: Int64
    public var loadFrom: Int64
    public init(rev: Int64, loadFrom: Int64 = 0) {
        self.rev = rev
        self.loadFrom = loadFrom
    }
}

/// One calendar's changes since a cursor.
public struct CalDelta: Equatable, Sendable {
    public let calendarID: UUID
    public let events: [CalEvent]
    public let labels: [CalLabel]
    public let deletedLabelIDs: [UUID]
    public let rev: Int64
    public let hasMore: Bool
    /// Drop everything held for this calendar first: the cursor was too old.
    public let reload: Bool
    /// While a full load is still paging: echo it back on the next cursor.
    public var loadFrom: Int64 = 0
}

/// One Sync answer.
public struct CalSyncPage: Equatable, Sendable {
    public let calendars: [CalCalendar]
    public let deltas: [CalDelta]
    public let gone: [UUID]
    public let alerts: [CalAlert]
    /// The next alerts cursor (the last alert sent, when the list was cut).
    public let alertsRev: Int64
    public let alertDefaults: CalAlertDefaults
    /// The alerts were cut at the server's per-Sync cap: sync again for the rest.
    public var alertsHasMore = false
}
