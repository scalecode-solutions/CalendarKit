import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-127 step 5: how the faint "fertility possible" band and unsettled
/// cycles show.
@Suite("Cycle, the faint band: the views")
struct CycleBandViewTests {
    private let cal = UUID(), person = UUID()

    private func est(_ gaps: [Int]) -> CalCycleEstimator {
        var s = [CalDate(2026, 1, 1)]
        for g in gaps { s.append(s.last!.adding(days: g)) }
        return CalCycleEstimator(days: s.map { CalCycleDay(calendarID: cal, personID: person, date: $0, flow: .heavy) }, settings: nil)
    }

    /// The band never hides another mark: it ranks lowest.
    @Test func theBandRanksLowest() {
        let others: [CalCycleDayInfo.Kind] = [.logged(.light), .inPeriod, .predictedPeriod, .fertile(ovulation: true), .fertile(ovulation: false)]
        for k in others { #expect(PrivateMarks.rank(.fertilePossible) < PrivateMarks.rank(k)) }
        #expect(PrivateMarks.rank(.fertile(ovulation: false)) < PrivateMarks.rank(.fertile(ovulation: true)))
        #expect(PrivateMarks.rank(.fertile(ovulation: true)) < PrivateMarks.rank(.predictedPeriod))
        #expect(PrivateMarks.rank(.predictedPeriod) < PrivateMarks.rank(.inPeriod))
    }

    @Test func itsWords() {
        #expect(PrivateMarks.spoken(.fertilePossible) == "fertility possible")
        #expect(CycleDaySection.estimate(.fertilePossible) == "Fertility possible · estimate")
        #expect(DropMark.kind(.fertilePossible) == nil)
        // Never "safe", anywhere it's described.
        for text in [CycleLegend.lowerChance, CycleLegend.disclaimer, CycleDaySection.unsettledLine,
                     PrivateMarks.spoken(.fertilePossible), CycleDaySection.estimate(.fertilePossible)] {
            #expect(!text.lowercased().contains("safe"))
            #expect(!text.lowercased().contains("irregular"))
        }
        #expect(CycleLegend.lowerChance == "No shading: lower chance, not zero")
    }

    /// Finding 8: a period day in the window says both.
    @Test func aPeriodDayInTheWindow() {
        var info = CalCycleDayInfo(kind: .logged(.medium), cycleDay: 6)
        #expect(CycleDaySection.periodLine(nil, info) == "Period · day 6")
        info.fertileToo = true
        #expect(CycleDaySection.periodLine(nil, info) == "Period · day 6 · fertile window")
    }

    /// The unsettled line goes under estimates only, never a logged day.
    @Test func theUnsettledLineIsForEstimates() {
        #expect(CycleDaySection.isEstimate(.fertilePossible) && CycleDaySection.isEstimate(.predictedPeriod))
        #expect(!CycleDaySection.isEstimate(.logged(.heavy)) && !CycleDaySection.isEstimate(.inPeriod))
    }

    /// While unsettled the next period is a range; settled, a date.
    @Test func theNextPeriodRowWhileUnsettled() {
        let e = est([24, 35, 26, 33, 25, 34])
        let label = e.nextPeriodLabel(today: e.starts.last!)!
        #expect(label.contains(" – "))
        let past = e.nextPeriodLabel(today: e.nextRange!.upperBound.adding(days: 1))!
        #expect(past == label + " · not logged yet")
        #expect(!est([28, 28, 28]).nextPeriodLabel(today: CalDate(2026, 3, 26))!.contains(" – "))
    }
}
