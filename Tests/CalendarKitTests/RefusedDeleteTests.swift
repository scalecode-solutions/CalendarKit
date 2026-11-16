import Foundation
import Testing
@testable import CalendarKit

/// R8: a refused delete reloads the calendar it was in. The local copy is gone
/// by the time the answer comes, so the write itself carries the calendar.
@MainActor
@Suite("Engine: refused deletes", .serialized)
struct RefusedDeleteTests {
    /// Someone else changed the series first: the delete loses, and the series
    /// comes back with its cancelled occurrence still cancelled.
    @Test func aLostDeleteRaceBringsBackTheSeriesWithItsExceptions() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let second = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[1]
        engine.deleteOccurrence(second) // Nov 9 is off
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 4)
        server.externalUpdate(s.id) { $0.title = "Gym (moved)" } // another device, first
        engine.deleteEvent(engine.event(s.id)!)                   // built on the old rev
        await engine.refresh()
        #expect(engine.notices.count == 1)
        let shown = engine.occurrences(from: nov.0, through: nov.1)
        #expect(shown.map(\.title) == Array(repeating: "Gym (moved)", count: 4), "\(shown.map(\.title))")
        #expect(!shown.contains { $0.when.firstDay == CalDate(2026, 11, 9) }) // still cancelled
    }

    /// The pair froze while offline (they unfriended): the delete is refused
    /// and the event, still on the server, comes back.
    @Test func aForbiddenDeleteBringsTheEventBack() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let e = engine.addEvent(to: own, allDay("Dentist", 2026, 11, 12))
        await engine.refresh()
        server.set { s in
            let i = s.calendars.firstIndex { $0.id == own }!
            s.calendars[i].frozen = true
        }
        engine.deleteEvent(engine.event(e.id)!)
        #expect(engine.event(e.id) == nil) // gone at once, optimistically
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(engine.event(e.id) != nil)
    }

    /// A queue stored before deletes carried their calendar still decodes.
    @Test func anOldQueuedDeleteStillDecodes() throws {
        let id = UUID()
        let json = #"{"delete":{"id":"\#(id.uuidString)","baseRev":3}}"#
        let w = try JSONDecoder().decode(PendingWrite.self, from: Data(json.utf8))
        guard case .delete(let got, let base, let cal) = w else { Issue.record("\(w)"); return }
        #expect(got == id && base == 3 && cal == nil)
    }
}
