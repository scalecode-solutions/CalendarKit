import Foundation

/// One thing on the calendar at one time: a single event, or one occurrence of
/// a series (possibly changed by an exception). What views draw.
public struct CalOccurrence: Identifiable, Equatable, Sendable {
    /// Stable per occurrence: the series (or event) id + its original start.
    public let id: String
    /// The event to show: the single event, the exception, or the series.
    public let event: CalEvent
    /// The series it belongs to (nil for a single event).
    public let seriesID: UUID?
    /// Which occurrence of the series this is (nil for a single event).
    public let originalStart: CalOriginalStart?
    /// When this occurrence happens.
    public let when: CalWhen
    public let calendar: CalCalendar
    public let label: CalLabel?
    /// event color → label color → the calendar's display color (or, inside
    /// one pair, who added it: the person's own color for theirs).
    public let color: CalColor
    /// Who made it: the series' creator for an occurrence of a series (even a
    /// changed one), else the event's.
    public let author: UUID

    public var title: String { event.fields.title }
    public var isAllDay: Bool { when.isAllDay }

    /// Sort key: all-day first, then by start.
    var sortKey: (Int, Date, String) {
        switch when {
        case .allDay(let s, _): return (0, s.utcMidnight, title)
        case .timed(let s, _, _): return (1, s, title)
        }
    }
}

/// Builds occurrences from cached events. Pure: tested without a store.
enum OccurrenceBuilder {
    /// Everything on these calendars that touches [from, through] (days in `zone`,
    /// the viewer's).
    /// `byAuthor`: inside one pair, an uncolored event takes its author's
    /// color (the person's own for theirs, the pair's for the other's) instead
    /// of the pair's.
    static func build(events: [CalEvent], exceptions: [CalEvent], calendars: [UUID: CalCalendar],
                      labels: [UUID: CalLabel], from: CalDate, through: CalDate, zone: TimeZone,
                      byAuthor: (me: UUID, mine: CalColor)? = nil) -> [CalOccurrence] {
        let rangeStart = start(of: from, in: zone), rangeEnd = start(of: through.adding(days: 1), in: zone)
        let byMaster = Dictionary(grouping: exceptions.filter { !$0.deleted }, by: { $0.masterID! })
        var out: [CalOccurrence] = []

        func overlaps(_ w: CalWhen) -> Bool {
            switch w {
            case .allDay(let s, let e): return s <= through && e > from
            case .timed(let s, let e, _): return s < rangeEnd && (e > rangeStart || (e == s && s >= rangeStart))
            }
        }
        func occurrence(_ shown: CalEvent, series: CalEvent?, original: CalOriginalStart?, when: CalWhen) -> CalOccurrence? {
            guard let cal = calendars[shown.calendarID] else { return nil }
            let label = shown.fields.labelID.flatMap { labels[$0] }
            let author = (series ?? shown).createdBy
            let fallback = byAuthor.map { author == $0.me ? $0.mine : cal.displayColor } ?? cal.displayColor
            let color = shown.fields.color != .none ? shown.fields.color
                : (label?.color ?? .none) != .none ? label!.color : fallback
            let base = (series ?? shown).id.uuidString
            let id: String
            switch original {
            case .date(let d): id = "\(base)/\(d)"
            case .instant(let t): id = "\(base)/\(Int64(t.timeIntervalSince1970))"
            case nil: id = base
            }
            return CalOccurrence(id: id, event: shown, seriesID: series?.id, originalStart: original, when: when,
                                 calendar: cal, label: label, color: color, author: author)
        }

        for e in events where !e.deleted && e.masterID == nil {
            guard let rule = e.fields.recurrence else {
                if overlaps(e.fields.when), let o = occurrence(e, series: nil, original: nil, when: e.fields.when) { out.append(o) }
                continue
            }
            let exs = byMaster[e.id] ?? []
            let exByStart = Dictionary(exs.compactMap { x in x.originalStart.map { ($0, x) } }, uniquingKeysWith: { a, _ in a })
            // Expand from just before the range (zones can differ by a day) to
            // just after it, widened to every exception's original so a moved
            // occurrence is matched; nothing earlier is generated (R23).
            var horizon = through.adding(days: 1)
            var earliest = from.adding(days: -2)
            for x in exs {
                var d: CalDate?
                switch x.originalStart {
                case .date(let day): d = day
                case .instant(let t):
                    if case .timed(_, _, let tz) = e.fields.when { d = CalDate(t, in: TimeZone(identifier: tz) ?? .gmt) }
                case nil: break
                }
                if let d { horizon = max(horizon, d); earliest = min(earliest, d) }
            }
            for (original, when) in expand(e, rule: rule, from: earliest, through: horizon) {
                if let x = exByStart[original] {
                    if x.cancelled { continue }
                    if overlaps(x.fields.when), let o = occurrence(x, series: e, original: original, when: x.fields.when) { out.append(o) }
                } else if overlaps(when), let o = occurrence(e, series: e, original: original, when: when) {
                    out.append(o)
                }
            }
        }
        return out.sorted { $0.sortKey < $1.sortKey }
    }

    /// A series' occurrences from `from` (its days; nil = the start) up to
    /// `through`: (original start, when).
    static func expand(_ e: CalEvent, rule: CalRecurrence, from: CalDate? = nil, through: CalDate) -> [(CalOriginalStart, CalWhen)] {
        switch e.fields.when {
        case .allDay(let s, let end):
            let len = s.days(to: end)
            // An all-day occurrence that starts before `from` can still reach into it.
            return CalRecurrenceExpander.dates(rule, first: s, from: from?.adding(days: -len), through: through).map { d in
                (.date(d), .allDay(start: d, end: d.adding(days: len)))
            }
        case .timed(let s, let end, let tz):
            let zone = TimeZone(identifier: tz) ?? .gmt
            let duration = end.timeIntervalSince(s)
            // Likewise a long timed one: back off by its length in days.
            let back = Int((duration / 86_400).rounded(.up))
            return CalRecurrenceExpander.instants(rule, start: s, timeZone: zone, from: from?.adding(days: -back),
                                                  through: through).map { t in
                (.instant(t), .timed(start: t, end: t.addingTimeInterval(duration), timeZone: tz))
            }
        }
    }

    static func start(of d: CalDate, in zone: TimeZone) -> Date {
        CalRecurrenceExpander.wallClock(d, hour: 0, minute: 0, second: 0, in: zone)
    }
}

private func < (a: (Int, Date, String), b: (Int, Date, String)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    return a.2 < b.2
}
