import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-7: the repeat picker's model, the detail hero, and the reminders row.
@Suite("Editor and detail")
struct EditorDetailTests {
    let tz = TimeZone(identifier: "America/Chicago")!

    func draft(on day: CalDate) -> CalEventDraft {
        let s = CalRecurrenceExpander.wallClock(day, hour: 9, minute: 0, second: 0, in: tz)
        var d = CalEventDraft(start: s, end: s.addingTimeInterval(3600), timeZone: tz)
        d.title = "x"
        return d
    }

    func rule(_ d: CalEventDraft) -> CalRecurrence? {
        if case .success(let f) = d.fields() { return f.recurrence }
        Issue.record("should save"); return nil
    }

    @Test func frequencyControlEditsTheRule() {
        var d = draft(on: CalDate(2026, 11, 16)) // a Monday
        #expect(d.frequency == nil && rule(d) == nil)
        d.frequency = .weekly
        #expect(rule(d) == CalRecurrence(.weekly, weekdays: [1]))
        // The controls under it edit the same rule.
        d.customRule.interval = 2
        d.customRule.weekdays = [1, 3]
        #expect(rule(d) == CalRecurrence(.weekly, interval: 2, weekdays: [1, 3]))
        // Choosing the same frequency again keeps them.
        d.frequency = .weekly
        #expect(rule(d)?.interval == 2 && rule(d)?.weekdays == [1, 3])
        // Another frequency starts fresh: weekdays mean nothing monthly.
        d.frequency = .monthly
        #expect(rule(d) == CalRecurrence(.monthly, monthly: .dayOfMonth))
        d.frequency = nil
        #expect(rule(d) == nil && d.repeatPreset == .never)
    }

    /// An event saved as a preset opens with the controls on its real rule.
    @Test func aPresetOpensAsItsRule() {
        let mon = CalDate(2026, 11, 16)
        let s = CalRecurrenceExpander.wallClock(mon, hour: 9, minute: 0, second: 0, in: tz)
        let saved = CalEventFields(title: "Work", when: .timed(start: s, end: s.addingTimeInterval(3600), timeZone: tz.identifier),
                                   recurrence: CalRecurrence(.weekly, weekdays: [1, 2, 3, 4, 5], count: 10))
        var d = CalEventDraft(saved, calendarID: UUID())
        #expect(d.repeatPreset == .weekdays && d.frequency == .weekly)
        d.frequency = .weekly // what touching the control does
        #expect(d.repeatPreset == .custom && d.customRule.weekdays == [1, 2, 3, 4, 5])
        #expect(rule(d) == CalRecurrence(.weekly, weekdays: [1, 2, 3, 4, 5], count: 10))
    }

    @Test func summariesShortenLongDayLists() {
        let mon = CalDate(2026, 11, 16)
        #expect(CalRepeatSummary.text(CalRecurrence(.weekly, weekdays: [1, 3, 5]), first: mon) == "Every week on Mon, Wed and Fri")
        #expect(CalRepeatSummary.text(CalRecurrence(.weekly, weekdays: [1, 3]), first: mon) == "Every week on Monday and Wednesday")
    }

    @Test func remindersRowSummary() {
        #expect(AlertsPicker.summary([], allDay: false) == "None")
        #expect(AlertsPicker.summary([60], allDay: false) == "1 hour before")
        #expect(AlertsPicker.summary([1440, 0], allDay: false) == "At time of event, 1 day before")
        #expect(AlertsPicker.summary([0, 5, 15], allDay: false) == "3 reminders")
        #expect(AlertsPicker.summary([900], allDay: true) == "1 day before (9 AM)")
    }

    @Test func heroStamps() {
        let s = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 14), hour: 17, minute: 0, second: 0, in: tz)
        let now = s // "this year" is 2026 for these
        let sameDay = EventText.hero(.timed(start: s, end: s.addingTimeInterval(3600), timeZone: tz.identifier), zone: tz, now: now)
        #expect(sameDay.start.day.contains("Nov") && sameDay.start.day.contains("14") && !sameDay.start.day.contains("2026"))
        let nextYear = EventText.hero(.timed(start: s, end: s.addingTimeInterval(3600), timeZone: tz.identifier), zone: tz,
                                      now: s.addingTimeInterval(-400 * 86_400))
        #expect(nextYear.start.day.contains("2026")) // not this year: the year shows
        #expect(sameDay.end?.day == "\u{00A0}") // one day: no second date
        #expect(sameDay.start.big != sameDay.end?.big)
        let overnight = EventText.hero(.timed(start: s, end: s.addingTimeInterval(10 * 3600), timeZone: tz.identifier), zone: tz, now: now)
        #expect(overnight.end?.day.contains("15") == true)
        let instant = EventText.hero(.timed(start: s, end: s, timeZone: tz.identifier), zone: tz, now: now)
        #expect(instant.end == nil)
        let one = EventText.hero(.allDay(start: CalDate(2026, 11, 14), end: CalDate(2026, 11, 15)), now: now)
        #expect(one.start.big == "All day" && one.end == nil)
        let trip = EventText.hero(.allDay(start: CalDate(2026, 11, 14), end: CalDate(2026, 11, 17)), now: now)
        #expect(trip.start.day == "All day" && trip.end?.big.contains("16") == true)
    }

    @MainActor @Test func slowDownSaysRequests() {
        #expect(CalendarEngine.describe(.slowDown) == "Too many requests — trying again shortly")
    }
}
