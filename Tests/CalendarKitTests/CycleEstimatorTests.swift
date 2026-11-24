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

    // MARK: whole bleeds and the tie-break (MVCALE-127 step 2)

    /// A run of mid-cycle bleeding is one block: the days of it past day 15
    /// don't start a period either (the audit's bug 1: this read as a
    /// 15-day cycle).
    @Test func aLongMidCycleBleedCrossingDay15IsNotAStart() {
        let days = period(9, 1, days: 4) + (12...17).map { day(9, $0, .light) } + period(9, 29, days: 4)
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 29)])
        #expect(e.cycleLength == 28)
        #expect(e.info(on: CalDate(2026, 9, 16)).kind == .logged(.light))
        #expect(e.cycleDay(on: CalDate(2026, 9, 16)) == 16)
        // The same with no period logged after it yet.
        let open = CalCycleEstimator(days: period(9, 1, days: 4) + (12...17).map { day(9, $0, .light) }, settings: nil)
        #expect(open.starts == [CalDate(2026, 9, 1)])
    }

    /// Two bleeds that could both begin a period, less than 15 days apart:
    /// the one nearer when the period was due wins. A bleed on day 17 and
    /// the real period 12 days later read as a 16-day cycle before.
    @Test func ofTwoCloseBleedsTheOneNearerTheDueDateIsThePeriod() {
        let days = period(3, 1, days: 5) + [day(3, 17, .medium), day(3, 18, .light)] + period(3, 29, days: 5)
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.starts == [CalDate(2026, 3, 1), CalDate(2026, 3, 29)])
        #expect(e.cycleLength == 28)
        #expect(e.periodLength == 5) // the day-17 bleed isn't a period
        #expect(e.info(on: CalDate(2026, 3, 17)).kind == .logged(.medium))

        // The due date comes from the person's own cycles: 30 days here, so
        // a bleed on day 24 (6 days early) loses to one on day 35 (4 days
        // late). Against the default 28 it would have won.
        var starts = [CalDate(2026, 1, 1)]
        for _ in 0..<3 { starts.append(starts.last!.adding(days: 30)) } // 1-31, 3-2, 4-1
        let history = starts.flatMap { s in (0..<4).map { CalCycleDay(calendarID: cal, personID: person, date: s.adding(days: $0), flow: .medium) } }
        let last = starts.last!
        let early = CalCycleDay(calendarID: cal, personID: person, date: last.adding(days: 23), flow: .medium)
        let real = (0..<4).map { CalCycleDay(calendarID: cal, personID: person, date: last.adding(days: 34 + $0), flow: .heavy) }
        let f = CalCycleEstimator(days: history + [early] + real, settings: nil)
        #expect(f.starts.last == last.adding(days: 34))
    }

    /// The tie-break's first rule: a bleed marked "Period started" wins over
    /// an unmarked one, even when the unmarked one is nearer the due date.
    @Test func ofTwoCloseBleedsAMarkedStartWins() {
        let days = period(3, 1, days: 5) + [day(3, 27, .medium), day(3, 28, .light)]
            + [mark(4, 6, starts: true, flow: .heavy), mark(4, 7, flow: .medium)]
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.starts == [CalDate(2026, 3, 1), CalDate(2026, 4, 6)])
        // The mark may come on a later day of the bleed: the bleed still
        // wins, and begins on its first day (a mark inside a period marks it).
        let later = period(3, 1, days: 5) + [day(3, 27, .medium), day(3, 28, .light)]
            + [mark(4, 5, flow: .heavy), mark(4, 6, starts: true, flow: .medium)]
        let l = CalCycleEstimator(days: later, settings: nil)
        #expect(l.starts == [CalDate(2026, 3, 1), CalDate(2026, 4, 5)])
        #expect(l.periods.last?.marked == true)
    }

    /// The tie-break's second rule (Stipe's review, Travis): the bleed with
    /// more bleeding days wins before nearness does, so a 1-day spot never
    /// takes a real period's place. A real 17-day cycle keeps its period.
    @Test func ofTwoCloseBleedsTheLongerWins() {
        let history = period(1, 1, days: 4) + period(1, 29, days: 4) + period(2, 26, days: 4)
        // A 5-day period on 3-15 (a 17-day cycle), then a 1-day bleed on
        // 3-25, the day before it was due.
        let short = CalCycleEstimator(days: history + period(3, 15, days: 5) + [day(3, 25, .light)], settings: nil)
        #expect(short.starts.last == CalDate(2026, 3, 15))
        // The mirror: a 1-day bleed on day 17, then the real 5-day period.
        let spot = CalCycleEstimator(days: history + [day(3, 15, .light)] + period(3, 26, days: 5), settings: nil)
        #expect(spot.starts.last == CalDate(2026, 3, 26))
        // Equal lengths fall through to nearness: logging only each period's
        // first day, the spot nearer the due date (3-26) wins. A mark
        // settles it (the known edge).
        let firstDays = [day(1, 1), day(1, 29), day(2, 26), day(3, 15), day(3, 25)]
        #expect(CalCycleEstimator(days: firstDays, settings: nil).starts.last == CalDate(2026, 3, 25))
        let marked = [day(1, 1), day(1, 29), day(2, 26), mark(3, 15, starts: true, flow: .heavy), day(3, 25)]
        #expect(CalCycleEstimator(days: marked, settings: nil).starts.last == CalDate(2026, 3, 15))
    }

    /// A "Period started" mark at least 15 days after the last start begins
    /// a period even inside a mid-cycle block.
    @Test func aStartMarkInsideABleedStillBeginsAPeriod() {
        let days = period(9, 1, days: 4) + (12...16).map { day(9, $0, .light) }
            + [mark(9, 17, starts: true, flow: .medium), mark(9, 18, flow: .medium)]
        let e = CalCycleEstimator(days: days, settings: nil)
        #expect(e.starts == [CalDate(2026, 9, 1), CalDate(2026, 9, 17)])
        #expect(e.periods.last?.marked == true)
    }

    @Test func lengthsAreTheAveragesOfWhatWasLogged() {
        let e = CalCycleEstimator(days: regular, settings: CalCycleSettings(calendarID: cal, personID: person, cycleLength: 35, periodLength: 8))
        #expect(e.cycleLength == 28) // measured wins over the setting
        #expect(e.periodLength == 4) // (4 + 5 + 4) / 3 rounded; spotting doesn't count
    }

    // MARK: odd gaps, resets and the median (MVCALE-127 step 3)

    private func starts(_ gaps: [Int]) -> [CalCycleDay] {
        var s = [CalDate(2026, 1, 1)]
        for g in gaps { s.append(s.last!.adding(days: g)) }
        return s.map { CalCycleDay(calendarID: cal, personID: person, date: $0, flow: .heavy) }
    }

    private func kept(_ gaps: [Int]) -> [Int] {
        CalCycleEstimator.recentGaps(starts: CalCycleEstimator(days: starts(gaps), settings: nil).starts)
    }

    /// A month left unlogged (28, 28, 56) isn't a 56-day cycle: it's dropped
    /// once there are 3 gaps to judge it by (the audit's bug 3: this read as
    /// 37).
    @Test func aMonthLeftUnloggedIsDropped() {
        #expect(CalCycleEstimator(days: starts([28, 28, 56]), settings: nil).cycleLength == 28)
        #expect(kept([28, 28, 56]) == [28, 28])
        #expect(kept([28, 28, 56, 28]) == [28, 28, 28])
        #expect(kept([28, 28, 45, 28]) == [28, 28, 28]) // over 28 + 0 + 15
        // With only 2 gaps there's nothing to judge by yet (open question 4).
        #expect(CalCycleEstimator(days: starts([28, 56]), settings: nil).cycleLength == 42)
    }

    /// Real cycles are kept, short or long: an 18 in a 28-day person, and
    /// the long ones of someone whose cycles vary.
    @Test func realCyclesAreKept() {
        #expect(kept([28, 28, 18]) == [28, 28, 18])
        #expect(CalCycleEstimator(days: starts([28, 28, 18]), settings: nil).cycleLength == 28)
        #expect(kept([24, 35, 26, 33, 25, 34]) == [24, 35, 26, 33, 25, 34])
        #expect(kept([28, 28, 43, 28]) == [28, 28, 43, 28]) // right at 28 + 0 + 15
    }

    /// The median, not the mean, once there are 3 gaps: one long cycle pulls
    /// it less (26, 27, 35: the mean is 29).
    @Test func theMedianOfTheRecentCycles() {
        #expect(CalCycleEstimator(days: starts([26, 27, 35]), settings: nil).cycleLength == 27)
        #expect(CalCycleEstimator(days: starts([26, 27, 35, 30]), settings: nil).cycleLength == 29) // (27 + 30) / 2, rounded
        #expect(CalCycleEstimator(days: starts([28, 33]), settings: nil).cycleLength == 31) // the mean, with 2
    }

    /// A gap over 60 days (a birth, months on the pill) ends the old
    /// history: the cycles after it are the ones that count.
    @Test func aLongGapResetsTheHistory() {
        #expect(CalCycleEstimator(days: starts([28, 28, 28, 120, 33]), settings: nil).cycleLength == 33)
        #expect(kept([28, 28, 28, 120, 33]) == [33])
        let h = CalCycleEstimator.history(CalCycleEstimator(days: starts([28, 28, 28, 120]), settings: nil).starts)
        #expect(h.reset && h.gaps.isEmpty && h.before == [28, 28, 28])
        // Nothing since: the setting, else the cycles before, else 28.
        #expect(CalCycleEstimator(days: starts([30, 30, 30, 120]), settings: nil).cycleLength == 30)
        let set = CalCycleSettings(calendarID: cal, personID: person, cycleLength: 32, periodLength: 0)
        #expect(CalCycleEstimator(days: starts([30, 30, 30, 120]), settings: set).cycleLength == 32)
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

    // MARK: late periods (MVCALE-127 step 4)

    /// The audit's bug 2: 28-day cycles, the last start 10-27, the next
    /// estimated for 11-24, nothing logged by 12-05. The cycle day counts on
    /// from 10-27, the missed expected period stays whole, and nothing is
    /// predicted after it.
    @Test func aLatePeriodCountsOnAndPredictsNothingAfter() {
        let e = CalCycleEstimator(days: regular, settings: nil)
        let today = CalDate(2026, 12, 5)
        func kind(_ m: Int, _ d: Int) -> CalCycleDayInfo.Kind? { e.info(on: CalDate(2026, m, d), today: today).kind }
        #expect(e.overdue(today: today)! == (CalDate(2026, 11, 24), 11))
        #expect(e.cycleDay(on: today, today: today) == 40)
        #expect(e.info(on: today, today: today).cycleDay == 40)
        #expect(e.cycleDay(on: CalDate(2026, 11, 24), today: today) == 29)
        // The missed expected period, whole.
        #expect(kind(11, 24) == .predictedPeriod)
        #expect(kind(11, 27) == .predictedPeriod)
        #expect(kind(11, 28) == nil)
        // Nothing after it: no window (12-03..12-08 was one), no period.
        for d in 3...8 { #expect(kind(12, d) == nil) }
        #expect(kind(12, 22) == nil)
        // The cycle before it keeps its window.
        #expect(kind(11, 10) == .fertile(ovulation: true))
        // Without today, or on the estimate itself, nothing changes.
        #expect(e.info(on: CalDate(2026, 12, 8)).kind == .fertile(ovulation: true))
        #expect(e.overdue(today: CalDate(2026, 11, 24)) == nil)
        #expect(e.info(on: CalDate(2026, 12, 8), today: CalDate(2026, 11, 24)).kind == .fertile(ovulation: true))
        #expect(e.cycleDay(on: CalDate(2026, 11, 30), today: CalDate(2026, 11, 24)) == 7)
    }

    /// The day detail says so only after the grace period, and only on
    /// today: 3 days for steady cycles (11-24 due: 11-27 is still within it).
    @Test func notLoggedYetAfterTheGracePeriod() {
        let e = CalCycleEstimator(days: regular, settings: nil)
        #expect(e.grace == 3)
        func past(_ m: Int, _ d: Int) -> Int? { e.info(on: CalDate(2026, m, d), today: CalDate(2026, m, d)).daysPastEstimate }
        #expect(past(11, 27) == nil)
        #expect(past(11, 28) == 4)
        #expect(past(12, 5) == 11)
        // Another day than today never says it.
        #expect(e.info(on: CalDate(2026, 12, 1), today: CalDate(2026, 12, 5)).daysPastEstimate == nil)
    }

    /// The grace period: half the recent shortest-to-longest spread, kept
    /// between 3 and 5 days; 3 with fewer than 2 gaps.
    @Test func theGracePeriodFollowsTheSpread() {
        #expect(CalCycleEstimator(days: starts([28, 36]), settings: nil).grace == 4)
        #expect(CalCycleEstimator(days: starts([28, 35]), settings: nil).grace == 4) // 3.5 rounds up
        #expect(CalCycleEstimator(days: starts([24, 35, 26, 33, 25, 34]), settings: nil).grace == 5) // 5.5, kept at 5
        #expect(CalCycleEstimator(days: starts([28, 30]), settings: nil).grace == 3) // 1, kept at 3
        #expect(CalCycleEstimator(days: starts([28]), settings: nil).grace == 3)
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

    /// Leaf's review: an end ends a period however it began. Flows then
    /// Ended; a flow, Started the next day, then Ended; Ended right after a run.
    @Test func anEndEndsAPeriodThatBeganWithAFlow() {
        var e = CalCycleEstimator(days: [mark(11, 1, flow: .medium), mark(11, 2, flow: .heavy), mark(11, 4, ends: true)], settings: nil)
        #expect(e.periods == [CalPeriod(start: CalDate(2026, 11, 1), end: CalDate(2026, 11, 4), marked: false)])
        #expect(e.periodLength == 4)
        #expect(e.info(on: CalDate(2026, 11, 3)).kind == .inPeriod)

        e = CalCycleEstimator(days: [mark(11, 1, flow: .medium), mark(11, 2, starts: true), mark(11, 5, ends: true)], settings: nil)
        #expect(e.periods == [CalPeriod(start: CalDate(2026, 11, 1), end: CalDate(2026, 11, 5), marked: true)])
        #expect(e.periodLength == 5)

        e = CalCycleEstimator(days: [mark(11, 1, flow: .heavy), mark(11, 2, flow: .light), mark(11, 7, ends: true)], settings: nil)
        #expect(e.periods.first?.end == CalDate(2026, 11, 7))
        // A flow-only run with no end still ends at its last bleeding day.
        e = CalCycleEstimator(days: [mark(11, 1, flow: .heavy), mark(11, 2, flow: .light)], settings: nil)
        #expect(e.periods == [CalPeriod(start: CalDate(2026, 11, 1), end: CalDate(2026, 11, 2), marked: false)])
    }
}
