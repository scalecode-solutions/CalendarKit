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
        /// Fertility possible (MVCALE-127 step 5): the calendar method's
        /// wider range around the window, from the person's own shortest and
        /// longest cycles. Not "safe" outside it: lower chance, not zero.
        case fertilePossible
    }
    public var kind: Kind?
    /// 1-based day of the cycle, when there's a cycle start before it.
    public let cycleDay: Int?
    /// A period day that also falls in the fertile window (short cycles:
    /// the period's mark wins the grid, the day detail says both).
    public var fertileToo = false
    /// Today, when the period is past its estimate by more than the grace
    /// period with none logged: by how many days (MVCALE-127 step 4). Shown
    /// in the day detail only, never on the grid.
    public var daysPastEstimate: Int?
    /// The day is past an open period's usual length: ask whether it ended.
    public var askIfEnded = false
    /// The open period this day belongs to, if any (offers "Ended today").
    public var openPeriod: CalPeriod?

    /// Something for the day detail to show: a mark, or a late line.
    public var hasSomething: Bool { kind != nil || daysPastEstimate != nil }

    public init(kind: Kind?, cycleDay: Int?, askIfEnded: Bool = false, openPeriod: CalPeriod? = nil,
                daysPastEstimate: Int? = nil) {
        self.kind = kind
        self.cycleDay = cycleDay
        self.askIfEnded = askIfEnded
        self.openPeriod = openPeriod
        self.daysPastEstimate = daysPastEstimate
    }
}

/// Estimates from logged days, a calendar estimate (cycle-length based, not
/// ACOG's: MVCALE-127 finding 7): a period starts on a logged non-spotting
/// day after a gap; the cycle length is the median of the recent cycles, else
/// the person's setting, else 28; the period length the average, else 5.
/// Ovulation is 13 days before the next start (Bull 2019; Apple), and the
/// fertile window is the 5 days before it plus that day. Around it, a wider
/// "fertility possible" band from the calendar method; while cycles are
/// unsettled, only that band.
public struct CalCycleEstimator: Sendable {
    public let days: [CalCycleDay]
    public let settings: CalCycleSettings?
    /// Each period, oldest first (see `findPeriods`).
    public let periods: [CalPeriod]
    /// The first day of each period.
    public let starts: [CalDate]
    /// The median of the last up to six cycles since the latest reset, a
    /// month left unlogged left out (the mean with fewer than three), else
    /// the setting, else the cycles before the reset, else 28.
    public let cycleLength: Int
    /// The average length of the last up to six finished periods (a marked
    /// start to its marked end, or a run's first to last bleeding day), else
    /// the setting, else 5. An open period doesn't count until it ends.
    public let periodLength: Int
    /// Cycles aren't settled enough for a confident window (MVCALE-127 step
    /// 5, open question 5): only the "fertility possible" band shows, and the
    /// next period is a range. See `isUnsettled`.
    public let unsettled: Bool

    /// Works the periods and both lengths out once: a month on screen asks
    /// about every day, and each answer needs them (MVCALE-127 step 1).
    public init(days: [CalCycleDay], settings: CalCycleSettings?) {
        let days = days.filter { !$0.deleted }.sorted { $0.date < $1.date }
        self.days = days
        self.settings = settings
        let periods = Self.findPeriods(days, settings: settings)
        self.periods = periods
        let starts = periods.map(\.start)
        self.starts = starts
        self.cycleLength = Self.cycleLength(starts: starts, settings: settings)
        self.periodLength = Self.periodLength(periods: periods, settings: settings)
        self.unsettled = Self.isUnsettled(starts: starts)
    }

    /// Each period, oldest first (MVCALE-52, MVCALE-127 step 2):
    /// - A period begins at a "Period started" mark or at a bleeding day
    ///   (spotting never begins one), unless it's less than 15 days after the
    ///   last period began. Then it's mid-cycle bleeding, and so is the whole
    ///   bleed it's part of (bleeding days at most 3 days apart): no day of
    ///   it begins a period, even one past day 15. Only a "Period started"
    ///   mark at least 15 days after the last start still begins one there.
    /// - It goes on through bleeding days at most 3 days apart; a "Period
    ///   started" mark inside it marks it rather than beginning another.
    /// - A "Period ended" mark within 15 days of its start ends it, whether it
    ///   began with a mark or with a flow (Leaf's review); an end with no
    ///   period before it is ignored.
    /// - Otherwise a marked period stays open until ended, and an unmarked
    ///   one (flows alone, or days logged before marks existed) ends at its
    ///   last bleeding day.
    /// - The tie-break: when a bleed that began a period has a rival, a later
    ///   bleed less than 15 days after it that could have begun one too, the
    ///   period is the bleed marked "Period started"; else the one with more
    ///   bleeding days (a 1-day spot never takes a real period's place on
    ///   nearness alone: Stipe's review); else the one nearer when the period
    ///   was due (the last start plus the usual cycle length). A bleed on day
    ///   17 with the real period 12 days later is mid-cycle. Someone who logs
    ///   only each period's first day has equal 1-day bleeds, so for her it
    ///   comes down to nearness; a "Period started" mark settles it.
    static func findPeriods(_ days: [CalCycleDay], settings: CalCycleSettings?) -> [CalPeriod] {
        // A losing bleed's first day is vetoed and the pass runs again; each
        // run vetoes one more day, so it ends.
        var vetoed: Set<CalDate> = []
        while true {
            let pass = periodPass(days, vetoed: vetoed)
            guard let loser = tieBreakLoser(pass, settings: settings) else { return pass.periods }
            vetoed.insert(loser)
        }
    }

    /// A bleed that could begin a period, but came less than 15 days after
    /// the start of `period` (an index into the periods found).
    private struct Rival {
        let period: Int
        let start: CalDate
        var marked: Bool
        /// Its bleeding days.
        var length: Int
    }

    private static func periodPass(_ days: [CalCycleDay], vetoed: Set<CalDate>) -> (periods: [CalPeriod], rivals: [Rival], lengths: [Int]) {
        var out: [CalPeriod] = []
        // Each period's bleeding days, beside `out`.
        var lengths: [Int] = []
        var rivals: [Rival] = []
        var cur: (start: CalDate, last: CalDate, marked: Bool, bled: Int)?
        // The mid-cycle bleed being skipped: its last day, and the rival it
        // is, if any.
        var block: (last: CalDate, rival: Int?)?
        func close(end: CalDate?) {
            guard let c = cur else { return }
            out.append(CalPeriod(start: c.start, end: end ?? (c.marked ? nil : c.last), marked: c.marked))
            lengths.append(c.bled)
            cur = nil
        }
        for d in days {
            let bleeding = d.flow?.startsAPeriod ?? false
            if let c = cur {
                let inRun = c.marked ? c.start.days(to: d.date) < 15 : c.last.days(to: d.date) <= 3
                if d.ends && c.start.days(to: d.date) < 15 && (inRun || !bleeding) {
                    if bleeding || d.starts { cur?.last = d.date }
                    if bleeding { cur?.bled += 1 }
                    close(end: d.date)
                    continue
                }
                if inRun {
                    if bleeding { cur?.last = d.date; cur?.bled += 1 }
                    if d.starts { cur?.marked = true }
                    continue
                }
                if bleeding || d.starts { close(end: nil) } else { continue }
            }
            guard bleeding || d.starts else { continue } // an end, or spotting, on its own
            let sinceLast = out.last.map { $0.start.days(to: d.date) }
            if let b = block, b.last.days(to: d.date) <= 3 {
                // Still the mid-cycle bleed, unless a start mark 15+ days on.
                if !(d.starts && (sinceLast ?? 15) >= 15) {
                    if bleeding { block?.last = d.date }
                    if bleeding, let r = b.rival { rivals[r].length += 1 }
                    if d.starts, let r = b.rival { rivals[r].marked = true }
                    continue
                }
            }
            if let since = sinceLast, since < 15 || vetoed.contains(d.date) {
                var rival: Int?
                if since < 15, out.count >= 2 {
                    rivals.append(Rival(period: out.count - 1, start: d.date, marked: d.starts, length: bleeding ? 1 : 0))
                    rival = rivals.count - 1
                }
                block = (d.date, rival)
                continue
            }
            block = nil
            cur = (d.date, d.date, d.starts, bleeding ? 1 : 0)
            if d.ends { close(end: d.date) }
        }
        close(end: nil)
        return (out, rivals, lengths)
    }

    /// The first day of the earliest period that loses its tie-break, if any.
    private static func tieBreakLoser(_ pass: (periods: [CalPeriod], rivals: [Rival], lengths: [Int]), settings: CalCycleSettings?) -> CalDate? {
        let periods = pass.periods
        for i in periods.indices.dropFirst() {
            let rivals = pass.rivals.filter { $0.period == i }
            guard !rivals.isEmpty else { continue }
            let starts = periods[..<i].map(\.start)
            let due = starts.last!.adding(days: cycleLength(starts: Array(starts), settings: settings))
            typealias Bleed = (start: CalDate, marked: Bool, length: Int)
            func better(_ a: Bleed, than b: Bleed) -> Bool {
                if a.marked != b.marked { return a.marked }
                if a.length != b.length { return a.length > b.length }
                return abs(a.start.days(to: due)) < abs(b.start.days(to: due))
            }
            let own: Bleed = (periods[i].start, periods[i].marked, pass.lengths[i])
            if rivals.contains(where: { better(($0.start, $0.marked, $0.length), than: own) }) {
                return periods[i].start
            }
        }
        return nil
    }

    /// The gaps between starts that can be cycles, since the latest reset
    /// (MVCALE-127 step 3):
    /// - a gap over 60 days (a pregnancy, months on the pill, months not
    ///   logged) ends the old history: only the gaps after it count, and
    ///   `before` keeps the older ones (Stipe's research);
    /// - a gap under 15 days isn't a cycle.
    static func history(_ s: [CalDate]) -> (gaps: [Int], reset: Bool, before: [Int]) {
        var gaps: [Int] = [], before: [Int] = [], reset = false
        for g in zip(s, s.dropFirst()).map({ $0.days(to: $1) }) {
            if g > 60 {
                before += gaps
                gaps = []
                reset = true
            } else if g >= 15 {
                gaps.append(g)
            }
        }
        return (gaps, reset, before)
    }

    /// The recent gaps the cycle length is taken from: with 3 or more, a gap
    /// longer than the median gap + the median change between consecutive
    /// gaps + 15 days is a month left unlogged and is dropped (the Apple
    /// Women's Health Study's artifact rule, Frond's research; the change is
    /// measured with the longest gap left out, or that gap would hide itself
    /// among few). Then the last 6. With fewer than 3 there's nothing to
    /// judge by.
    static func recentGaps(_ gaps: [Int]) -> [Int] {
        Array(keptGaps(gaps).suffix(6))
    }

    /// The gaps since the reset with any month left unlogged dropped.
    static func keptGaps(_ gaps: [Int]) -> [Int] { keptIndices(gaps).map { gaps[$0] } }

    /// The positions of the gaps kept (see `recentGaps`).
    static func keptIndices(_ gaps: [Int]) -> [Int] {
        guard gaps.count >= 3 else { return Array(gaps.indices) }
        let window = Array(gaps.suffix(12))
        var rest = window
        rest.remove(at: rest.firstIndex(of: rest.max()!)!)
        let limit = median(window) + median(changes(rest)) + 15
        return gaps.indices.filter { Double(gaps[$0]) <= limit }
    }

    /// The absolute change from each gap to the next.
    static func changes(_ gaps: [Int]) -> [Int] {
        zip(gaps, gaps.dropFirst()).map { abs($1 - $0) }
    }

    static func recentGaps(starts: [CalDate]) -> [Int] { recentGaps(history(starts).gaps) }

    /// The median of the recent gaps (the mean with fewer than 3), else the
    /// setting, else the gaps from before the latest reset, else 28.
    static func cycleLength(starts s: [CalDate], settings: CalCycleSettings?) -> Int {
        func length(_ all: [Int]) -> Int? {
            let gaps = recentGaps(all)
            guard !gaps.isEmpty else { return nil }
            let avg = all.count >= 3 ? median(gaps) : Double(gaps.reduce(0, +)) / Double(gaps.count)
            return Int(avg.rounded())
        }
        let h = history(s)
        if let n = length(h.gaps) { return n }
        if let c = settings?.cycleLength, c > 0 { return c }
        return length(h.before) ?? 28
    }

    /// Whether cycles are unsettled (Stipe's research, MVCALE-127 Q5):
    /// - a reset (a gap over 60 days: a birth, the pill, perimenopause) with
    ///   fewer than 3 cycles since. The first cycles after a birth are often
    ///   off, and ovulation can come before the first period; or
    /// - the median change between consecutive cycles, over the last 6 kept,
    ///   is 9 days or more (the Apple Women's Health Study's alternative
    ///   rule, 2023; Li 2020, Clue, uses more than 9). Only cycles that were
    ///   next to each other count as a change: a month left unlogged is
    ///   dropped first, so it neither makes nor hides a change.
    static func isUnsettled(starts: [CalDate]) -> Bool {
        let h = history(starts)
        if h.reset && h.gaps.count < 3 { return true }
        guard h.gaps.count >= 3 else { return false }
        let kept = Set(keptIndices(h.gaps).suffix(6))
        let pairs = h.gaps.indices.dropLast().filter { kept.contains($0) && kept.contains($0 + 1) }
        guard !pairs.isEmpty else { return false }
        return median(pairs.map { abs(h.gaps[$0 + 1] - h.gaps[$0]) }) >= 9
    }

    /// The cycle days of the "fertility possible" band (MVCALE-127 step 5),
    /// the calendar method: the shortest recent cycle − 18 through the longest
    /// − 11, from 3 cycles since the reset; before that, days 8–19 (the
    /// Standard Days Method), widened to the cycle length − 18 / − 11.
    public var possibleDays: ClosedRange<Int> {
        let gaps = Self.recentGaps(starts: starts)
        if gaps.count >= 3, let lo = gaps.min(), let hi = gaps.max() { return (lo - 18)...(hi - 11) }
        return min(8, cycleLength - 18)...max(19, cycleLength - 11)
    }

    /// While unsettled, when the next period may come: the last start plus
    /// the shortest through the longest recent cycle (from 2 since the
    /// reset); before that, the setting ± the grace period, else days 21–35.
    /// Always holding the estimate itself.
    public var nextRange: ClosedRange<CalDate>? {
        guard unsettled, let last = starts.last else { return nil }
        let gaps = Self.recentGaps(starts: starts)
        var lo: Int, hi: Int
        if gaps.count >= 2 { (lo, hi) = (gaps.min()!, gaps.max()!) }
        else if let c = settings?.cycleLength, c > 0 { (lo, hi) = (c - grace, c + grace) }
        else { (lo, hi) = (21, 35) }
        return last.adding(days: min(lo, cycleLength))...last.adding(days: max(hi, cycleLength))
    }

    static func median(_ xs: [Int]) -> Double {
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? Double(s[m]) : Double(s[m - 1] + s[m]) / 2
    }

    static func periodLength(periods: [CalPeriod], settings: CalCycleSettings?) -> Int {
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

    /// How many days a period may be past its estimate before the day
    /// detail says so (MVCALE-127 step 4): half the recent shortest-to-longest
    /// spread, kept between 3 and 5 days (Apple's predictions count as on
    /// time within ±3: Frond's research), or 3 with fewer than 2 recent gaps.
    public var grace: Int {
        let gaps = Self.recentGaps(starts: starts)
        guard gaps.count >= 2, let lo = gaps.min(), let hi = gaps.max() else { return 3 }
        return min(5, max(3, Int((Double(hi - lo) / 2).rounded())))
    }

    /// The estimate a period is past, and by how many days, when today is
    /// past it with no period logged since (MVCALE-127 step 4). While
    /// unsettled the estimate is the end of the range shown, not its middle
    /// (Leaf's and Stipe's review: never past an estimate the card still
    /// shows as possible). nil when it isn't, or with nothing logged.
    public func overdue(today: CalDate?) -> (due: CalDate, days: Int)? {
        guard let today, let estimate = predictedStarts(count: 1).first else { return nil }
        let due = nextRange?.upperBound ?? estimate
        guard today > due else { return nil }
        return (due, due.days(to: today))
    }

    /// What one day is. `today` bounds an open period: it runs at least its
    /// usual length, and on through today (up to 12 days) until it's ended.
    ///
    /// Late (MVCALE-127 step 4): once today is past the next estimate with
    /// no period logged, the cycle day counts on from the last logged start,
    /// the missed expected period stays whole (open question 3), and nothing
    /// is predicted after it: no later periods, no fertile window. After the
    /// grace period, today's day says by how much (`daysPastEstimate`).
    public func info(on day: CalDate, today: CalDate? = nil) -> CalCycleDayInfo {
        let late = overdue(today: today)
        let predicted = late == nil ? predictedStarts() : predictedStarts(count: 1)
        let open = periods.last.flatMap { $0.end == nil ? $0 : nil }
        let inOpen: Bool = {
            guard let open, open.start <= day else { return false }
            let usual = open.start.adding(days: periodLength - 1)
            let through = max(usual, min(today ?? usual, open.start.adding(days: 11)))
            return day <= through
        }()
        let ask = inOpen && day > open!.start.adding(days: periodLength - 1)
        let openHere = inOpen ? open : nil
        let cd = cycleDay(on: day, today: today)
        var info = CalCycleDayInfo(kind: nil, cycleDay: cd)
        if let late, day == today, late.days > grace { info.daysPastEstimate = late.days }
        // The fertile window of the cycle that holds this day. While late,
        // only the cycles up to the missed estimate have one (nothing is
        // predicted after it); while unsettled, none.
        let all = starts + predicted
        let window: (day: CalDate, ovulation: CalDate)? = {
            guard !unsettled, let next = all.first(where: { $0 > day }), starts.contains(where: { $0 <= day }) else { return nil }
            let ovulation = next.adding(days: -13)
            guard day >= ovulation.adding(days: -5) && day <= ovulation else { return nil }
            return (day, ovulation)
        }()
        if let logged = days.last(where: { $0.date == day }), let flow = logged.flow {
            info.kind = .logged(flow)
            info.askIfEnded = ask
            info.openPeriod = openHere
            info.fertileToo = window != nil && flow.startsAPeriod
            return info
        }
        if inOpen || periods.contains(where: { $0.end != nil && $0.covers(day) }) {
            info.kind = .inPeriod
            info.askIfEnded = ask
            info.openPeriod = openHere
            info.fertileToo = window != nil
            return info
        }
        // Predicted period days: from each predicted start, for the period's length.
        if predicted.contains(where: { $0 <= day && $0.days(to: day) < periodLength }) {
            info.kind = .predictedPeriod
            return info
        }
        if let window {
            info.kind = .fertile(ovulation: window.day == window.ovulation)
            return info
        }
        // The faint band, by cycle day, in every cycle with a start and a
        // next one (logged or predicted), the window's own horizon: so not
        // past a missed estimate, nor past the last prediction (Frond's
        // review: a lone band there read like the unsettled look).
        if let cd, possibleDays.contains(cd), all.contains(where: { $0 > day }) {
            info.kind = .fertilePossible
        }
        return info
    }

    /// 1-based day of the cycle (from the latest start on or before it,
    /// logged or predicted; while late, `today` past the estimate, logged
    /// only).
    public func cycleDay(on day: CalDate, today: CalDate? = nil) -> Int? {
        let predicted = overdue(today: today) == nil ? predictedStarts() : []
        let all = (starts + predicted).filter { $0 <= day }
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
