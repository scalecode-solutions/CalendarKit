import Foundation
import Synchronization
import Testing
@testable import CalendarKit

final class FakeCenter: ReminderCenter, Sendable {
    let state = Mutex<[String: CalReminder]>([:])
    let hostIDs = Mutex<[String]>([])

    func pendingIDs() async -> [String] { state.withLock { Array($0.keys) } + hostIDs.withLock { $0 } }
    func add(_ r: CalReminder) async throws { state.withLock { $0[r.id] = r } }
    func remove(_ ids: [String]) async {
        state.withLock { s in for id in ids { s[id] = nil } }
        hostIDs.withLock { h in h.removeAll { ids.contains($0) } }
    }
    var all: [CalReminder] { state.withLock { $0.values.sorted { $0.fireAt < $1.fireAt } } }
}

private let chicago = TimeZone(identifier: "America/Chicago")!

private func cal() -> CalCalendar {
    CalCalendar(id: UUID(), ownerID: UUID(), name: "", color: .blue, role: .owner, rev: 1,
                grantExpiresAt: nil, visible: true, prefColor: .none)
}

private func event(_ title: String, _ when: CalWhen, calendar: UUID, recurrence: CalRecurrence? = nil,
                   master: UUID? = nil, original: CalOriginalStart? = nil, location: String = "") -> CalEvent {
    CalEvent(id: UUID(), calendarID: calendar,
             fields: CalEventFields(title: title, location: location, when: when, recurrence: recurrence),
             masterID: master, originalStart: original, cancelled: false, createdBy: UUID(), updatedBy: UUID(),
             createdAt: Date(), updatedAt: Date(), rev: 1, deleted: false)
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    CalRecurrenceExpander.wallClock(CalDate(y, m, d), hour: h, minute: min, second: 0, in: chicago)
}

@Suite("Reminders")
struct ReminderTests {
    let c = cal()

    func occ(_ events: [CalEvent], exceptions: [CalEvent] = []) -> [CalOccurrence] {
        OccurrenceBuilder.build(events: events, exceptions: exceptions, calendars: [c.id: c], labels: [:],
                                from: CalDate(2026, 11, 1), through: CalDate(2026, 12, 31), zone: chicago)
    }

    @Test func timedAndAllDayFireTimes() {
        let dentist = event("Dentist", .timed(start: at(2026, 11, 18, 15), end: at(2026, 11, 18, 16), timeZone: "America/Chicago"),
                            calendar: c.id, location: "Main St")
        let bday = event("Bday", .allDay(start: CalDate(2026, 11, 20), end: CalDate(2026, 11, 21)), calendar: c.id)
        let plan = ReminderPlanner.plan(occurrences: occ([dentist, bday]),
                                        alerts: [dentist.id: [60, 1440], bday.id: [900, -540]],
                                        now: at(2026, 11, 1, 0), zone: chicago)
        #expect(plan.map(\.fireAt) == [at(2026, 11, 17, 15), at(2026, 11, 18, 14), at(2026, 11, 19, 9), at(2026, 11, 20, 9)])
        #expect(plan.map(\.title) == ["Dentist", "Dentist", "Bday", "Bday"])
        #expect(plan[0].body.hasSuffix("· Main St"))
        #expect(plan[2].body.hasSuffix("all day"))
        #expect(Set(plan.map(\.id)).count == 4 && plan.allSatisfy { $0.id.hasPrefix(ReminderPlanner.prefix) })
    }

    @Test func seriesAlertsCoverOccurrencesAndExceptionsCanOverride() {
        let gym = event("Gym", .timed(start: at(2026, 11, 2, 18), end: at(2026, 11, 2, 19), timeZone: "America/Chicago"),
                        calendar: c.id, recurrence: CalRecurrence(.weekly, count: 3))
        let moved = event("Gym (late)", .timed(start: at(2026, 11, 9, 20), end: at(2026, 11, 9, 21), timeZone: "America/Chicago"),
                          calendar: c.id, master: gym.id, original: .instant(at(2026, 11, 9, 18)))
        let plan = ReminderPlanner.plan(occurrences: occ([gym], exceptions: [moved]), alerts: [gym.id: [30]],
                                        now: at(2026, 11, 1, 0), zone: chicago)
        #expect(plan.map(\.fireAt) == [at(2026, 11, 2, 17, 30), at(2026, 11, 9, 19, 30), at(2026, 11, 16, 17, 30)])
        let own = ReminderPlanner.plan(occurrences: occ([gym], exceptions: [moved]), alerts: [gym.id: [30], moved.id: [5]],
                                       now: at(2026, 11, 1, 0), zone: chicago)
        #expect(own.map(\.fireAt)[1] == at(2026, 11, 9, 19, 55))
    }

    @Test func pastRemindersAreSkippedAndTheBudgetKeepsTheSoonest() {
        let daily = event("Pills", .timed(start: at(2026, 11, 1, 8), end: at(2026, 11, 1, 8), timeZone: "America/Chicago"),
                          calendar: c.id, recurrence: CalRecurrence(.daily))
        let plan = ReminderPlanner.plan(occurrences: occ([daily]), alerts: [daily.id: [0, 10]],
                                        now: at(2026, 11, 3, 7, 55), zone: chicago, budget: 5)
        #expect(plan.count == 5)
        #expect(plan.first?.fireAt == at(2026, 11, 3, 8)) // 7:50 already passed
        #expect(plan.map(\.fireAt) == plan.map(\.fireAt).sorted())
        #expect(ReminderPlanner.plan(occurrences: occ([daily]), alerts: [daily.id: []], now: at(2026, 11, 1, 0), zone: chicago).isEmpty)
        #expect(ReminderPlanner.plan(occurrences: occ([daily]), alerts: [daily.id: [0]], now: at(2026, 11, 1, 0), zone: chicago, budget: 0).isEmpty)
    }

    /// R20 ("use my defaults"): events someone else added remind with
    /// the person's defaults; their own don't (they got defaults when made),
    /// and anything set explicitly — including none — wins.
    @Test func partnerEventsUseMyDefaults() {
        let me = UUID(), partner = UUID()
        func ev(_ title: String, by who: UUID) -> CalEvent {
            var e = event(title, .timed(start: at(2026, 11, 18, 15), end: at(2026, 11, 18, 16), timeZone: "America/Chicago"), calendar: c.id)
            e.createdBy = who
            return e
        }
        let theirs = ev("Theirs", by: partner), mine = ev("Mine", by: me), muted = ev("Muted", by: partner)
        let d = CalAlertDefaults(timed: [30], allDay: [900])
        let plan = ReminderPlanner.plan(occurrences: occ([theirs, mine, muted]), alerts: [muted.id: []],
                                        now: at(2026, 11, 1, 0), zone: chicago, me: me, defaults: d)
        #expect(plan.map(\.title) == ["Theirs"])
        #expect(plan.first?.fireAt == at(2026, 11, 18, 14, 30))
    }

    @Test func schedulerDiffsAndLeavesTheHostsAlone() async {
        let center = FakeCenter()
        center.hostIDs.withLock { $0 = ["host.message.1", "host.other"] }
        let s = ReminderScheduler(center: center)
        let a = CalReminder(id: "calendarkit.a.10", fireAt: Date().addingTimeInterval(600), title: "A", body: "")
        let b = CalReminder(id: "calendarkit.b.10", fireAt: Date().addingTimeInterval(900), title: "B", body: "")
        var r = await s.apply([a, b])
        #expect(r == (2, 0))
        r = await s.apply([b])
        #expect(r == (0, 1))
        #expect(center.all.map(\.id) == ["calendarkit.b.10"])
        await s.clear()
        #expect(center.all.isEmpty)
        #expect(center.hostIDs.withLock { $0 } == ["host.message.1", "host.other"])
    }
}

@MainActor
@Suite("Engine reminders", .serialized)
struct EngineReminderTests {
    @Test func newEventsGetDefaultsAndSyncReplans() async {
        let me = UUID()
        let server = FakeServer(me: me)
        let own = server.addCalendar(owner: me, role: .owner)
        let center = FakeCenter()
        let engine = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me, tokenProvider: { "t" }),
                                    transport: server, reminderCenter: center)
        engine.storeInMemory = true
        await engine.refresh()
        engine.setAlertDefaults(CalAlertDefaults(timed: [15], allDay: [900]))
        let soon = Date().addingTimeInterval(3 * 3600)
        let e = engine.addEvent(to: own, CalEventFields(title: "Call", when: .timed(start: soon, end: soon.addingTimeInterval(1800),
                                                                                    timeZone: TimeZone.current.identifier)))
        let quiet = engine.addEvent(to: own, CalEventFields(title: "No buzz", when: .timed(start: soon, end: soon,
                                                                                           timeZone: TimeZone.current.identifier)), alerts: [])
        await engine.refresh()
        await engine.replanTask?.value
        #expect(engine.alerts[e.id] == [15])
        #expect(engine.alerts[quiet.id] == nil)
        #expect(server.get { $0.alerts[e.id]?.minutesBefore } == [15])
        #expect(center.all.map(\.title) == ["Call"])
        // Deleting it removes its reminder on the next plan.
        engine.deleteEvent(e)
        await engine.refresh()
        await engine.replanTask?.value
        #expect(center.all.isEmpty)
    }

    /// Regression: a notification center that never answers (a permission
    /// prompt still up) once held every sync open.
    @Test(.timeLimit(.minutes(1))) func aStuckNotificationCenterNeverBlocksSync() async {
        let me = UUID()
        let server = FakeServer(me: me)
        let own = server.addCalendar(owner: me, role: .owner)
        let engine = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me, tokenProvider: { "t" }),
                                    transport: server, reminderCenter: StuckCenter())
        engine.storeInMemory = true
        await engine.refresh()
        let e = engine.addEvent(to: own, allDay("x", 2026, 11, 3), alerts: [900])
        await engine.refresh() // must come back although the center never does
        #expect(server.get { $0.events[e.id] } != nil)
        #expect(engine.loadState == .loaded)
    }
}

/// A notification center that never answers.
final class StuckCenter: ReminderCenter, Sendable {
    func pendingIDs() async -> [String] {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } // never resumes
        return []
    }
    func add(_ r: CalReminder) async throws {}
    func remove(_ ids: [String]) async {}
}
