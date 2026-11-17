import Foundation

// Cycle tracking (0.8.0 design sprint, MVCALE-28; PROVISIONAL). Days the
// person logs, and estimates made on the phone from them. Estimates, not
// advice: "Estimates only. Not a medical device or birth control." (plan
// decision 12, shortened in the design review of 2026-11-16).

/// How a logged day flows. Spotting is its own mark and never starts a cycle
/// (plan decision 13).
public enum CalFlow: String, CaseIterable, Sendable, Codable {
    case spotting, light, medium, heavy
    public var startsAPeriod: Bool { self != .spotting }
}

/// One logged day of one person's cycle, on a pair calendar: its flow, and
/// whether a period was marked as starting or ending on it (MVCALE-52: two
/// taps a period, daily flow optional). One row per person per day.
public struct CalCycleDay: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    /// Whose cycle: one of the pair's two members.
    public let personID: UUID
    public var date: CalDate
    /// nil: not given (a day marked only as a start or an end).
    public var flow: CalFlow?
    /// A period was marked as starting here.
    public var starts: Bool
    /// A period was marked as ending here (its last day).
    public var ends: Bool
    public var rev: Int64
    public var deleted: Bool

    public init(id: UUID = UUID(), calendarID: UUID, personID: UUID, date: CalDate, flow: CalFlow?,
                starts: Bool = false, ends: Bool = false, rev: Int64 = 0, deleted: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.personID = personID
        self.date = date
        self.flow = flow
        self.starts = starts
        self.ends = ends
        self.rev = rev
        self.deleted = deleted
    }

    /// Nothing on it: no flow, no mark (deleted rather than saved).
    public var isEmpty: Bool { flow == nil && !starts && !ends }

    private enum CodingKeys: String, CodingKey { case id, calendarID, personID, date, flow, starts, ends, rev, deleted }

    /// Days stored before marks existed read as unmarked.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        calendarID = try c.decode(UUID.self, forKey: .calendarID)
        personID = try c.decode(UUID.self, forKey: .personID)
        date = try c.decode(CalDate.self, forKey: .date)
        flow = try c.decodeIfPresent(CalFlow.self, forKey: .flow)
        starts = try c.decodeIfPresent(Bool.self, forKey: .starts) ?? false
        ends = try c.decodeIfPresent(Bool.self, forKey: .ends) ?? false
        rev = try c.decode(Int64.self, forKey: .rev)
        deleted = try c.decode(Bool.self, forKey: .deleted)
    }
}

/// One period: its first day, and its last when known (nil: still open).
public struct CalPeriod: Equatable, Sendable {
    public let start: CalDate
    public let end: CalDate?
    /// From the marks (MVCALE-52), not inferred from a run of logged days.
    public let marked: Bool
}

/// A person's cycle settings (0 = measure from what's logged).
public struct CalCycleSettings: Equatable, Sendable, Codable {
    public let calendarID: UUID
    public let personID: UUID
    public var cycleLength: Int
    public var periodLength: Int
    public var rev: Int64

    public init(calendarID: UUID, personID: UUID, cycleLength: Int = 0, periodLength: Int = 0, rev: Int64 = 0) {
        self.calendarID = calendarID
        self.personID = personID
        self.cycleLength = cycleLength
        self.periodLength = periodLength
        self.rev = rev
    }
}

/// One calendar's cycle changes since its cursor.
public struct CalCycleDelta: Equatable, Sendable {
    public let days: [CalCycleDay]
    public let settings: [CalCycleSettings]
    public let rev: Int64
    public let hasMore: Bool
    /// Cycle consent is off: drop every cycle row held for this calendar.
    public let reset: Bool

    public static let none = CalCycleDelta(days: [], settings: [], rev: 0, hasMore: false, reset: false)
}

/// What a day is in a person's cycle, for drawing (the grid's bands) and the
/// detail ("day 13, fertile window").
public struct CalCycleDayInfo: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Logged bleeding (or spotting) on this day.
        case logged(CalFlow)
        /// A day inside a marked period with no flow logged on it (MVCALE-52).
        case inPeriod
        /// An estimated period day (not logged).
        case predictedPeriod
        /// The estimated fertile window (ovulation's day included).
        case fertile(ovulation: Bool)
    }
    public let kind: Kind?
    /// 1-based day of the cycle, when there's a cycle start before it.
    public let cycleDay: Int?
    /// The day is past an open period's usual length: ask whether it ended.
    public var askIfEnded = false
    /// The open period this day belongs to, if any (offers "Ended today").
    public var openPeriod: CalPeriod?

    public init(kind: Kind?, cycleDay: Int?, askIfEnded: Bool = false, openPeriod: CalPeriod? = nil) {
        self.kind = kind
        self.cycleDay = cycleDay
        self.askIfEnded = askIfEnded
        self.openPeriod = openPeriod
    }
}

/// Estimates from logged days, the calendar method (ACOG): a period starts
/// on a logged non-spotting day after a gap; the cycle length is the average
/// of the last up to six cycles, else the person's setting, else 28; the
/// period length likewise, else 5. Ovulation is about 14 days before the next
/// start, and the fertile window is the 5 days before it plus that day.
public struct CalCycleEstimator: Sendable {
    public let days: [CalCycleDay]
    public let settings: CalCycleSettings?

    public init(days: [CalCycleDay], settings: CalCycleSettings?) {
        self.days = days.filter { !$0.deleted }.sorted { $0.date < $1.date }
        self.settings = settings
    }

    /// Each period, oldest first (MVCALE-52), from one pass over the days:
    /// - A period begins at a "Period started" mark or at a bleeding day
    ///   (spotting never begins one), unless it's less than 15 days after the
    ///   last period began (mid-cycle bleeding, not a new period).
    /// - It goes on through bleeding days at most 3 days apart; a "Period
    ///   started" mark inside it marks it rather than beginning another.
    /// - A "Period ended" mark within 15 days of its start ends it, whether it
    ///   began with a mark or with a flow (Leaf's review); an end with no
    ///   period before it is ignored.
    /// - Otherwise a marked period stays open until ended, and an unmarked
    ///   one (flows alone, or days logged before marks existed) ends at its
    ///   last bleeding day.
    public var periods: [CalPeriod] {
        var out: [CalPeriod] = []
        var cur: (start: CalDate, last: CalDate, marked: Bool)?
        func close(end: CalDate?) {
            guard let c = cur else { return }
            out.append(CalPeriod(start: c.start, end: end ?? (c.marked ? nil : c.last), marked: c.marked))
            cur = nil
        }
        for d in days {
            let bleeding = d.flow?.startsAPeriod ?? false
            if let c = cur {
                let inRun = c.marked ? c.start.days(to: d.date) < 15 : c.last.days(to: d.date) <= 3
                if d.ends && c.start.days(to: d.date) < 15 && (inRun || !bleeding) {
                    if bleeding || d.starts { cur?.last = d.date }
                    close(end: d.date)
                    continue
                }
                if inRun {
                    if bleeding { cur?.last = d.date }
                    if d.starts { cur?.marked = true }
                    continue
                }
                if bleeding || d.starts { close(end: nil) } else { continue }
            }
            guard bleeding || d.starts else { continue } // an end, or spotting, on its own
            if let prev = out.last, prev.start.days(to: d.date) < 15 { continue }
            cur = (d.date, d.date, d.starts)
            if d.ends { close(end: d.date) }
        }
        close(end: nil)
        return out
    }

    /// The first day of each period.
    public var starts: [CalDate] { periods.map(\.start) }

    /// The average of the last up to six cycles, else the setting, else 28.
    public var cycleLength: Int {
        let s = starts
        if s.count >= 2 {
            let gaps = zip(s, s.dropFirst()).map { $0.days(to: $1) }.filter { (15...60).contains($0) }.suffix(6)
            if !gaps.isEmpty { return Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded()) }
        }
        if let c = settings?.cycleLength, c > 0 { return c }
        return 28
    }

    /// The average length of the last up to six finished periods (a marked
    /// start to its marked end, or a run's first to last bleeding day), else
    /// the setting, else 5. An open period doesn't count until it ends.
    public var periodLength: Int {
        let lengths = periods.compactMap { p in p.end.map { p.start.days(to: $0) + 1 } }
        let recent = lengths.suffix(6).filter { (1...12).contains($0) }
        if !recent.isEmpty { return Int((Double(recent.reduce(0, +)) / Double(recent.count)).rounded()) }
        if let p = settings?.periodLength, p > 0 { return p }
        return 5
    }

    /// The next predicted starts after the last logged one (a few ahead).
    public func predictedStarts(count: Int = 3) -> [CalDate] {
        guard let last = starts.last else { return [] }
        return (1...max(1, count)).map { last.adding(days: cycleLength * $0) }
    }

    /// What one day is. `today` bounds an open period: it runs at least its
    /// usual length, and on through today (up to 12 days) until it's ended.
    public func info(on day: CalDate, today: CalDate? = nil) -> CalCycleDayInfo {
        let open = periods.last.flatMap { $0.end == nil ? $0 : nil }
        let inOpen: Bool = {
            guard let open, open.start <= day else { return false }
            let usual = open.start.adding(days: periodLength - 1)
            let through = max(usual, min(today ?? usual, open.start.adding(days: 11)))
            return day <= through
        }()
        let ask = inOpen && day > open!.start.adding(days: periodLength - 1)
        let openHere = inOpen ? open : nil
        if let logged = days.last(where: { $0.date == day }), let flow = logged.flow {
            return CalCycleDayInfo(kind: .logged(flow), cycleDay: cycleDay(on: day), askIfEnded: ask, openPeriod: openHere)
        }
        if inOpen || periods.contains(where: { $0.end != nil && $0.covers(day) }) {
            return CalCycleDayInfo(kind: .inPeriod, cycleDay: cycleDay(on: day), askIfEnded: ask, openPeriod: openHere)
        }
        let all = starts + predictedStarts()
        // Predicted period days: from each predicted start, for the period's length.
        for p in predictedStarts() where p <= day && p.days(to: day) < periodLength {
            return CalCycleDayInfo(kind: .predictedPeriod, cycleDay: cycleDay(on: day))
        }
        // The fertile window of the cycle that holds this day.
        if let next = all.first(where: { $0 > day }) {
            let ovulation = next.adding(days: -14)
            let windowStart = ovulation.adding(days: -5)
            if day >= windowStart && day <= ovulation, starts.contains(where: { $0 <= day }) {
                return CalCycleDayInfo(kind: .fertile(ovulation: day == ovulation), cycleDay: cycleDay(on: day))
            }
        }
        return CalCycleDayInfo(kind: nil, cycleDay: cycleDay(on: day))
    }

    /// 1-based day of the cycle (from the latest start on or before it,
    /// logged or predicted).
    public func cycleDay(on day: CalDate) -> Int? {
        let all = (starts + predictedStarts()).filter { $0 <= day }
        guard let s = all.last else { return nil }
        return s.days(to: day) + 1
    }
}

extension CalPeriod {
    /// Whether a day falls inside it (an open one: within 15 days of its start).
    func covers(_ day: CalDate) -> Bool {
        guard start <= day else { return false }
        if let end { return day <= end }
        return start.days(to: day) < 15
    }
}
