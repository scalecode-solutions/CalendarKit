import Foundation

/// Expands a series into occurrences. The rules are a contract shared with
/// mvCalendar (`internal/recur/expand.go`) and pinned by its golden cases
/// (`testdata/recurrence/cases.json`, answered by python-dateutil):
///
/// - Occurrences are generated on calendar dates in the event's zone; the
///   start's wall-clock time is then attached.
/// - Weekly: weeks start on Monday; every `interval` weeks counted from the
///   start's week, on each listed weekday, Monday first.
/// - Monthly: the start's day of the month (months without it are skipped),
///   its n-th weekday (no n-th → skipped), or the last such weekday.
///   Yearly: the start's month and day (Feb 29 only in leap years).
/// - `count` counts generated occurrences (cancelled ones included); `until`
///   is an inclusive date.
/// - A wall-clock time that doesn't exist (spring forward) uses the offset in
///   force before the gap; a time that happens twice (fall back) is the first.
public enum CalRecurrenceExpander {
    /// Guards against a rule that keeps producing nothing.
    static let maxSteps = 200_000

    /// The one canonical form of a rule, the server's: interval ≥ 1; weekly
    /// days sorted, unique, defaulting to the start's; no weekdays unless weekly
    /// (the server refuses them); the monthly mode only on a monthly rule. Every
    /// rule is compared, built and decoded through this (review R2, R6, R53).
    public static func normalized(_ r: CalRecurrence, first: CalDate) -> CalRecurrence {
        var r = canonical(r)
        if r.frequency == .weekly && r.weekdays.isEmpty { r.weekdays = [first.isoWeekday] }
        return r
    }

    /// `normalized` without a start date to default from (decoding, comparing).
    public static func canonical(_ r: CalRecurrence) -> CalRecurrence {
        var r = r
        r.interval = max(1, r.interval)
        r.weekdays = r.frequency == .weekly ? Set(r.weekdays.filter { (1...7).contains($0) }).sorted() : []
        if r.frequency != .monthly { r.monthly = .dayOfMonth }
        return r
    }

    /// The series' occurrence days, in order, starting at `first`. Stops at the
    /// rule's end, after `limit` occurrences, or past `through` (whichever is
    /// first). With `from`, only days on or after it are returned; without a
    /// count, the periods before it are skipped outright instead of generated
    /// (a daily series three years old: R23). A count still counts from the
    /// start, so then the early days are generated but not returned.
    public static func dates(_ rule: CalRecurrence, first: CalDate, from: CalDate? = nil, through: CalDate? = nil,
                             limit: Int = .max) -> [CalDate] {
        let r = normalized(rule, first: first)
        var out: [CalDate] = []
        var produced = 0
        // false = stop
        func emit(_ d: CalDate) -> Bool {
            if let u = r.until, d > u { return false }
            if let t = through, d > t { return false }
            produced += 1
            if from.map({ d >= $0 }) ?? true { out.append(d) }
            if let c = r.count, produced >= c { return false }
            return out.count < limit
        }
        // Whether a skipped period is already past every end (so we can stop).
        func pastEnd(_ d: CalDate) -> Bool {
            if let u = r.until, d > u { return true }
            if let t = through, d > t { return true }
            return false
        }
        let monday = first.adding(days: -(first.isoWeekday - 1))
        // Whole periods that end before `from` (only without a count).
        var skip = 0
        if let from, from > first, r.count == nil {
            switch r.frequency {
            case .daily: skip = first.days(to: from) / r.interval
            case .weekly: skip = monday.days(to: from) / (7 * r.interval)
            case .monthly: skip = max(0, ((from.year - first.year) * 12 + from.month - first.month - 1) / r.interval)
            case .yearly: skip = max(0, (from.year - first.year - 1) / r.interval)
            }
        }
        for step in skip..<(skip + maxSteps) {
            switch r.frequency {
            case .daily:
                if !emit(first.adding(days: step * r.interval)) { return out }
            case .weekly:
                let week = monday.adding(days: 7 * r.interval * step)
                for wd in r.weekdays {
                    let d = week.adding(days: wd - 1)
                    if d < first { continue }
                    if !emit(d) { return out }
                }
            case .monthly:
                let (y, m) = addMonths(first.year, first.month, step * r.interval)
                if let d = monthlyDay(r.monthly, first: first, year: y, month: m) {
                    if !emit(d) { return out }
                } else if pastEnd(CalDate(y, m, 1)) {
                    return out
                }
            case .yearly:
                let d = CalDate(first.year + step * r.interval, first.month, first.day)
                if d.isValid {
                    if !emit(d) { return out }
                } else if pastEnd(CalDate(d.year, 1, 1)) {
                    return out
                }
            }
        }
        return out
    }

    /// Timed series: occurrence start instants.
    public static func instants(_ rule: CalRecurrence, start: Date, timeZone: TimeZone,
                                from: CalDate? = nil, through: CalDate? = nil, limit: Int = .max) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let first = CalDate(c.year!, c.month!, c.day!)
        // Only the days asked for get a wall clock (the costly part).
        return dates(rule, first: first, from: from, through: through, limit: limit).map {
            wallClock($0, hour: c.hour!, minute: c.minute!, second: c.second!, in: timeZone)
        }
    }

    static func addMonths(_ y: Int, _ m: Int, _ n: Int) -> (Int, Int) {
        let t = m - 1 + n
        return (y + t / 12, t % 12 + 1)
    }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        var d = 31
        while !CalDate(y, m, d).isValid { d -= 1 }
        return d
    }

    static func monthlyDay(_ mode: CalMonthlyMode, first: CalDate, year y: Int, month m: Int) -> CalDate? {
        switch mode {
        case .dayOfMonth:
            let d = CalDate(y, m, first.day)
            return d.isValid ? d : nil
        case .nthWeekday, .lastWeekday:
            let firstOfMonth = CalDate(y, m, 1)
            let day1 = 1 + (first.isoWeekday - firstOfMonth.isoWeekday + 7) % 7 // first such weekday
            let last = daysIn(y, m)
            if mode == .lastWeekday {
                var d = day1
                while d + 7 <= last { d += 7 }
                return CalDate(y, m, d)
            }
            let n = (first.day - 1) / 7 + 1
            let d = day1 + 7 * (n - 1)
            return d <= last ? CalDate(y, m, d) : nil
        }
    }

    /// Day d at h:m:s in zone: the first instant showing that wall clock; a time
    /// that doesn't exist is read with the offset in force before the gap.
    static func wallClock(_ d: CalDate, hour: Int, minute: Int, second: Int, in zone: TimeZone) -> Date {
        // The wall clock read as if it were UTC.
        let naive = CalDate.utc.date(from: DateComponents(year: d.year, month: d.month, day: d.day,
                                                          hour: hour, minute: minute, second: second))!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        // The offsets in force around that day (transitions are months apart).
        let offsets = Set([-86_400.0, 0, 86_400].map { zone.secondsFromGMT(for: naive.addingTimeInterval($0)) })
        let matches = offsets.map { naive.addingTimeInterval(-Double($0)) }.filter { t in
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
            return c.year == d.year && c.month == d.month && c.day == d.day
                && c.hour == hour && c.minute == minute && c.second == second
        }
        if let earliest = matches.min() { return earliest }
        let before = zone.secondsFromGMT(for: naive.addingTimeInterval(-86_400))
        return naive.addingTimeInterval(-Double(before))
    }
}
