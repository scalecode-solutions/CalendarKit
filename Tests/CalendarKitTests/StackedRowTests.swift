import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-44: the day view's rows and header stack, so their words are whole
/// at large text sizes. The time line and what VoiceOver reads.
@Suite("Stacked rows")
struct StackedRowTests {
    let chicago = TimeZone(identifier: "America/Chicago")!

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = chicago
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func aSameDayEventReadsAsOneRange() {
        let line = AgendaRow.timeLine(.timed(start: at(2026, 11, 16, 9), end: at(2026, 11, 16, 10), timeZone: "America/Chicago"),
                                      on: CalDate(2026, 11, 16), zone: chicago)
        #expect(line.contains("9") && line.contains("10") && line.contains("–"), "\(line)")
        #expect(!line.contains("Nov") && !line.contains("16"), "no date on a same-day range: \(line)")
    }

    @Test func endingAtMidnightIsStillTheSameDay() {
        let line = AgendaRow.timeLine(.timed(start: at(2026, 11, 16, 22), end: at(2026, 11, 17, 0), timeZone: "America/Chicago"),
                                      on: CalDate(2026, 11, 16), zone: chicago)
        #expect(!line.contains("Nov") && !line.contains("17") && !line.contains("/"), "an end at midnight carries no date: \(line)")
        #expect(line.contains("–"), "\(line)")
    }

    @Test func crossingMidnightCarriesTheDates() {
        let line = AgendaRow.timeLine(.timed(start: at(2026, 11, 16, 21), end: at(2026, 11, 17, 2), timeZone: "America/Chicago"),
                                      on: CalDate(2026, 11, 16), zone: chicago)
        #expect(line.contains("Nov 16") && line.contains("Nov 17"), "\(line)")
    }

    @Test func aMomentShowsItsStartOnly() {
        let t = at(2026, 11, 16, 9, 30)
        let line = AgendaRow.timeLine(.timed(start: t, end: t, timeZone: "America/Chicago"), on: CalDate(2026, 11, 16), zone: chicago)
        #expect(line.contains("9:30") && !line.contains("–"), "\(line)")
    }

    @Test func allDayAndARunOfDays() {
        #expect(AgendaRow.timeLine(.allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 17)),
                                   on: CalDate(2026, 11, 16), zone: chicago) == "All day")
        #expect(AgendaRow.timeLine(.allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 19)),
                                   on: CalDate(2026, 11, 17), zone: chicago) == "All day · day 2 of 3")
    }

    /// Title first (what it is, then when), the way the system calendar reads.
    @Test func voiceOverReadsTheTitleFirst() {
        #expect(AgendaRow.spoken(title: "Dentist", time: "9:00 – 10:00 AM", location: "Main St", repeats: true, who: "Added by Sam")
                == "Dentist, 9:00 – 10:00 AM, Main St, Repeats, Added by Sam")
        #expect(AgendaRow.spoken(title: "Dentist", time: "All day", location: "", repeats: false, who: nil) == "Dentist, All day")
    }
}
