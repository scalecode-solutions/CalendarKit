import Foundation
import Testing
@testable import CalendarKit

@Suite("UI logic")
struct UILogicTests {
    @Test func monthLayoutMondayFirst() {
        let m = MonthLayout(year: 2026, month: 11, firstWeekday: 2) // Nov 1 2026 is a Sunday
        #expect(m.weeks.count == 6)
        #expect(m.weeks[0][0] == CalDate(2026, 10, 26) && m.weeks[0][6] == CalDate(2026, 11, 1))
        #expect(m.weeks.last!.last! == CalDate(2026, 12, 6))
        #expect(m.weeks.flatMap { $0 }.filter(m.contains).count == 30)
    }

    @Test func monthLayoutSundayFirst() {
        let m = MonthLayout(year: 2026, month: 11, firstWeekday: 1)
        #expect(m.weeks.count == 5)
        #expect(m.weeks[0][0] == CalDate(2026, 11, 1))
        let feb = MonthLayout(year: 2026, month: 2, firstWeekday: 1) // Feb 1 2026 is a Sunday, 28 days
        #expect(feb.weeks.count == 4)
        #expect(m.previous == (2026, 10) && MonthLayout(year: 2026, month: 12, firstWeekday: 1).next == (2027, 1))
    }

    @Test func weekdaySymbolsRotate() {
        let en = Locale(identifier: "en_US")
        #expect(MonthLayout.weekdaySymbols(firstWeekday: 2, locale: en) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(MonthLayout.weekdaySymbols(firstWeekday: 1, locale: en).first == "S")
    }

    @Test func repeatSummaries() {
        let mon = CalDate(2026, 11, 16), tue2 = CalDate(2026, 11, 10), lastFri = CalDate(2026, 11, 27)
        #expect(CalRepeatSummary.text(CalRecurrence(.weekly), first: mon) == "Every week on Monday")
        #expect(CalRepeatSummary.text(CalRecurrence(.weekly, interval: 2, weekdays: [3, 1], count: 6), first: mon)
                == "Every 2 weeks on Monday and Wednesday, 6 times")
        #expect(CalRepeatSummary.text(CalRecurrence(.weekly, weekdays: [1, 2, 3, 4, 5]), first: mon) == "Every weekday")
        #expect(CalRepeatSummary.text(CalRecurrence(.monthly, monthly: .nthWeekday), first: tue2) == "Every month on the second Tuesday")
        #expect(CalRepeatSummary.text(CalRecurrence(.monthly, monthly: .lastWeekday), first: lastFri) == "Every month on the last Friday")
        #expect(CalRepeatSummary.text(CalRecurrence(.monthly), first: CalDate(2026, 1, 31)) == "Every month on the 31st")
        #expect(CalRepeatSummary.text(CalRecurrence(.daily, count: 1), first: mon) == "Every day, once")
        #expect(CalRepeatSummary.ordinalDay(11) == "11th" && CalRepeatSummary.ordinalDay(22) == "22nd" && CalRepeatSummary.ordinalDay(3) == "3rd")
    }

    @Test func presetsRoundTrip() {
        let mon = CalDate(2026, 11, 16)
        for p in CalRepeatPreset.allCases where p != .custom {
            #expect(CalRepeatPreset.of(p.rule(), first: mon) == p, "\(p)")
        }
        #expect(CalRepeatPreset.of(CalRecurrence(.weekly, weekdays: [2]), first: CalDate(2026, 11, 17)) == .weekly)
        #expect(CalRepeatPreset.of(CalRecurrence(.daily, interval: 3), first: mon) == .custom)
    }

    let chicago = TimeZone(identifier: "America/Chicago")!

    @Test func draftValidation() {
        let s = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 16), hour: 9, minute: 0, second: 0, in: chicago)
        var d = CalEventDraft(start: s, end: s.addingTimeInterval(3600), timeZone: chicago)
        #expect(d.fields() == .failure(.noTitle))
        d.title = "  PT  "
        guard case .success(let f) = d.fields() else { Issue.record("should save"); return }
        #expect(f.title == "PT" && f.when == .timed(start: s, end: s.addingTimeInterval(3600), timeZone: "America/Chicago"))
        d.end = s.addingTimeInterval(-60)
        #expect(d.fields() == .failure(.endBeforeStart))
        d.end = s.addingTimeInterval(3600)
        d.title = String(repeating: "é", count: 201)
        #expect(d.fields() == .failure(.titleTooLong))
        d.title = "PT"
        d.repeatPreset = .weekly
        d.ending = .on(CalDate(2026, 11, 15))
        #expect(d.fields() == .failure(.endsBeforeItStarts))
        d.ending = .after(0)
        #expect(d.fields() == .failure(.badCount))
        d.ending = .after(6)
        if case .success(let f) = d.fields() { #expect(f.recurrence == CalRecurrence(.weekly, weekdays: [1], count: 6)) }
    }

    @Test func draftFixesRulesTheServerWouldRefuse() {
        // Custom weekly without the start's day: the start's day is added.
        let tue = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 17), hour: 9, minute: 0, second: 0, in: chicago)
        var d = CalEventDraft(start: tue, end: tue, timeZone: chicago)
        d.title = "x"
        d.repeatPreset = .custom
        d.customRule = CalRecurrence(.weekly, weekdays: [4])
        if case .success(let f) = d.fields() { #expect(f.recurrence?.weekdays == [2, 4]) }
        // "Last Tuesday" on a day that isn't the last one becomes "nth".
        d.customRule = CalRecurrence(.monthly, monthly: .lastWeekday)
        if case .success(let f) = d.fields() { #expect(f.recurrence?.monthly == .nthWeekday) }
    }

    /// R2: switching a custom rule away from weekly drops its weekdays (the
    /// server refuses weekdays on anything else), and the monthly mode only
    /// stays on a monthly rule.
    @Test func switchingAwayFromWeeklyDropsTheWeekdays() {
        let tue = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 17), hour: 9, minute: 0, second: 0, in: chicago)
        var d = CalEventDraft(start: tue, end: tue, timeZone: chicago)
        d.title = "x"
        d.repeatPreset = .custom
        d.customRule = CalRecurrence(.weekly, weekdays: [2, 4])
        d.customRule.frequency = .monthly
        if case .success(let f) = d.fields() { #expect(f.recurrence?.weekdays == []) } else { Issue.record("should save") }
        d.customRule = CalRecurrence(.monthly, weekdays: [2], monthly: .nthWeekday)
        d.customRule.frequency = .daily
        if case .success(let f) = d.fields() {
            #expect(f.recurrence?.weekdays == [] && f.recurrence?.monthly == .dayOfMonth)
        }
    }

    /// R6: the same rule in another weekday order is the same rule.
    @Test func ruleOrderDoesNotMatter() {
        let a = CalRecurrenceExpander.canonical(CalRecurrence(.weekly, weekdays: [7, 3]))
        let b = CalRecurrenceExpander.canonical(CalRecurrence(.weekly, weekdays: [3, 7, 3]))
        #expect(a == b && a.weekdays == [3, 7])
    }

    @Test func allDayDraftsAreInclusiveForPeopleExclusiveOnTheWire() {
        let day = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 20), hour: 0, minute: 0, second: 0, in: chicago)
        var d = CalEventDraft(start: day, end: day, timeZone: chicago)
        d.title = "Work"
        d.allDay = true
        #expect(d.fields().map(\.when) == .success(.allDay(start: CalDate(2026, 11, 20), end: CalDate(2026, 11, 21))))
        let back = CalEventDraft(CalEventFields(title: "Work", when: .allDay(start: CalDate(2026, 11, 20), end: CalDate(2026, 11, 22))),
                                 calendarID: UUID())
        #expect(back.allDay && CalDate(back.end, in: back.timeZone) == CalDate(2026, 11, 21))
    }

    @Test func newDraftStartsAtTheNextHourToday() {
        let now = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 14), hour: 10, minute: 20, second: 0, in: chicago)
        let today = CalEventDraft.new(on: CalDate(2026, 11, 14), now: now, zone: chicago, calendarID: nil)
        #expect(today.start == CalRecurrenceExpander.wallClock(CalDate(2026, 11, 14), hour: 11, minute: 0, second: 0, in: chicago))
        let later = CalEventDraft.new(on: CalDate(2026, 11, 20), now: now, zone: chicago, calendarID: nil)
        #expect(later.start == CalRecurrenceExpander.wallClock(CalDate(2026, 11, 20), hour: 9, minute: 0, second: 0, in: chicago))
    }
}
