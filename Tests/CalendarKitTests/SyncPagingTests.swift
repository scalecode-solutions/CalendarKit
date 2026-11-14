import Foundation
import Testing
@testable import CalendarKit

/// R38/R58/R66: the engine keeps syncing while the server says there's more,
/// of a calendar, of calendars it didn't get to, or of alerts.
@MainActor
@Suite("Engine: sync paging", .serialized)
struct SyncPagingTests {
    /// Alerts cut at the server's cap all arrive in one refresh, none skipped.
    @Test func alertsPastTheCapAllArrive() async {
        let (engine, server, _) = makeEngine()
        server.set { s in
            s.maxAlertsPerSync = 2
            for i in 0..<5 {
                s.alertsRev += 1
                let id = UUID()
                s.alerts[id] = CalAlert(eventID: id, minutesBefore: [10 + i], rev: s.alertsRev)
            }
        }
        await engine.refresh()
        #expect(engine.alerts.count == 5)
        #expect(server.get(\.syncs) >= 3)
    }

    /// Many shared calendars and a small budget per Sync: everything loads.
    @Test func calendarsTheServerDidntGetToStillLoad() async {
        let (engine, server, _) = makeEngine()
        server.set { $0.pageLimit = 1; $0.maxPagesPerSync = 1 }
        for i in 0..<5 {
            let c = server.addCalendar(owner: UUID(), role: .view, name: "friend \(i)")
            _ = server.externalCreate(c, allDay("a\(i)", 2026, 11, 3))
            _ = server.externalCreate(c, allDay("b\(i)", 2026, 11, 4))
        }
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 10)
    }
}
