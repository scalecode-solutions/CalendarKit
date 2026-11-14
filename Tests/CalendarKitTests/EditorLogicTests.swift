import Foundation
import Testing
@testable import CalendarKit

@MainActor @Suite("Editor logic", .serialized)
struct EditorLogicTests {
    /// "All future events" of a 10-session series opened at the 4th shows the 7
    /// left, which is what gets saved (R3, the editor half).
    @Test func followingEditorStartsAtWhatIsLeft() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        var rule = CalRecurrence(.weekly)
        rule.count = 10
        let s = engine.addEvent(to: own, allDay("Course", 2026, 11, 2, repeating: rule))
        await engine.refresh()
        let occ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2027, 1, 31)).filter { $0.seriesID == s.id }
        #expect(occ.count == 10)
        guard let series = engine.event(s.id) else { Issue.record("no series"); return }
        #expect(EventEditorView.remaining(of: series, from: occ[3]) == 7)
        #expect(EventEditorView.remaining(of: series, from: occ[9]) == 1)
        #expect(EventEditorView.remaining(of: series, from: occ[0]) == nil) // the first: the whole series is edited
    }

    /// An open-ended series has no count to adjust.
    @Test func uncountedSeriesHasNoRemaining() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let occ = engine.occurrences(from: CalDate(2026, 11, 1), through: CalDate(2026, 11, 30)).filter { $0.seriesID == s.id }
        guard let series = engine.event(s.id) else { Issue.record("no series"); return }
        #expect(EventEditorView.remaining(of: series, from: occ[2]) == nil)
    }
}
