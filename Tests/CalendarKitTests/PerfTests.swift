import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-12: what a few years of two people's calendars cost on the main
/// actor. Prints timings (Debug build, simulator: compare runs, not absolutes)
/// and guards the shape: work that shouldn't happen doesn't.
@MainActor
@Suite("Performance", .serialized)
struct PerfTests {
    static let chicago = TimeZone(identifier: "America/Chicago")!

    /// Two calendars, ~3,000 single events over three years, five daily timed
    /// series and three weekly ones started three years ago, with alerts.
    static func bigEngine() async -> (CalendarEngine, FakeServer, UUID) {
        let (engine, server, own) = makeEngine()
        let other = server.addCalendar(owner: UUID(), role: .edit, name: "partner")
        server.set { $0.pageLimit = 500 }
        var d = CalDate(2023, 11, 1)
        var i = 0
        while d < CalDate(2026, 12, 31) {
            _ = server.externalCreate(i % 2 == 0 ? own : other, allDay("e\(i)", d.year, d.month, d.day))
            _ = server.externalCreate(i % 2 == 0 ? other : own, allDay("f\(i)", d.year, d.month, d.day))
            i += 1
            d = d.adding(days: 1)
        }
        for k in 0..<5 {
            let s = CalRecurrenceExpander.wallClock(CalDate(2023, 11, 1), hour: 7 + k, minute: 0, second: 0, in: chicago)
            let f = CalEventFields(title: "daily \(k)", when: .timed(start: s, end: s.addingTimeInterval(1800), timeZone: chicago.identifier),
                                   recurrence: CalRecurrence(.daily))
            let e = server.externalCreate(own, f)
            server.set { s in s.alertsRev += 1; s.alerts[e.id] = CalAlert(eventID: e.id, minutesBefore: [10, 60], rev: s.alertsRev) }
        }
        for k in 0..<3 {
            _ = server.externalCreate(other, allDay("weekly \(k)", 2023, 11, 6 + k, repeating: CalRecurrence(.weekly)))
        }
        await engine.refresh()
        return (engine, server, own)
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }

    @Test func baseline() async {
        let clock = ContinuousClock()
        var (engine, server, own): (CalendarEngine, FakeServer, UUID) = (makeEngine().0, makeEngine().1, UUID())
        let load = await clock.measure { (engine, server, own) = await Self.bigEngine() }
        let month = clock.measure { _ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2026, 12, 6)) }
        let monthAgain = clock.measure { _ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2026, 12, 6)) }
        let agenda = clock.measure { _ = engine.occurrences(from: CalDate(2026, 11, 14), through: CalDate(2028, 11, 14)) }
        let replan = await clock.measure { await engine.replanReminders() }
        let target = engine.occurrences(from: CalDate(2026, 11, 20), through: CalDate(2026, 11, 20)).first { $0.seriesID == nil }!
        var f = target.event.fields
        f.title = "edited"
        let edit = clock.measure { engine.updateEvent(target.event, f) }
        let syncAfterEdit = await clock.measure { await engine.refresh() }
        let count = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2026, 12, 6)).count
        print(String(format: "PERF load %.0f ms · month %.1f ms (again %.1f) · agenda 2y %.0f ms · replan %.0f ms · edit %.1f ms · sync after edit %.0f ms · month occurrences %d",
                     Self.ms(load), Self.ms(month), Self.ms(monthAgain), Self.ms(agenda), Self.ms(replan), Self.ms(edit), Self.ms(syncAfterEdit), count))
        _ = (server, own)
        #expect(count > 0)
    }

    /// A sync that brings nothing new doesn't make the views rebuild (R22).
    @Test func aQuietSyncKeepsTheRevision() async {
        let (engine, server, own) = makeEngine()
        _ = server.externalCreate(own, allDay("x", 2026, 11, 5))
        await engine.refresh()
        let r = engine.revision
        await engine.refresh()
        await engine.refresh()
        #expect(engine.revision == r)
        _ = server.externalCreate(own, allDay("y", 2026, 11, 6))
        await engine.refresh()
        #expect(engine.revision > r)
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 2) // and the cache saw it
    }
}
