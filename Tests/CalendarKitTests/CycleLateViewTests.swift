import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-127 step 4: what the day detail and the settings sheet say when a
/// period is past its estimate with none logged. Both people see it.
@Suite("Cycle, late: the words")
struct CycleLateViewTests {
    private let cal = UUID(), person = UUID()

    /// 28-day cycles from 9-1; the next estimated for 11-24.
    private var est: CalCycleEstimator {
        let days = [CalDate(2026, 9, 1), CalDate(2026, 9, 29), CalDate(2026, 10, 27)].flatMap { s in
            (0..<4).map { CalCycleDay(calendarID: cal, personID: person, date: s.adding(days: $0), flow: .medium) }
        }
        return CalCycleEstimator(days: days, settings: nil)
    }

    @Test func theLateLine() {
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 33, daysPastEstimate: 4), unsettled: false)
                == "Not logged yet · 4 days past the estimate")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 30, daysPastEstimate: 1), unsettled: false)
                == "Not logged yet · 1 day past the estimate")
        // Past 60 days since the last start: only the cycle day.
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 61, daysPastEstimate: 33), unsettled: false) == "Cycle day 61")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 60, daysPastEstimate: 32), unsettled: false)
                == "Not logged yet · 32 days past the estimate")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 20), unsettled: false) == nil)
        // Never the word "late".
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 33, daysPastEstimate: 4), unsettled: false)?.lowercased().contains("late") == false)
    }

    /// Unsettled: the days count from the end of the expected range, not the
    /// dashed estimate, and the words say so. Past 60 it's still the cycle day.
    @Test func theLateLineWhileUnsettled() {
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 45, daysPastEstimate: 9), unsettled: true)
                == "Not logged yet · 9 days past the expected range")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 37, daysPastEstimate: 1), unsettled: true)
                == "Not logged yet · 1 day past the expected range")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 61, daysPastEstimate: 25), unsettled: true) == "Cycle day 61")
        #expect(CycleDaySection.lateLine(CalCycleDayInfo(kind: nil, cycleDay: 45, daysPastEstimate: 9), unsettled: true)?.lowercased().contains("late") == false)
    }

    /// A day with only a late line still shows the card (the design review's
    /// "an empty day shows no card" is about days with nothing on them).
    @Test func aLateLineAloneIsSomething() {
        #expect(CalCycleDayInfo(kind: nil, cycleDay: 33, daysPastEstimate: 4).hasSomething)
        #expect(!CalCycleDayInfo(kind: nil, cycleDay: 33).hasSomething)
        let today = CalDate(2026, 11, 28)
        #expect(est.info(on: today, today: today).hasSomething)
    }

    @Test func theNextPeriodRow() {
        let on = est.nextPeriodLabel(today: CalDate(2026, 11, 20))
        #expect(on != nil && !on!.contains("not logged yet"))
        // Past the estimate: the same date, said to be not logged yet, not a
        // date that's gone by passed off as next.
        let past = est.nextPeriodLabel(today: CalDate(2026, 11, 25))
        #expect(past == on! + " · not logged yet")
    }
}
