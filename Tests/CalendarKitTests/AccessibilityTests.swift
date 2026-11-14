import Foundation
import Testing
@testable import CalendarKit

@Suite("Accessibility and locale")
struct AccessibilityTests {
    private func calendar(_ locale: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: locale)
        return c
    }

    /// Chips follow the person's week: Monday-first, Sunday-first, Saturday-first.
    @Test func chipOrderFollowsTheFirstWeekday() {
        #expect(WeekdayChips.order(firstWeekday: 2) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeekdayChips.order(firstWeekday: 1) == [7, 1, 2, 3, 4, 5, 6])
        #expect(WeekdayChips.order(firstWeekday: 7) == [6, 7, 1, 2, 3, 4, 5])
    }

    /// ISO and Foundation numbering round-trip.
    @Test func weekdayNumbering() {
        for i in 1...7 { #expect(WeekdayChips.iso(gregorian: WeekdayChips.gregorian(iso: i)) == i) }
        #expect(WeekdayChips.gregorian(iso: 7) == 1) // Sunday
        #expect(WeekdayChips.gregorian(iso: 1) == 2) // Monday
    }

    /// Letters and names come from the locale, keyed by ISO number.
    @Test func chipsSpeakTheLocale() {
        #expect(WeekdayChips.letter(1, calendar: calendar("en_US")) == "M")
        #expect(WeekdayChips.name(7, calendar: calendar("en_US")) == "Sunday")
        #expect(WeekdayChips.name(1, calendar: calendar("fr_FR")) == "lundi")
        #expect(WeekdayChips.name(3, calendar: calendar("de_DE")) == "Mittwoch")
    }

    /// VoiceOver hears a date, not "2026-11-14"; today and the event count are said.
    @Test func daysAreSpokenAsDates() {
        let s = DayCell.spoken(CalDate(2026, 11, 14), isToday: true, events: 2)
        #expect(s.hasPrefix("Today, "), "\(s)")
        #expect(s.contains("14") && !s.contains("2026-11-14"), "\(s)")
        #expect(s.hasSuffix("2 events"), "\(s)")
        #expect(DayCell.spoken(CalDate(2026, 11, 15), isToday: false, events: 1).hasSuffix("1 event"))
        #expect(!DayCell.spoken(CalDate(2026, 11, 16), isToday: false, events: 0).contains("event"))
    }
}
