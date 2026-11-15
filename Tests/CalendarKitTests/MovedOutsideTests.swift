import Foundation
import Testing
@testable import CalendarKit

/// R10/R26: an occurrence moved outside its series' days still shows, found
/// by its own days.
@MainActor
@Suite("Engine: moved outside the series", .serialized)
struct MovedOutsideTests {
    private func series(_ engine: CalendarEngine, _ own: UUID) -> CalEvent {
        var rule = CalRecurrence(.weekly)
        rule.until = CalDate(2026, 11, 23) // Nov 2, 9, 16, 23
        return engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: rule))
    }

    @Test func theLastOneMovedPastTheEndShows() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = series(engine, own)
        await engine.refresh()
        let last = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }.last!
        var f = last.event.fields
        f.recurrence = nil
        f.when = .allDay(start: CalDate(2026, 12, 10), end: CalDate(2026, 12, 11))
        engine.updateOccurrence(last, f)
        await engine.refresh()
        let dec = engine.occurrences(from: CalDate(2026, 12, 1), through: CalDate(2026, 12, 31))
        #expect(dec.map(\.when.firstDay) == [CalDate(2026, 12, 10)])
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 3)
    }

    @Test func theFirstOneMovedBeforeTheStartShows() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = series(engine, own)
        await engine.refresh()
        let first = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }.first!
        var f = first.event.fields
        f.recurrence = nil
        f.when = .allDay(start: CalDate(2026, 10, 20), end: CalDate(2026, 10, 21))
        engine.updateOccurrence(first, f)
        await engine.refresh()
        let oct = engine.occurrences(from: CalDate(2026, 10, 1), through: CalDate(2026, 10, 25)) // a week the series doesn't reach
        #expect(oct.map(\.when.firstDay) == [CalDate(2026, 10, 20)])
    }

    /// R23: expansion starts near the range, but an occurrence moved into it
    /// from long before is still matched (and the original slot stays empty).
    @Test func anOccurrenceMovedInFromMonthsBeforeShows() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Pills", 2026, 1, 1, repeating: CalRecurrence(.daily)))
        await engine.refresh()
        let jan5 = engine.occurrences(from: CalDate(2026, 1, 5), through: CalDate(2026, 1, 5)).first { $0.seriesID == s.id }!
        var f = jan5.event.fields
        f.recurrence = nil
        f.title = "Pills (moved)"
        f.when = .allDay(start: CalDate(2026, 11, 10), end: CalDate(2026, 11, 11))
        engine.updateOccurrence(jan5, f)
        await engine.refresh()
        let nov10 = engine.occurrences(from: CalDate(2026, 11, 10), through: CalDate(2026, 11, 10)).map(\.title)
        #expect(nov10.sorted() == ["Pills", "Pills (moved)"])
        #expect(engine.occurrences(from: CalDate(2026, 1, 5), through: CalDate(2026, 1, 5)).isEmpty)
    }
}
