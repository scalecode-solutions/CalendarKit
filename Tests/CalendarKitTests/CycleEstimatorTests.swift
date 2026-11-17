import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-28 (design sprint): the calendar-method estimates made on the phone
/// from logged days (Cycle.swift). Estimates only; these pin the arithmetic.
@Suite("Cycle estimator")
struct CycleEstimatorTests {
    private let cal = UUID(), person = UUID()

    private func day(_ m: Int, _ d: Int, _ flow: CalFlow = .medium, y: Int = 2026, deleted: Bool = false) -> CalCycleDay {
        CalCycleDay(calendarID: cal, personID: person, date: CalDate(y, m, d), flow: flow, deleted: deleted)
    }

    /// Days of bleeding from a start, inclusive.
    private func period(_ m: Int, _ d: Int, days n: Int) -> [CalCycleDay] {
        (0..<n).map { i in
            let date = CalDate(2026, m, d).adding(days: i)
            return CalCycleDay(calendarID: cal, personID: person, date: date, flow: i == 0 ? .heavy : .light)
        }
    }

    /// Three periods 28 days apart, of 4, 5 and 4 days, and a spotting day
    /// mid-cycle.
    private var regular: [CalCycleDay] {
        period(9, 1, days: 4) + period(9, 29, days: 5) + period(10, 27, days: 4) + [day(9, 20, .spotting)]
    }

    @Test func startsComeFromBleedingAfterAGap() {
        let e = CalCycleEstimator(days: regular.shuffled(), settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 29), CalDate(2026, 10, 27)])
    }

    @Test func spottingNeverStartsAPeriod() {
        let e = CalCycleEstimator(days: [day(10, 25, .spotting), day(10, 26, .spotting)] + period(10, 27, days: 3), settings: nil)
        #expect(e.starts == [CalDate(2026, 10, 27)])
        #expect(CalCycleEstimator(days: [day(10, 1, .spotting)], settings: nil).starts.isEmpty)
    }

    /// A bleeding day up to 3 days after the last one continues the period.
    @Test func aShortBreakContinuesAPeriod() {
        #expect(CalCycleEstimator(days: [day(11, 1, .heavy), day(11, 4, .light)], settings: nil).starts == [CalDate(2026, 11, 1)])
        // The continuation counts in the period's length.
        #expect(CalCycleEstimator(days: [day(11, 1, .heavy), day(11, 4, .light)], settings: nil).periodLength == 4)
    }

    /// Bleeding less than 15 days after a start is mid-cycle (Frond, d630ea1):
    /// not a start, so it doesn't shorten the cycle, and not part of the
    /// period, so it doesn't lengthen it.
    @Test func aMidCycleBleedIsNeitherAStartNorPartOfThePeriod() {
        let days = period(9, 1, days: 4) + [day(9, 10, .medium)] + period(9, 29, days: 4)
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 29)])
        #expect(e.cycleLength == 28)
        #expect(e.periodLength == 4)
        #expect(e.info(on: CalDate(2026, 9, 10)).kind == .logged(.medium))
        #expect(e.cycleDay(on: CalDate(2026, 9, 10)) == 10)
    }

    @Test func lengthsAreTheAveragesOfWhatWasLogged() {
        let e = CalCycleEstimator(days: regular, settings: CalCycleSettings(calendarID: cal, personID: person, cycleLength: 35, periodLength: 8))
        #expect(e.cycleLength == 28) // measured wins over the setting
        #expect(e.periodLength == 4) // (4 + 5 + 4) / 3 rounded; spotting doesn't count
    }

    @Test func onlyTheLastSixCyclesCount() {
        // Starts 40, 40, then six 26-day cycles apart.
        var starts = [CalDate(2026, 1, 1)]
        for gap in [40, 40, 26, 26, 26, 26, 26, 26] { starts.append(starts.last!.adding(days: gap)) }
        let days = starts.map { CalCycleDay(calendarID: cal, personID: person, date: $0, flow: .heavy) }
        #expect(CalCycleEstimator(days: days, settings: nil).cycleLength == 26)
    }

    /// A gap outside 15...60 days (a missed log) isn't a cycle.
    @Test func implausibleGapsAreIgnored() {
        let days = [day(1, 1, .heavy), day(3, 30, .heavy)] // 88 days
        #expect(CalCycleEstimator(days: days, settings: nil).cycleLength == 28)
        let set = CalCycleSettings(calendarID: cal, personID: person, cycleLength: 31, periodLength: 0)
        #expect(CalCycleEstimator(days: days, settings: set).cycleLength == 31)
    }

    @Test func withNothingLoggedTheSettingsElseTheDefaults() {
        let set = CalCycleSettings(calendarID: cal, personID: person, cycleLength: 30, periodLength: 6)
        #expect(CalCycleEstimator(days: [], settings: set).cycleLength == 30)
        #expect(CalCycleEstimator(days: [], settings: set).periodLength == 6)
        let measure = CalCycleSettings(calendarID: cal, personID: person) // 0 = measure
        #expect(CalCycleEstimator(days: [], settings: measure).cycleLength == 28)
        #expect(CalCycleEstimator(days: [], settings: nil).periodLength == 5)
        #expect(CalCycleEstimator(days: [], settings: nil).predictedStarts().isEmpty)
        #expect(CalCycleEstimator(days: [], settings: nil).info(on: CalDate(2026, 11, 16)) == CalCycleDayInfo(kind: nil, cycleDay: nil))
    }

    @Test func deletedDaysAreIgnored() {
        let e = CalCycleEstimator(days: regular + [day(10, 13, .heavy, deleted: true)], settings: nil)
        #expect(e.starts.count == 3)
        #expect(e.info(on: CalDate(2026, 10, 13)).kind != .logged(.heavy))
    }

    @Test func theNextStartsFollowTheLastByTheCycleLength() {
        let e = CalCycleEstimator(days: regular, settings: nil)
        #expect(e.predictedStarts() == [CalDate(2026, 11, 24), CalDate(2026, 12, 22), CalDate(2027, 1, 19)])
        #expect(e.predictedStarts(count: 1) == [CalDate(2026, 11, 24)])
    }

    @Test func whatEachDayIs() {
        let e = CalCycleEstimator(days: regular, settings: nil)
        func kind(_ m: Int, _ d: Int, y: Int = 2026) -> CalCycleDayInfo.Kind? { e.info(on: CalDate(y, m, d)).kind }
        // Logged days, as logged.
        #expect(kind(10, 27) == .logged(.heavy))
        #expect(kind(9, 20) == .logged(.spotting))
        // The predicted period: from 11-24 for 4 days.
        #expect(kind(11, 24) == .predictedPeriod)
        #expect(kind(11, 27) == .predictedPeriod)
        #expect(kind(11, 28) == nil)
        // Ovulation 14 days before the next start (11-10), the window the 5 days before it.
        #expect(kind(11, 10) == .fertile(ovulation: true))
        #expect(kind(11, 5) == .fertile(ovulation: false))
        #expect(kind(11, 4) == nil)
        #expect(kind(11, 11) == nil)
        // A past cycle's window is from its logged next start (9-29 → ovulation 9-15).
        #expect(kind(9, 15) == .fertile(ovulation: true))
        // Before the first logged start there is no cycle to estimate in.
        #expect(kind(8, 18) == nil)
        // The predicted cycles after the next one have windows too (12-22 → 12-08).
        #expect(kind(12, 8) == .fertile(ovulation: true))
        #expect(kind(12, 22) == .predictedPeriod)
    }

    @Test func theCycleDayCountsFromTheLatestStart() {
        let e = CalCycleEstimator(days: regular, settings: nil)
        #expect(e.cycleDay(on: CalDate(2026, 8, 31)) == nil)
        #expect(e.cycleDay(on: CalDate(2026, 9, 1)) == 1)
        #expect(e.cycleDay(on: CalDate(2026, 11, 10)) == 15) // from 10-27
        #expect(e.cycleDay(on: CalDate(2026, 11, 24)) == 1) // a predicted start
        #expect(e.cycleDay(on: CalDate(2026, 11, 30)) == 7)
        #expect(e.info(on: CalDate(2026, 10, 28)).cycleDay == 2)
    }

    @Test func flowsAndStarting() {
        #expect(CalFlow.allCases.filter(\.startsAPeriod) == [.light, .medium, .heavy])
    }

    // MARK: marked starts and ends (MVCALE-52)

    private func mark(_ m: Int, _ d: Int, starts: Bool = false, ends: Bool = false, flow: CalFlow? = nil) -> CalCycleDay {
        CalCycleDay(calendarID: cal, personID: person, date: CalDate(2026, m, d), flow: flow, starts: starts, ends: ends)
    }

    /// Two taps a period: everything between a marked start and end is a
    /// period day, logged or not, and ended periods set the length.
    @Test func markedPeriodsFillAndSetTheLength() {
        let e = CalCycleEstimator(days: [mark(9, 1, starts: true), mark(9, 6, ends: true),
                                         mark(9, 29, starts: true), mark(10, 4, ends: true, flow: .light)], settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 29)])
        #expect(e.periodLength == 6)
        #expect(e.cycleLength == 28)
        #expect(e.info(on: CalDate(2026, 9, 3)).kind == .inPeriod)
        #expect(e.info(on: CalDate(2026, 10, 4)).kind == .logged(.light))
        #expect(e.info(on: CalDate(2026, 9, 7)).kind == nil)
        // The fertile window still comes from the next start.
        #expect(e.info(on: CalDate(2026, 9, 15)).kind == .fertile(ovulation: true))
    }

    /// An open period runs its usual length, and on through today until it's
    /// ended; past the usual length the day asks whether it ended. It doesn't
    /// count toward the average.
    @Test func anOpenPeriodRunsUntilEndedAndAsks() {
        let days = [mark(9, 1, starts: true), mark(9, 4, ends: true), mark(9, 29, starts: true)]
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.periodLength == 4) // only the ended one
        let today = CalDate(2026, 10, 5)
        let usual = e.info(on: CalDate(2026, 10, 2), today: today)
        #expect(usual.kind == .inPeriod && !usual.askIfEnded && usual.openPeriod?.start == CalDate(2026, 9, 29))
        let past = e.info(on: CalDate(2026, 10, 4), today: today)
        #expect(past.kind == .inPeriod && past.askIfEnded)
        #expect(e.info(on: CalDate(2026, 10, 6), today: today).kind != .inPeriod)
        // Never more than 12 days open.
        #expect(e.info(on: CalDate(2026, 10, 11), today: CalDate(2026, 10, 30)).kind != .inPeriod)
    }

    /// Strays: an end with no start before it, a second start inside a
    /// period, and spotting in it, change nothing.
    @Test func strayMarksAreIgnored() {
        let e = CalCycleEstimator(days: [mark(8, 20, ends: true), mark(9, 1, starts: true), mark(9, 3, starts: true),
                                         mark(9, 4, flow: .spotting), mark(9, 5, ends: true)], settings: nil)
        #expect(e.periods == [CalPeriod(start: CalDate(2026, 9, 1), end: CalDate(2026, 9, 5), marked: true)])
        #expect(e.periodLength == 5)
    }

    /// Days logged before marks existed still make periods from their runs,
    /// beside marked ones.
    @Test func unmarkedRunsStillCount() {
        let e = CalCycleEstimator(days: period(9, 1, days: 4) + [mark(9, 29, starts: true), mark(10, 3, ends: true)], settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 29)])
        #expect(e.periodLength == 5) // (4 + 5) / 2, rounded
    }
}
