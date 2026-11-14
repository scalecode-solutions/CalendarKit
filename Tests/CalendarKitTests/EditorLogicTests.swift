import Foundation
import Testing
@testable import CalendarKit

@MainActor @Suite("Editor logic", .serialized)
struct EditorLogicTests {
    /// "All future events" of a 10-session series opened at the 4th shows the 7
    /// left, which is what gets saved (R3, the editor half).
    @Test func followingEditorStartsAtWhatIsLeft() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        var rule = CalRecurrence(.weekly)
        rule.count = 10
        let s = engine.addEvent(to: own, allDay("Course", 2026, 11, 2, repeating: rule))
        await engine.refresh()
        let occ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2027, 1, 31)).filter { $0.seriesID == s.id }
        #expect(occ.count == 10)
        guard let series = engine.event(s.id) else { Issue.record("no series"); return }
        #expect(EventEditorView.remaining(of: series, from: occ[3]) == 7)
        #expect(EventEditorView.remaining(of: series, from: occ[9]) == 1)
        #expect(EventEditorView.remaining(of: series, from: occ[0]) == nil) // the first: the whole series is edited
    }

    /// An open-ended series has no count to adjust.
    @Test func uncountedSeriesHasNoRemaining() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let occ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2026, 11, 30)).filter { $0.seriesID == s.id }
        guard let series = engine.event(s.id) else { Issue.record("no series"); return }
        #expect(EventEditorView.remaining(of: series, from: occ[2]) == nil)
    }

    // R63/R64: the all-day toggle keeps the days shown and sensible times.
    private let zone = TimeZone(identifier: "America/Chicago")!
    private func at(_ d: CalDate, _ h: Int, _ m: Int = 0) -> Date {
        CalRecurrenceExpander.wallClock(d, hour: h, minute: m, second: 0, in: zone)
    }
    private let earlier = CalRecurrenceExpander.wallClock(CalDate(2026, 11, 1), hour: 8, minute: 0, second: 0,
                                                          in: TimeZone(identifier: "America/Chicago")!)

    @Test func allDayOffGivesAnHourAtNine() {
        var d = CalEventDraft(start: at(CalDate(2026, 11, 14), 0), end: at(CalDate(2026, 11, 14), 0), timeZone: zone)
        d.allDay = true
        d.title = "x"
        d.alerts = [900]
        d.setAllDay(false, now: earlier)
        #expect(d.start == at(CalDate(2026, 11, 14), 9) && d.end == at(CalDate(2026, 11, 14), 10))
        #expect(d.alerts == nil)
        guard case .success(let f) = d.fields(), case .timed(let s, let e, _) = f.when else { Issue.record("fields"); return }
        #expect(e.timeIntervalSince(s) == 3600)
    }

    @Test func multiDayAllDayOffKeepsItsDays() {
        var d = CalEventDraft(start: at(CalDate(2026, 11, 14), 0), end: at(CalDate(2026, 11, 16), 0), timeZone: zone)
        d.allDay = true
        d.setAllDay(false, now: earlier)
        #expect(d.start == at(CalDate(2026, 11, 14), 9) && d.end == at(CalDate(2026, 11, 16), 10))
    }

    @Test func todayGoesToTheNextHour() {
        let now = at(CalDate(2026, 11, 14), 15, 20)
        var d = CalEventDraft(start: at(CalDate(2026, 11, 14), 0), end: at(CalDate(2026, 11, 14), 0), timeZone: zone)
        d.allDay = true
        d.setAllDay(false, now: now)
        #expect(d.start == at(CalDate(2026, 11, 14), 16))
    }

    @Test func allDayOnKeepsTheDaysAndDropsTimedReminders() {
        var d = CalEventDraft(start: at(CalDate(2026, 11, 14), 22), end: at(CalDate(2026, 11, 15), 0), timeZone: zone)
        d.title = "x"
        d.alerts = [15]
        d.setAllDay(true)
        #expect(d.alerts == nil) // 15 minutes before a time would be 23:45 the night before
        guard case .success(let f) = d.fields() else { Issue.record("fields"); return }
        #expect(f.when == .allDay(start: CalDate(2026, 11, 14), end: CalDate(2026, 11, 15))) // midnight end adds no day
    }

    @Test func movingTheStartKeepsTheLength() {
        var d = CalEventDraft(start: at(CalDate(2026, 11, 14), 9), end: at(CalDate(2026, 11, 14), 10, 30), timeZone: zone)
        d.moveStart(to: at(CalDate(2026, 11, 14), 13))
        #expect(d.end == at(CalDate(2026, 11, 14), 14, 30))
    }
}
