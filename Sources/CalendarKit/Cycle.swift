import Foundation

// Cycle tracking (0.8.0 design sprint, MVCALE-28; PROVISIONAL). Days the
// person logs, and estimates made on the phone from them. Estimates, not
// advice: "Estimates from your entries. Not a medical device and not a
// contraceptive method." (plan decision 12).

/// How a logged day flows. Spotting is its own mark and never starts a cycle
/// (plan decision 13).
public enum CalFlow: String, CaseIterable, Sendable, Codable {
    case spotting, light, medium, heavy
    public var startsAPeriod: Bool { self != .spotting }
}

/// One logged day of one person's cycle, on a pair calendar.
public struct CalCycleDay: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    /// Whose cycle: one of the pair's two members.
    public let personID: UUID
    public var date: CalDate
    public var flow: CalFlow
    public var rev: Int64
    public var deleted: Bool

    public init(id: UUID = UUID(), calendarID: UUID, personID: UUID, date: CalDate, flow: CalFlow,
                rev: Int64 = 0, deleted: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.personID = personID
        self.date = date
        self.flow = flow
        self.rev = rev
        self.deleted = deleted
    }
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
        /// An estimated period day (not logged).
        case predictedPeriod
        /// The estimated fertile window (ovulation's day included).
        case fertile(ovulation: Bool)
    }
    public let kind: Kind?
    /// 1-based day of the cycle, when there's a cycle start before it.
    public let cycleDay: Int?
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

    /// The first day of each logged period. Spotting never starts one; a
    /// bleeding day within 3 days of the last bleeding day continues it; and
    /// bleeding less than 15 days after a start is mid-cycle, not a new
    /// period (it would drag the average cycle down; Leaf's question).
    public var starts: [CalDate] {
        var out: [CalDate] = []
        var last: CalDate?
        for d in days where d.flow.startsAPeriod {
            defer { last = d.date }
            if let l = last, l.days(to: d.date) <= 3 { continue }
            if let s = out.last, s.days(to: d.date) < 15 { continue }
            out.append(d.date)
        }
        return out
    }

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

    /// The average logged period length (last up to six), else the setting, else 5.
    public var periodLength: Int {
        let s = starts
        var lengths: [Int] = []
        for (i, start) in s.enumerated() {
            let end = i + 1 < s.count ? s[i + 1] : nil
            let run = days.filter { d in d.flow.startsAPeriod && d.date >= start && (end.map { d.date < $0 } ?? true) }
            if let last = run.last { lengths.append(start.days(to: last.date) + 1) }
        }
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

    /// What one day is.
    public func info(on day: CalDate) -> CalCycleDayInfo {
        if let logged = days.last(where: { $0.date == day }) {
            return CalCycleDayInfo(kind: .logged(logged.flow), cycleDay: cycleDay(on: day))
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
