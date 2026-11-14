import Foundation
import Testing
@testable import CalendarKit

/// R23: expanding from a day skips what's before it, and gives exactly the
/// days a full expansion would from there on.
@Suite("Expander: from a day")
struct ExpanderFromTests {
    static let rules: [CalRecurrence] = {
        var out: [CalRecurrence] = []
        for interval in 1...3 {
            out.append(CalRecurrence(.daily, interval: interval))
            out.append(CalRecurrence(.weekly, interval: interval, weekdays: [1, 3, 5]))
            out.append(CalRecurrence(.weekly, interval: interval))
            out.append(CalRecurrence(.monthly, interval: interval, monthly: .dayOfMonth))
            out.append(CalRecurrence(.monthly, interval: interval, monthly: .nthWeekday))
            out.append(CalRecurrence(.yearly, interval: interval))
        }
        var withEnds: [CalRecurrence] = []
        for r in out {
            withEnds.append(r)
            var c = r; c.count = 17; withEnds.append(c)
            var u = r; u.until = CalDate(2026, 3, 9); withEnds.append(u)
        }
        return withEnds
    }()

    @Test(arguments: [CalDate(2024, 1, 31), CalDate(2024, 2, 29), CalDate(2023, 12, 4)])
    func sameDaysAsAFullExpansion(first: CalDate) {
        let through = CalDate(2027, 6, 30)
        for r in Self.rules {
            let full = CalRecurrenceExpander.dates(r, first: first, through: through)
            for offset in stride(from: -40, through: 1200, by: 37) {
                let from = first.adding(days: offset)
                let fast = CalRecurrenceExpander.dates(r, first: first, from: from, through: through)
                #expect(fast == full.filter { $0 >= from }, "\(r) first \(first) from \(from)")
            }
        }
    }

    /// Timed: the same instants, including across a DST change.
    @Test func instantsMatch() {
        let zone = TimeZone(identifier: "America/Chicago")!
        let start = CalRecurrenceExpander.wallClock(CalDate(2023, 11, 1), hour: 2, minute: 30, second: 0, in: zone)
        for r in [CalRecurrence(.daily), CalRecurrence(.weekly, interval: 2, weekdays: [3, 7])] {
            let full = CalRecurrenceExpander.instants(r, start: start, timeZone: zone, through: CalDate(2026, 12, 31))
            let from = CalDate(2026, 3, 1)
            let fast = CalRecurrenceExpander.instants(r, start: start, timeZone: zone, from: from, through: CalDate(2026, 12, 31))
            #expect(fast == full.filter { CalDate($0, in: zone) >= from })
        }
    }
}

/// R50: a counted series is stored with the day it ends, so a finished one
/// isn't fetched for every later range.
@Suite("Store: counted series span")
struct CountedSpanTests {
    @Test func aCountedSeriesEndsAtItsLastOccurrence() {
        var r = CalRecurrence(.weekly)
        r.count = 10 // Mondays from Jan 1 2024: the 10th is Mar 4
        let e = CalEvent(id: UUID(), calendarID: UUID(), fields: allDay("Physio", 2024, 1, 1, repeating: r),
                         masterID: nil, originalStart: nil, cancelled: false, createdBy: UUID(), updatedBy: UUID(),
                         createdAt: Date(), updatedAt: Date(), rev: 1, deleted: false)
        let (_, last) = EventRecord.span(e)
        #expect(last == EventRecord.dayNumber(CalDate(2024, 3, 5))) // a day past it, as with until
        r.count = nil
        var open = e
        open.fields.recurrence = r
        #expect(EventRecord.span(open).1 == .max)
    }
}
