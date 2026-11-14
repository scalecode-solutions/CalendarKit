import Foundation
import Testing
@testable import CalendarKit

/// The golden recurrence cases from mvCalendar (testdata/recurrence/cases.json,
/// answered by python-dateutil). The copy here must stay byte-identical:
/// mvCalendar's `scripts/recurrence_golden.py --check` verifies it.
struct GoldenCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Rule: Decodable, Sendable {
        let freq: String
        let interval: Int?
        let by_weekday: [String]?
        let monthly: String?
        let until: String?
        let count: Int?
    }
    let name: String
    let all_day: Bool?
    let start: String
    let time_zone: String?
    let rule: Rule
    let take: Int?
    let expect: [String]

    var testDescription: String { name }

    static func load() throws -> [GoldenCase] {
        let url = try #require(Bundle.module.url(forResource: "recurrence-cases", withExtension: "json"))
        struct Doc: Decodable { let cases: [GoldenCase] }
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url)).cases
    }

    static let all: [GoldenCase] = (try? load()) ?? []
}

private let isoDays = ["MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7]

private func day(_ s: String) -> CalDate {
    let p = s.prefix(10).split(separator: "-").map { Int($0)! }
    return CalDate(p[0], p[1], p[2])
}

private func utcString(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: d)
}

@Suite("Golden recurrence cases")
struct GoldenRecurrenceTests {
    @Test func theFileIsThere() {
        #expect(GoldenCase.all.count >= 20)
    }

    @Test(arguments: GoldenCase.all)
    func expands(_ c: GoldenCase) throws {
        var rule = CalRecurrence(CalFrequency(rawValue: c.rule.freq)!, interval: c.rule.interval ?? 1,
                                 weekdays: (c.rule.by_weekday ?? []).map { isoDays[$0]! },
                                 until: c.rule.until.map(day), count: c.rule.count)
        switch c.rule.monthly {
        case "nth_weekday": rule.monthly = .nthWeekday
        case "last_weekday": rule.monthly = .lastWeekday
        default: rule.monthly = .dayOfMonth
        }
        let take = c.take ?? 50
        let got: [String]
        if c.all_day == true {
            got = CalRecurrenceExpander.dates(rule, first: day(c.start), limit: take).map(\.description)
        } else {
            let zone = try #require(TimeZone(identifier: c.time_zone ?? ""))
            let hm = c.start.dropFirst(11).split(separator: ":").map { Int($0)! }
            let start = CalRecurrenceExpander.wallClock(day(c.start), hour: hm[0], minute: hm[1], second: 0, in: zone)
            got = CalRecurrenceExpander.instants(rule, start: start, timeZone: zone, limit: take).map(utcString)
        }
        #expect(got == c.expect)
    }
}

@Suite("Expander details")
struct ExpanderTests {
    @Test func throughStopsEarlyButCountStillCountsFromTheStart() {
        let r = CalRecurrence(.daily, count: 10)
        let first = CalDate(2026, 11, 1)
        #expect(CalRecurrenceExpander.dates(r, first: first, through: CalDate(2026, 11, 3)).count == 3)
        #expect(CalRecurrenceExpander.dates(r, first: first, through: CalDate(2027, 1, 1)).count == 10)
    }

    @Test func weeklyWithoutDaysUsesTheStartsDay() {
        let d = CalRecurrenceExpander.dates(CalRecurrence(.weekly), first: CalDate(2026, 11, 18), limit: 2)
        #expect(d == [CalDate(2026, 11, 18), CalDate(2026, 11, 25)])
    }

    @Test func aRuleThatNeverLandsEnds() {
        // Feb 29 yearly with an until before the next leap year: one occurrence, no hang.
        let d = CalRecurrenceExpander.dates(CalRecurrence(.yearly, until: CalDate(2031, 1, 1)), first: CalDate(2028, 2, 29))
        #expect(d == [CalDate(2028, 2, 29)])
    }

    @Test func calDateBasics() {
        #expect(CalDate(2026, 2, 29).isValid == false)
        #expect(CalDate(2028, 2, 29).isValid)
        #expect(CalDate(2026, 11, 16).isoWeekday == 1)
        #expect(CalDate(2026, 11, 22).isoWeekday == 7)
        #expect(CalDate(2026, 12, 31).adding(days: 1) == CalDate(2027, 1, 1))
        #expect(CalDate(2026, 3, 1).days(to: CalDate(2026, 3, 31)) == 30)
    }
}
