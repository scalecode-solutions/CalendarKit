import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-32: the day view shows what touches its day, and "Opens on" picks
/// the view a fresh calendar screen starts on.
@MainActor
@Suite("Day view", .serialized)
struct DayViewTests {
    @Test func aDayHoldsEverythingThatTouchesIt() async {
        let (engine, server, own) = makeEngine()
        _ = server.externalCreate(own, allDay("Dentist", 2026, 11, 10))
        // Three days, the 9th to the 11th: on each of them, not just the first.
        _ = server.externalCreate(own, CalEventFields(title: "Trip",
            when: .allDay(start: CalDate(2026, 11, 9), end: CalDate(2026, 11, 12))))
        _ = server.externalCreate(own, allDay("Other day", 2026, 11, 12))
        await engine.refresh()
        let zone = TimeZone(identifier: "America/Chicago")!
        #expect(Set(DayIndex.occurrences(on: CalDate(2026, 11, 10), engine: engine, zone: zone).map(\.title)) == ["Dentist", "Trip"])
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 9), engine: engine, zone: zone).map(\.title) == ["Trip"])
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 11), engine: engine, zone: zone).map(\.title) == ["Trip"])
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 12), engine: engine, zone: zone).map(\.title) == ["Other day"])
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 13), engine: engine, zone: zone).isEmpty)
    }

    @Test func aTimedEventEndingAtMidnightStaysOnItsDay() async {
        let (engine, server, own) = makeEngine()
        let zone = TimeZone(identifier: "America/Chicago")!
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        let start = c.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 22))!
        let end = c.date(from: DateComponents(year: 2026, month: 11, day: 11))!
        _ = server.externalCreate(own, CalEventFields(title: "Late", when: .timed(start: start, end: end, timeZone: zone.identifier)))
        await engine.refresh()
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 10), engine: engine, zone: zone).map(\.title) == ["Late"])
        #expect(DayIndex.occurrences(on: CalDate(2026, 11, 11), engine: engine, zone: zone).isEmpty)
    }

    @Test func opensOnPicksTheStartingView() throws {
        let d = try #require(UserDefaults(suiteName: "DayViewTests-\(UUID().uuidString)"))
        // Nothing stored: the month, as before 0.7.0.
        #expect(CalendarOpensOn.startMode(d) == .month)
        // Last used (the default) follows the remembered switch.
        d.set(CalendarMode.agenda.rawValue, forKey: CalendarMode.storageKey)
        #expect(CalendarOpensOn.startMode(d) == .agenda)
        d.set(CalendarOpensOn.lastUsed.rawValue, forKey: CalendarOpensOn.storageKey)
        #expect(CalendarOpensOn.startMode(d) == .agenda)
        // A fixed choice wins over the remembered one.
        d.set(CalendarOpensOn.month.rawValue, forKey: CalendarOpensOn.storageKey)
        #expect(CalendarOpensOn.startMode(d) == .month)
        d.set(CalendarMode.month.rawValue, forKey: CalendarMode.storageKey)
        d.set(CalendarOpensOn.agenda.rawValue, forKey: CalendarOpensOn.storageKey)
        #expect(CalendarOpensOn.startMode(d) == .agenda)
        // Something unreadable falls back to Last used.
        d.set("weekly", forKey: CalendarOpensOn.storageKey)
        #expect(CalendarOpensOn.startMode(d) == .month)
    }
}
