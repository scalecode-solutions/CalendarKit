import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-7: the month cells' chips and the agenda's row identity.
@MainActor
@Suite("Main screen")
struct MainScreenTests {
    private func occ(_ title: String, _ color: CalColor, on day: CalDate, days: Int = 1, cal: CalCalendar) -> CalOccurrence {
        let e = CalEvent(id: UUID(), calendarID: cal.id, fields: CalEventFields(title: title, when: .allDay(start: day, end: day.adding(days: days)), color: color),
                         masterID: nil, originalStart: nil, cancelled: false, createdBy: cal.ownerID, updatedBy: cal.ownerID,
                         createdAt: Date(), updatedAt: Date(), rev: 1, deleted: false)
        return OccurrenceBuilder.build(events: [e], exceptions: [], calendars: [cal.id: cal], labels: [:],
                                       from: day, through: day.adding(days: days - 1), zone: .gmt)[0]
    }

    private let cal = CalCalendar(id: UUID(), ownerID: UUID(), name: "Me", color: .teal, role: .owner, rev: 0,
                                  grantExpiresAt: nil, visible: true, prefColor: .none)

    /// Up to two titles in a cell; past that, one and "+N" (two lines, always).
    @Test func cellsShowTwoTitlesOrOneAndMore() {
        let d = CalDate(2026, 11, 14)
        let a = occ("A", .red, on: d, cal: cal), b = occ("B", .none, on: d, cal: cal), c = occ("C", .blue, on: d, cal: cal)
        #expect(DayChip.chips([]) == DayChip.Line())
        #expect(DayChip.chips([a, b]).shown.map(\.title) == ["A", "B"])
        #expect(DayChip.chips([a, b]).more == 0)
        let three = DayChip.chips([a, b, c])
        #expect(three.shown.map(\.title) == ["A"] && three.more == 2)
        // The event's own color wins; else the calendar's.
        #expect(DayChip.chips([a, b]).shown.map(\.color) == [.red, .teal])
    }

    /// A multi-day event is one occurrence on several agenda days: each day's
    /// row needs its own identity, or a lazy stack draws only the first.
    @Test func agendaRowsAreKeyedByDay() {
        let trip = occ("Trip", .none, on: CalDate(2026, 11, 27), days: 3, cal: cal)
        let ids = (0..<3).map { AgendaItem(day: CalDate(2026, 11, 27).adding(days: $0), occurrence: trip).id }
        #expect(Set(ids).count == 3)
    }

    /// The week strip's dots keep the order of the day's events, each color once.
    @Test func weekDotsAreOrderedAndUnique() {
        let d = CalDate(2026, 11, 14)
        let o = [occ("a", .red, on: d, cal: cal), occ("b", .blue, on: d, cal: cal), occ("c", .red, on: d, cal: cal),
                 occ("d", .green, on: d, cal: cal), occ("e", .pink, on: d, cal: cal)]
        #expect(WeekStrip.dots(o) == [.red, .blue, .green])
    }
}
