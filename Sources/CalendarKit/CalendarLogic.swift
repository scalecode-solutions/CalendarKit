import Foundation

/// The days a month view shows: whole weeks from the locale's first weekday,
/// padded with the neighbouring months' days. Pure, tested.
public struct MonthLayout: Equatable, Sendable {
    public let year: Int
    public let month: Int
    /// 5 or 6 rows of 7 days.
    public let weeks: [[CalDate]]

    /// `firstWeekday`: 1 = Sunday ... 7 = Saturday (Foundation's numbering;
    /// pass `Calendar.current.firstWeekday`).
    public init(year: Int, month: Int, firstWeekday: Int) {
        self.year = year
        self.month = month
        let first = CalDate(year, month, 1)
        // Foundation weekday of the 1st (1 = Sunday).
        let fdWeekday = first.isoWeekday % 7 + 1
        let lead = (fdWeekday - firstWeekday + 7) % 7
        let start = first.adding(days: -lead)
        let days = CalRecurrenceExpander.daysIn(year, month)
        let rows = (lead + days + 6) / 7
        weeks = (0..<rows).map { r in (0..<7).map { start.adding(days: r * 7 + $0) } }
    }

    public func contains(_ d: CalDate) -> Bool { d.year == year && d.month == month }

    public var next: (Int, Int) { CalRecurrenceExpander.addMonths(year, month, 1) }
    public var previous: (Int, Int) { CalRecurrenceExpander.addMonths(year, month, -1) }

    /// Weekday column titles, starting at firstWeekday ("M", "T", …).
    public static func weekdaySymbols(firstWeekday: Int, locale: Locale = .current) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let s = cal.veryShortStandaloneWeekdaySymbols // Sunday first
        return (0..<7).map { s[(firstWeekday - 1 + $0) % 7] }
    }
}

/// Repeat presets the editor offers; anything else is "Custom".
public enum CalRepeatPreset: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekdays, weekly, everyTwoWeeks, monthly, yearly, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .daily: "Every day"
        case .weekdays: "Every weekday"
        case .weekly: "Every week"
        case .everyTwoWeeks: "Every 2 weeks"
        case .monthly: "Every month"
        case .yearly: "Every year"
        case .custom: "Custom"
        }
    }

    /// The rule this preset means (ends are set separately).
    public func rule() -> CalRecurrence? {
        switch self {
        case .never: nil
        case .daily: CalRecurrence(.daily)
        case .weekdays: CalRecurrence(.weekly, weekdays: [1, 2, 3, 4, 5])
        case .weekly: CalRecurrence(.weekly)
        case .everyTwoWeeks: CalRecurrence(.weekly, interval: 2)
        case .monthly: CalRecurrence(.monthly)
        case .yearly: CalRecurrence(.yearly)
        case .custom: CalRecurrence(.weekly)
        }
    }

    /// Which preset a rule is (ignoring how it ends).
    public static func of(_ r: CalRecurrence?, first: CalDate) -> CalRepeatPreset {
        guard let r else { return .never }
        let n = CalRecurrenceExpander.normalized(r, first: first)
        switch (n.frequency, n.interval) {
        case (.daily, 1): return .daily
        case (.weekly, 1) where n.weekdays == [1, 2, 3, 4, 5]: return .weekdays
        case (.weekly, 1) where n.weekdays == [first.isoWeekday]: return .weekly
        case (.weekly, 2) where n.weekdays == [first.isoWeekday]: return .everyTwoWeeks
        case (.monthly, 1) where n.monthly == .dayOfMonth: return .monthly
        case (.yearly, 1): return .yearly
        default: return .custom
        }
    }
}

public enum CalRepeatSummary {
    private static let dayNames = [1: "Monday", 2: "Tuesday", 3: "Wednesday", 4: "Thursday", 5: "Friday", 6: "Saturday", 7: "Sunday"]
    private static let ordinals = [1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth"]

    /// "Every 2 weeks on Monday and Wednesday, 6 times" and the like.
    public static func text(_ r: CalRecurrence, first: CalDate) -> String {
        let n = CalRecurrenceExpander.normalized(r, first: first)
        let unit: String
        switch n.frequency {
        case .daily: unit = n.interval == 1 ? "Every day" : "Every \(n.interval) days"
        case .weekly:
            let base = n.interval == 1 ? "Every week" : "Every \(n.interval) weeks"
            let days = n.weekdays.compactMap { dayNames[$0] }
            // Three or more days read better short: "on Mon, Wed and Fri".
            let shown = days.count > 2 ? days.map { String($0.prefix(3)) } : days
            unit = days == ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"] && n.interval == 1
                ? "Every weekday" : "\(base) on \(list(shown))"
        case .monthly:
            let base = n.interval == 1 ? "Every month" : "Every \(n.interval) months"
            let wd = dayNames[first.isoWeekday]!
            switch n.monthly {
            case .dayOfMonth: unit = "\(base) on the \(ordinalDay(first.day))"
            case .nthWeekday: unit = "\(base) on the \(ordinals[(first.day - 1) / 7 + 1]!) \(wd)"
            case .lastWeekday: unit = "\(base) on the last \(wd)"
            }
        case .yearly: unit = n.interval == 1 ? "Every year" : "Every \(n.interval) years"
        }
        if let c = n.count { return c == 1 ? "\(unit), once" : "\(unit), \(c) times" }
        if let u = n.until {
            return "\(unit), until \(CalFormat.styles(date: .medium, time: .none, zone: CalFormat.utc).string(from: u.utcMidnight))"
        }
        return unit
    }

    static func ordinalDay(_ d: Int) -> String {
        let suffix: String
        switch (d % 10, d % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(d)\(suffix)"
    }

    static func list(_ xs: [String]) -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        default: return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
        }
    }
}

/// What the editor holds while someone types. Converts to `CalEventFields`
/// with the same checks the server makes, so a bad event is caught on the
/// phone instead of bouncing back as a notice.
public struct CalEventDraft: Equatable, Sendable {
    public var title = ""
    public var notes = ""
    public var location = ""
    public var allDay = false
    /// Timed: the instants. All-day: the days these fall on (in `timeZone`).
    public var start: Date
    public var end: Date
    public var timeZone: TimeZone
    public var calendarID: UUID?
    public var labelID: UUID?
    public var color: CalColor = .none
    public var repeatPreset: CalRepeatPreset = .never
    /// For `.custom`.
    public var customRule = CalRecurrence(.weekly)
    public enum Ending: Equatable, Sendable { case never, on(CalDate), after(Int) }
    public var ending: Ending = .never
    /// The person's reminders (nil = their defaults).
    public var alerts: [Int]?

    public init(start: Date, end: Date, timeZone: TimeZone = .current, calendarID: UUID? = nil) {
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.calendarID = calendarID
    }

    /// A new event at the next whole hour of `day`, an hour long.
    public static func new(on day: CalDate, now: Date = Date(), zone: TimeZone = .current, calendarID: UUID?) -> CalEventDraft {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let hour = day == CalDate(now, in: zone) ? min(23, cal.component(.hour, from: now) + 1) : 9
        let s = CalRecurrenceExpander.wallClock(day, hour: hour, minute: 0, second: 0, in: zone)
        return CalEventDraft(start: s, end: s.addingTimeInterval(3600), timeZone: zone, calendarID: calendarID)
    }

    /// Editing an existing event (or one occurrence of a series).
    public init(_ fields: CalEventFields, calendarID: UUID, occurrence when: CalWhen? = nil) {
        let w = when ?? fields.when
        switch w {
        case .allDay(let s, let e):
            let zone = TimeZone.current
            self.init(start: CalRecurrenceExpander.wallClock(s, hour: 0, minute: 0, second: 0, in: zone),
                      end: CalRecurrenceExpander.wallClock(e.adding(days: -1), hour: 0, minute: 0, second: 0, in: zone),
                      timeZone: zone, calendarID: calendarID)
            allDay = true
        case .timed(let s, let e, let tz):
            self.init(start: s, end: e, timeZone: TimeZone(identifier: tz) ?? .current, calendarID: calendarID)
        }
        title = fields.title
        notes = fields.notes
        location = fields.location
        labelID = fields.labelID
        color = fields.color
        let first = w.firstDay
        repeatPreset = CalRepeatPreset.of(fields.recurrence, first: first)
        if let r = fields.recurrence {
            customRule = r
            ending = r.count.map { .after($0) } ?? r.until.map { .on($0) } ?? .never
        }
    }

    /// The repeat as the editor shows it (a segmented control): nil = it
    /// doesn't repeat. Setting a frequency edits the rule in place: the
    /// interval, weekdays and month mode stay while the frequency does, and
    /// reset when it changes (they mean something else per frequency). A
    /// preset becomes its rule, so the controls below can edit it.
    public var frequency: CalFrequency? {
        get {
            switch repeatPreset {
            case .never: nil
            case .custom: customRule.frequency
            default: repeatPreset.rule()?.frequency
            }
        }
        set {
            guard let f = newValue else { repeatPreset = .never; return }
            if repeatPreset != .custom, let r = repeatPreset.rule() { customRule = r }
            if customRule.frequency != f { customRule = CalRecurrence(f) }
            repeatPreset = .custom
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        case noTitle, titleTooLong, notesTooLong, locationTooLong, endBeforeStart, tooLong, endsBeforeItStarts, badCount
    }

    public var firstDay: CalDate { CalDate(start, in: timeZone) }

    /// Move the start, keeping the length (the Starts picker).
    public mutating func moveStart(to new: Date) {
        let delta = new.timeIntervalSince(start)
        start = new
        end = max(new, end.addingTimeInterval(delta))
    }

    /// Switch between all-day and timed, keeping the days shown (R63, R64).
    /// To timed: the next hour today, else 9:00, an hour long on a one-day
    /// event, or to the same time on the last day. To all-day: the days the
    /// times fall on (an end at midnight doesn't add a day). Reminders chosen
    /// for the other kind would mean something else (minutes before a time vs
    /// before the day), so they go back to the person's defaults.
    public mutating func setAllDay(_ on: Bool, now: Date = Date()) {
        guard on != allDay else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let first = CalDate(start, in: timeZone)
        var last = CalDate(end, in: timeZone)
        if on {
            if end > start && OccurrenceBuilder.start(of: last, in: timeZone) == end { last = last.adding(days: -1) }
            if last < first { last = first }
            start = CalRecurrenceExpander.wallClock(first, hour: 0, minute: 0, second: 0, in: timeZone)
            end = CalRecurrenceExpander.wallClock(last, hour: 0, minute: 0, second: 0, in: timeZone)
        } else {
            let hour = first == CalDate(now, in: timeZone) ? min(23, cal.component(.hour, from: now) + 1) : 9
            start = CalRecurrenceExpander.wallClock(first, hour: hour, minute: 0, second: 0, in: timeZone)
            end = CalRecurrenceExpander.wallClock(max(first, last), hour: hour, minute: 0, second: 0, in: timeZone)
                .addingTimeInterval(3600)
        }
        allDay = on
        alerts = nil
    }

    /// The fields to save, or what's wrong (the server's own limits).
    public func fields() -> Result<CalEventFields, Problem> {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.noTitle) }
        if t.count > 200 { return .failure(.titleTooLong) }
        if notes.count > 4000 { return .failure(.notesTooLong) }
        if location.count > 300 { return .failure(.locationTooLong) }
        let when: CalWhen
        if allDay {
            let s = CalDate(start, in: timeZone), e = CalDate(end, in: timeZone)
            if e < s { return .failure(.endBeforeStart) }
            if s.days(to: e) + 1 > 366 { return .failure(.tooLong) }
            when = .allDay(start: s, end: e.adding(days: 1))
        } else {
            if end < start { return .failure(.endBeforeStart) }
            if end.timeIntervalSince(start) > 366 * 86_400 { return .failure(.tooLong) }
            when = .timed(start: start, end: end, timeZone: timeZone.identifier)
        }
        var rule = repeatPreset == .custom ? customRule : repeatPreset.rule()
        if rule != nil {
            switch ending {
            case .never: rule!.until = nil; rule!.count = nil
            case .on(let d):
                if d < when.firstDay { return .failure(.endsBeforeItStarts) }
                rule!.until = d; rule!.count = nil
            case .after(let n):
                if !(1...1000).contains(n) { return .failure(.badCount) }
                rule!.count = n; rule!.until = nil
            }
            rule = CalRecurrenceExpander.normalized(rule!, first: when.firstDay)
            if rule!.frequency == .weekly && !rule!.weekdays.contains(when.firstDay.isoWeekday) {
                rule!.weekdays = (rule!.weekdays + [when.firstDay.isoWeekday]).sorted()
            }
            if rule!.frequency == .monthly && rule!.monthly == .lastWeekday
                && when.firstDay.adding(days: 7).month == when.firstDay.month {
                rule!.monthly = .nthWeekday
            }
        }
        return .success(CalEventFields(title: t, notes: notes, location: location, when: when,
                                       labelID: labelID, color: color, recurrence: rule))
    }

    public static func describe(_ p: Problem) -> String {
        switch p {
        case .noTitle: "Add a title"
        case .titleTooLong: "The title is too long"
        case .notesTooLong: "The notes are too long"
        case .locationTooLong: "The location is too long"
        case .endBeforeStart: "It ends before it starts"
        case .tooLong: "An event can't be longer than a year"
        case .endsBeforeItStarts: "The repeat ends before the first one"
        case .badCount: "Repeat between 1 and 1000 times"
        }
    }
}
