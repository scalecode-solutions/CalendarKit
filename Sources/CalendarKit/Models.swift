import Foundation
import CryptoKit

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

/// The color palette (`none` = no color set). Hosts map tokens to light and
/// dark colors; `CalColor+UI` has the kit's defaults.
public enum CalColor: String, CaseIterable, Sendable, Codable {
    case none = ""
    case red, orange, yellow, green, mint, teal, cyan, sky, blue, indigo, purple, pink, brown, gray
}

/// A pair calendar: one the caller keeps together with one other person.
/// There's no owner: both of them read and change everything on it. Its id is
/// computed from the two (`CalPairID`), so a pair exists on this device before
/// the server has a row for it.
public struct CalCalendar: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// The other member.
    public let otherID: UUID
    /// "" = the host shows the other member's name.
    public var name: String
    /// The newest change on the server (the sync cursor's target).
    public var rev: Int64
    /// The two aren't friends any more: everything stays readable, nothing can
    /// be changed. Back to false the moment they are again.
    public var frozen: Bool
    /// The caller's own display preference (false: hidden for them).
    public var visible: Bool
    public var prefColor: CalColor
    /// Consent (0.8.0, PROVISIONAL): each member's own, per kind. Intimate
    /// entries exist for this pair only while both are on.
    public var intimateMine = false
    public var intimateTheirs = false
    public var cycleMine = false
    public var cycleTheirs = false
    /// The server's newest private change (meaningless while it's off).
    public var intimateRev: Int64 = 0
    /// Where this device is in the private stream. This device's, never synced.
    public internal(set) var intimateCursor: Int64 = 0
    /// The server's newest cycle change, and where this device is in it.
    public var cycleRev: Int64 = 0
    public internal(set) var cycleCursor: Int64 = 0
    /// Both members have turned cycle tracking on.
    public var cycleOn: Bool { cycleMine && cycleTheirs }
    /// Both members have turned intimate entries on.
    public var intimateOn: Bool { intimateMine && intimateTheirs }

    /// Whether the server has listed it. A pair nobody has opened yet is shown
    /// from the caller's contacts (false) until its first write opens it.
    public internal(set) var listed: Bool = true

    /// What the engine draws it in when the person chose no color: one apart
    /// from their own accent and the other pairs', from the other member's id
    /// (`CalCalendar.assignAutoColors`). Kept in this device's store so it
    /// doesn't move when friends come and go; never synced.
    public internal(set) var autoColor: CalColor? = nil

    public init(id: UUID, otherID: UUID, name: String = "", rev: Int64 = 0, frozen: Bool = false,
                visible: Bool = true, prefColor: CalColor = .none) {
        self.id = id
        self.otherID = otherID
        self.name = name
        self.rev = rev
        self.frozen = frozen
        self.visible = visible
        self.prefColor = prefColor
    }

    private enum CodingKeys: String, CodingKey {
        case id, otherID, name, rev, frozen, visible, prefColor, listed, autoColor
        case intimateMine, intimateTheirs, cycleMine, cycleTheirs, intimateRev, intimateCursor, cycleRev, cycleCursor
    }

    /// Reads 0.7.x's stored payloads too (no consent fields then).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        otherID = try c.decode(UUID.self, forKey: .otherID)
        name = try c.decode(String.self, forKey: .name)
        rev = try c.decode(Int64.self, forKey: .rev)
        frozen = try c.decode(Bool.self, forKey: .frozen)
        visible = try c.decode(Bool.self, forKey: .visible)
        prefColor = try c.decode(CalColor.self, forKey: .prefColor)
        listed = try c.decode(Bool.self, forKey: .listed)
        autoColor = try c.decodeIfPresent(CalColor.self, forKey: .autoColor)
        intimateMine = try c.decodeIfPresent(Bool.self, forKey: .intimateMine) ?? false
        intimateTheirs = try c.decodeIfPresent(Bool.self, forKey: .intimateTheirs) ?? false
        cycleMine = try c.decodeIfPresent(Bool.self, forKey: .cycleMine) ?? false
        cycleTheirs = try c.decodeIfPresent(Bool.self, forKey: .cycleTheirs) ?? false
        intimateRev = try c.decodeIfPresent(Int64.self, forKey: .intimateRev) ?? 0
        intimateCursor = try c.decodeIfPresent(Int64.self, forKey: .intimateCursor) ?? 0
        cycleRev = try c.decodeIfPresent(Int64.self, forKey: .cycleRev) ?? 0
        cycleCursor = try c.decodeIfPresent(Int64.self, forKey: .cycleCursor) ?? 0
    }

    /// The color to draw it in for this person: their choice, else the
    /// automatic one.
    public var displayColor: CalColor { prefColor != .none ? prefColor : autoColor ?? .none }
}

/// A pair calendar's id: UUIDv5 (SHA-1) in the pair namespace over the two
/// people's 16-byte ids, lower first in byte order. The server computes the
/// same (it never takes one from a client), so both phones know a pair's id
/// before it exists anywhere.
public enum CalPairID {
    /// Part of the wire contract with the server: never change it.
    public static let namespace = UUID(uuidString: "1cb2b0c2-a02e-4ef6-8d47-1f8f5c22fbfc")!

    public static func make(_ a: UUID, _ b: UUID) -> UUID {
        let (x, y) = (bytes(a), bytes(b))
        let (lo, hi) = x.lexicographicallyPrecedes(y) ? (x, y) : (y, x)
        return v5(namespace: namespace, name: lo + hi)
    }

    static func bytes(_ u: UUID) -> [UInt8] { withUnsafeBytes(of: u.uuid) { Array($0) } }

    /// RFC 4122 §4.3: SHA-1 of namespace bytes + name, version 5, variant 10.
    static func v5(namespace: UUID, name: [UInt8]) -> UUID {
        var h = Array(Insecure.SHA1.hash(data: bytes(namespace) + name)).prefix(16).map { $0 }
        h[6] = (h[6] & 0x0F) | 0x50
        h[8] = (h[8] & 0x3F) | 0x80
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                           h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
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
    static func assignAutoColors(_ cals: [CalCalendar], own: CalColor = .indigo) -> [CalCalendar] {
        var out = cals
        var taken: Set<CalColor> = []
        let own = own == .none ? CalColor.indigo : own
        taken.insert(own)
        let near = neighbours(of: own)
        func needsOne(_ c: CalCalendar) -> Bool { c.prefColor == .none }
        for c in out where !needsOne(c) { taken.insert(c.displayColor) }
        let open = out.indices.filter { needsOne(out[$0]) }
            .sorted { (out[$0].otherID.uuidString, out[$0].id.uuidString) < (out[$1].otherID.uuidString, out[$1].id.uuidString) }
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
            let start = stableIndex(out[i].otherID, n)
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

/// A person the caller has (or can open) a pair calendar with, or the caller.
public struct CalContact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let avatar: Data?
}

/// One row of a pair calendar's history (either member's change).
public struct CalActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// event_added | event_changed | event_deleted
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
    /// The private stream's cursor (0 = none held).
    public var intimate: Int64
    /// The cycle stream's cursor (0 = none held).
    public var cycle: Int64
    public init(rev: Int64, loadFrom: Int64 = 0, intimate: Int64 = 0, cycle: Int64 = 0) {
        self.rev = rev
        self.loadFrom = loadFrom
        self.intimate = intimate
        self.cycle = cycle
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
    /// The pair's private stream (empty unless both members consented).
    public var privateDelta: CalPrivateDelta = .none
    /// The pair's cycle stream (empty unless both members consented to cycle).
    public var cycleDelta: CalCycleDelta = .none
}

/// One Sync answer.
public struct CalSyncPage: Equatable, Sendable {
    public let calendars: [CalCalendar]
    public let deltas: [CalDelta]
    public let gone: [UUID]
}
