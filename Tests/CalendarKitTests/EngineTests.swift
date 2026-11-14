import Foundation
import Synchronization
import Testing
@testable import CalendarKit

/// An in-memory mvCalendar: revs per calendar, tombstones, base_rev conflicts,
/// exceptions, splits. Switch it offline or make the next write fail to drive
/// the engine's queue. State is behind a Mutex (transport calls are nonisolated).
final class FakeServer: CalendarTransport, Sendable {
    struct State {
        var me: UUID
        var calendars: [CalCalendar] = []
        var events: [UUID: CalEvent] = [:]
        var labels: [UUID: (CalLabel, deleted: Bool)] = [:]
        var alerts: [UUID: CalAlert] = [:]
        var alertsRev: Int64 = 0
        var defaults = CalAlertDefaults()
        var offline = false
        var failNextWrite: CalTransportError?
        var writes: [String] = []
        var syncs = 0
        /// Simulated network latency per call.
        var delay: Duration = .zero
        /// Rows per Sync page per calendar (the server's SYNC_PAGE_LIMIT).
        var pageLimit = 500
        /// Per calendar: the newest purged tombstone's rev (the server's purged_rev).
        var purgedRev: [UUID: Int64] = [:]
        /// Apply the next write, then lose its answer (a dropped connection).
        var loseNextAnswer = false
        /// Fail every write with this until cleared (a broken server).
        var failAllWrites: CalTransportError?
        var failedWrites = 0
    }

    /// The answer to a write that was applied: lost if loseNextAnswer is set.
    private func answer<T>(_ s: inout State, _ v: T) throws -> T {
        if s.loseNextAnswer { s.loseNextAnswer = false; throw CalTransportError.unavailable("answer lost") }
        return v
    }
    let state: Mutex<State>

    init(me: UUID) { state = Mutex(State(me: me)) }

    func set(_ f: (inout State) -> Void) { state.withLock { f(&$0) } }
    func get<T>(_ f: (State) -> T) -> T { state.withLock { f($0) } }

    /// Give `me` their own calendar (and optionally one shared with them).
    @discardableResult
    func addCalendar(owner: UUID, role: CalRole, name: String = "") -> UUID {
        let c = CalCalendar(id: UUID(), ownerID: owner, name: name, color: .blue, role: role, rev: 0,
                            grantExpiresAt: nil, visible: true, prefColor: .none)
        set { $0.calendars.append(c) }
        return c.id
    }

    private func bump(_ s: inout State, _ cal: UUID) -> Int64 {
        let i = s.calendars.firstIndex { $0.id == cal }!
        s.calendars[i].rev += 1
        return s.calendars[i].rev
    }

    private func gate(_ s: inout State, _ name: String) throws {
        if s.offline { throw CalTransportError.unavailable("offline") }
        if let e = s.failAllWrites { s.failedWrites += 1; throw e }
        if let e = s.failNextWrite { s.failNextWrite = nil; throw e }
        s.writes.append(name)
    }

    private func writable(_ s: State, _ cal: UUID) throws {
        guard let c = s.calendars.first(where: { $0.id == cal }) else { throw CalTransportError.notFound }
        guard c.role.canWrite else { throw CalTransportError.forbidden("view only") }
    }

    /// Someone else edits an event on the server.
    func externalUpdate(_ id: UUID, _ change: (inout CalEventFields) -> Void) {
        set { s in
            var e = s.events[id]!
            change(&e.fields)
            e.rev = bump(&s, e.calendarID)
            s.events[id] = e
        }
    }

    /// Purge every tombstone (as the server's daily purge does past retention).
    func purge() {
        set { s in
            for (id, e) in s.events where e.deleted {
                s.purgedRev[e.calendarID] = max(s.purgedRev[e.calendarID] ?? 0, e.rev)
                s.events[id] = nil
            }
        }
    }

    func externalDelete(_ id: UUID) {
        set { s in
            guard var e = s.events[id] else { return }
            e.deleted = true
            e.rev = bump(&s, e.calendarID)
            s.events[id] = e
        }
    }

    /// Delete a label on the server (as another device of the owner would).
    func externalDeleteLabel(_ id: UUID) async throws { try await deleteLabel(id: id) }

    func externalCreate(_ cal: UUID, _ fields: CalEventFields) -> CalEvent {
        state.withLock { s in
            let e = CalEvent(id: UUID(), calendarID: cal, fields: fields, masterID: nil, originalStart: nil, cancelled: false,
                             createdBy: UUID(), updatedBy: UUID(), createdAt: Date(), updatedAt: Date(), rev: bump(&s, cal), deleted: false)
            s.events[e.id] = e
            return e
        }
    }

    // MARK: CalendarTransport

    private func latency() async {
        let d = get { $0.delay }
        if d > .zero { try? await Task.sleep(for: d) }
    }

    func sync(cursors: [UUID: CalCursor], alertsCursor: Int64) async throws -> CalSyncPage {
        await latency()
        return try state.withLock { s in
            if s.offline { throw CalTransportError.unavailable("offline") }
            s.syncs += 1
            // The real server's paging and reload rules (internal/store/sync.go):
            // pages never split one rev; a load cursor is judged by load_from.
            let deltas: [CalDelta] = s.calendars.compactMap { c in
                var cur = max(0, cursors[c.id]?.rev ?? 0)
                var loadFrom = cur == 0 ? 0 : max(0, cursors[c.id]?.loadFrom ?? 0)
                let purged = s.purgedRev[c.id] ?? 0
                let reset = loadFrom > 0 ? loadFrom < purged : (cur > 0 && cur < purged)
                if reset { cur = 0; loadFrom = 0 }
                guard cur < c.rev || reset else { return nil }
                let live = cur == 0
                let evs = s.events.values.filter { $0.calendarID == c.id && $0.rev > cur && (!live || !$0.deleted) }
                let ls = s.labels.values.filter { $0.0.calendarID == c.id && $0.0.rev > cur && (!live || !$0.deleted) }
                let revs = (evs.map(\.rev) + ls.map(\.0.rev)).sorted()
                var hi = c.rev
                var more = false
                if revs.count > s.pageLimit {
                    let boundary = revs[s.pageLimit]
                    hi = boundary - 1 > cur ? boundary - 1 : boundary
                    more = hi < c.rev
                }
                let pageEvents = evs.filter { $0.rev <= hi }.sorted { $0.rev < $1.rev }
                let pageLabels = ls.filter { $0.0.rev <= hi }
                return CalDelta(calendarID: c.id, events: pageEvents,
                                labels: pageLabels.filter { !$0.deleted }.map(\.0), deletedLabelIDs: pageLabels.filter(\.deleted).map(\.0.id),
                                rev: hi, hasMore: more, reload: reset,
                                loadFrom: more ? (cur == 0 ? c.rev : loadFrom) : 0)
            }
            let gone = cursors.keys.filter { id in !s.calendars.contains { $0.id == id } }
            return CalSyncPage(calendars: s.calendars, deltas: deltas, gone: gone,
                               alerts: s.alerts.values.filter { $0.rev > alertsCursor }, alertsRev: s.alertsRev,
                               alertDefaults: s.defaults)
        }
    }

    func createEvent(id: UUID, calendarID: UUID, fields: CalEventFields) async throws -> CalEvent {
        await latency()
        return try state.withLock { s in
            try gate(&s, "create \(fields.title)")
            try writable(s, calendarID)
            if let e = s.events[id] { return e }
            let e = CalEvent(id: id, calendarID: calendarID, fields: fields, masterID: nil, originalStart: nil, cancelled: false,
                             createdBy: s.me, updatedBy: s.me, createdAt: Date(), updatedAt: Date(), rev: bump(&s, calendarID), deleted: false)
            s.events[id] = e
            return e
        }
    }

    func createException(id: UUID, calendarID: UUID, masterID: UUID, originalStart: CalOriginalStart,
                         fields: CalEventFields?, cancelled: Bool) async throws -> CalEvent {
        try state.withLock { s in
            try gate(&s, cancelled ? "cancel" : "exception")
            try writable(s, calendarID)
            guard let m = s.events[masterID], !m.deleted else { throw CalTransportError.invalid("no such series") }
            let rev = bump(&s, calendarID)
            if let old = s.events.values.first(where: { $0.masterID == masterID && $0.originalStart == originalStart && !$0.deleted }) {
                guard cancelled else { throw CalTransportError.exists("already changed") }
                s.events[old.id]!.deleted = true
                s.events[old.id]!.rev = rev
            }
            let e = CalEvent(id: id, calendarID: calendarID, fields: cancelled ? m.fields : fields!, masterID: masterID,
                             originalStart: originalStart, cancelled: cancelled, createdBy: s.me, updatedBy: s.me,
                             createdAt: Date(), updatedAt: Date(), rev: rev, deleted: false)
            s.events[id] = e
            return e
        }
    }

    func updateEvent(id: UUID, baseRev: Int64, fields: CalEventFields) async throws -> CalEvent {
        try state.withLock { s in
            try gate(&s, "update \(fields.title)")
            guard var e = s.events[id], !e.deleted else { throw CalTransportError.notFound }
            try writable(s, e.calendarID)
            guard e.rev == baseRev else { throw CalTransportError.conflict(current: e) }
            e.fields = fields
            e.cancelled = false
            e.updatedBy = s.me
            e.rev = bump(&s, e.calendarID)
            s.events[id] = e
            return try answer(&s, e)
        }
    }

    func deleteEvent(id: UUID, baseRev: Int64) async throws -> Int64 {
        try state.withLock { s in
            try gate(&s, "delete")
            guard let e = s.events[id], !e.deleted else { throw CalTransportError.notFound }
            try writable(s, e.calendarID)
            guard e.rev == baseRev else { throw CalTransportError.conflict(current: e) }
            let rev = bump(&s, e.calendarID)
            for (k, v) in s.events where v.id == id || v.masterID == id {
                s.events[k]!.deleted = true
                s.events[k]!.rev = rev
            }
            return try answer(&s, rev)
        }
    }

    func splitSeries(masterID: UUID, baseRev: Int64, at originalStart: CalOriginalStart, newID: UUID,
                     fields: CalEventFields) async throws -> (old: CalEvent, new: CalEvent) {
        try state.withLock { s in
            try gate(&s, "split")
            guard var m = s.events[masterID] else { throw CalTransportError.notFound }
            // Idempotent by the new id, as the real server.
            if let prev = s.events[newID], prev.calendarID == m.calendarID, prev.masterID == nil { return (m, prev) }
            guard m.rev == baseRev else { throw CalTransportError.conflict(current: m) }
            let rev = bump(&s, m.calendarID)
            guard case .date(let d) = originalStart else { throw CalTransportError.invalid("fake: dates only") }
            m.fields.recurrence?.count = nil
            m.fields.recurrence?.until = d.adding(days: -1)
            m.rev = rev
            s.events[masterID] = m
            let n = CalEvent(id: newID, calendarID: m.calendarID, fields: fields, masterID: nil, originalStart: nil, cancelled: false,
                             createdBy: s.me, updatedBy: s.me, createdAt: Date(), updatedAt: Date(), rev: rev, deleted: false)
            s.events[newID] = n
            // As the server: the reminders follow when all-day/timed matches.
            if fields.when.isAllDay == m.fields.when.isAllDay, let a = s.alerts[masterID] {
                s.alertsRev += 1
                s.alerts[newID] = CalAlert(eventID: newID, minutesBefore: a.minutesBefore, rev: s.alertsRev)
            }
            return try answer(&s, (m, n))
        }
    }

    func setAlerts(eventID: UUID, minutesBefore: [Int]) async throws -> CalAlert {
        try state.withLock { s in
            try gate(&s, "alerts")
            s.alertsRev += 1
            let a = CalAlert(eventID: eventID, minutesBefore: minutesBefore, rev: s.alertsRev)
            s.alerts[eventID] = a
            return a
        }
    }

    func setAlertDefaults(_ d: CalAlertDefaults) async throws -> CalAlertDefaults {
        try state.withLock { s in try gate(&s, "defaults"); s.defaults = d; return d }
    }

    func setCalendarPref(calendarID: UUID, visible: Bool, color: CalColor) async throws {
        try state.withLock { s in
            try gate(&s, "pref")
            guard let i = s.calendars.firstIndex(where: { $0.id == calendarID }) else { throw CalTransportError.notFound }
            s.calendars[i].visible = visible
            s.calendars[i].prefColor = color
        }
    }

    func listContacts() async throws -> [CalContact] { [] }

    func updateCalendar(name: String?, color: CalColor?) async throws -> CalCalendar {
        try state.withLock { s in
            try gate(&s, "rename")
            let i = s.calendars.firstIndex { $0.role == .owner }!
            if let name { s.calendars[i].name = name }
            if let color { s.calendars[i].color = color }
            return s.calendars[i]
        }
    }

    func saveLabel(id: UUID, name: String, color: CalColor) async throws -> CalLabel {
        try state.withLock { s in
            try gate(&s, "label")
            let cal = s.calendars.first { $0.role == .owner }!.id
            let l = CalLabel(id: id, calendarID: cal, name: name, color: color, rev: bump(&s, cal))
            s.labels[id] = (l, false)
            return l
        }
    }

    func deleteLabel(id: UUID) async throws {
        try state.withLock { s in
            try gate(&s, "unlabel")
            guard var l = s.labels[id]?.0 else { throw CalTransportError.notFound }
            l.rev = bump(&s, l.calendarID)
            s.labels[id] = (l, true)
            // As the server: events with the label lose it, in the same rev.
            for (k, e) in s.events where e.fields.labelID == id && !e.deleted {
                s.events[k]!.fields.labelID = nil
                s.events[k]!.rev = l.rev
            }
        }
    }

    func createGrant(granteeID: UUID, role: CalRole, expiresAt: Date?, label: String) async throws -> CalGrant {
        CalGrant(id: UUID(), granteeID: granteeID, role: role, createdAt: Date(), expiresAt: expiresAt, label: label)
    }
    func revokeGrant(id: UUID) async throws {}
    func listGrants() async throws -> [CalGrant] { [] }
    func listActivity(cursor: String?, limit: Int) async throws -> (rows: [CalActivity], next: String?) { ([], nil) }
}

// MARK: - engine tests

@MainActor
func makeEngine() -> (CalendarEngine, FakeServer, own: UUID) {
    let me = UUID()
    let server = FakeServer(me: me)
    let own = server.addCalendar(owner: me, role: .owner)
    let engine = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me,
                                                       tokenProvider: { "t" }), transport: server, reminderCenter: FakeCenter())
    engine.storeInMemory = true
    return (engine, server, own)
}

func allDay(_ title: String, _ y: Int, _ m: Int, _ d: Int, repeating r: CalRecurrence? = nil) -> CalEventFields {
    CalEventFields(title: title, when: .allDay(start: CalDate(y, m, d), end: CalDate(y, m, d).adding(days: 1)), recurrence: r)
}

let nov = (CalDate(2026, 11, 1), CalDate(2026, 11, 30))

@MainActor
@Suite("Engine", .serialized)
struct EngineTests {
    @Test func firstSyncLoadsCalendarsAndEvents() async {
        let (engine, server, own) = makeEngine()
        _ = server.externalCreate(own, allDay("Work", 2026, 11, 20))
        await engine.refresh()
        #expect(engine.loadState == .loaded)
        #expect(engine.ownCalendar?.id == own)
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Work"])
    }

    @Test func offlineWritesShowAtOnceAndLandLater() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        let e = engine.addEvent(to: own, allDay("Dentist", 2026, 11, 10))
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Dentist"])
        await engine.refresh()
        #expect(engine.pendingCount == 1)
        #expect(engine.lastError == "Can't reach the calendar right now")
        // Edit it while still offline: merged into the waiting create, one write.
        var f = e.fields
        f.title = "Dentist 3pm"
        engine.updateEvent(e, f)
        #expect(engine.pendingCount == 1)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.pendingCount == 0)
        #expect(server.get { $0.writes } == ["create Dentist 3pm"])
        #expect(server.get { $0.events[e.id]?.fields.title } == "Dentist 3pm")
        #expect(engine.event(e.id)?.rev == 1)
        #expect(engine.lastError == nil)
    }

    @Test func createThenDeleteOfflineSendsNothing() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        let e = engine.addEvent(to: own, allDay("oops", 2026, 11, 3))
        engine.deleteEvent(e)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(server.get { $0.writes }.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.occurrences(from: nov.0, through: nov.1).isEmpty)
    }

    @Test func queuedWritesKeepTheirOrder() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        let a = engine.addEvent(to: own, allDay("A", 2026, 11, 1))
        _ = engine.addEvent(to: own, allDay("B", 2026, 11, 2))
        engine.setAlerts(for: a, minutesBefore: [900])
        engine.setAlerts(for: a, minutesBefore: [60]) // merged: last wins
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(server.get { $0.writes } == ["create A", "create B", "alerts"])
        #expect(server.get { $0.alerts[a.id]?.minutesBefore } == [60])
    }

    @Test func aLostRaceIsANoticeAndTheServerWins() async {
        let (engine, server, own) = makeEngine()
        let e = server.externalCreate(own, allDay("Dentist", 2026, 11, 10))
        await engine.refresh()
        // The partner moves it on the server; this device, still on the old rev, edits it.
        server.externalUpdate(e.id) { $0.title = "Dentist (moved)" }
        var f = e.fields
        f.title = "Dentist (mine)"
        engine.updateEvent(engine.event(e.id)!, f)
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(engine.notices.first?.message.contains("Someone else changed “Dentist (mine)”") == true)
        #expect(engine.event(e.id)?.fields.title == "Dentist (moved)")
        #expect(engine.pendingCount == 0)
        engine.dismissNotice(engine.notices[0])
        #expect(engine.notices.isEmpty)
    }

    @Test func aRefusedWriteIsRevertedFromTheServer() async {
        let (engine, server, _) = makeEngine()
        let me = engine.config.currentUserID
        let shared = server.addCalendar(owner: UUID(), role: .view, name: "Theirs")
        _ = me
        await engine.refresh()
        engine.addEvent(to: shared, allDay("sneaky", 2026, 11, 5))
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 1)
        await engine.refresh()
        #expect(engine.notices.first?.message.contains("view this calendar but not change it") == true)
        #expect(engine.occurrences(from: nov.0, through: nov.1).isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(!engine.writableCalendars.contains { $0.id == shared })
    }

    @Test func aSyncNeverOverwritesALocalEditStillWaiting() async {
        let (engine, server, own) = makeEngine()
        let e = server.externalCreate(own, allDay("Dentist", 2026, 11, 10))
        await engine.refresh()
        var f = e.fields
        f.title = "Dentist (mine)"
        engine.updateEvent(engine.event(e.id)!, f)
        // The write is throttled (retryable) but syncs still work; the partner's
        // change arrives meanwhile.
        server.set { $0.failNextWrite = .slowDown }
        server.externalUpdate(e.id) { $0.notes = "theirs" }
        await engine.refresh()
        #expect(engine.pendingCount == 1)
        #expect(engine.event(e.id)?.fields.title == "Dentist (mine)")
        // Next round: the write goes out, loses the race, and the server wins.
        await engine.refresh()
        #expect(engine.event(e.id)?.fields.notes == "theirs")
        #expect(engine.notices.count == 1)
    }

    @Test func occurrencesHonourExceptionsLabelsAndHiddenCalendars() async {
        let (engine, server, own) = makeEngine()
        let other = server.addCalendar(owner: UUID(), role: .edit, name: "Partner")
        await engine.refresh()
        let label = engine.saveLabel(name: "Work", color: .orange)!
        var f = allDay("Shift", 2026, 11, 2, repeating: CalRecurrence(.weekly, count: 4))
        f.labelID = label.id
        let series = engine.addEvent(to: own, f)
        engine.addEvent(to: other, allDay("Their thing", 2026, 11, 4))
        await engine.refresh()
        var occ = engine.occurrences(from: nov.0, through: nov.1)
        #expect(occ.filter { $0.title == "Shift" }.map(\.when.firstDay) ==
                [CalDate(2026, 11, 2), CalDate(2026, 11, 9), CalDate(2026, 11, 16), CalDate(2026, 11, 23)])
        #expect(occ.first { $0.title == "Shift" }?.color == .orange) // label color
        #expect(occ.first { $0.title == "Their thing" }?.color == .blue) // calendar color
        // Cancel the 2nd, move the 3rd.
        let second = occ.filter { $0.seriesID == series.id }[1]
        let third = occ.filter { $0.seriesID == series.id }[2]
        engine.deleteOccurrence(second)
        var moved = third.event.fields
        moved.when = .allDay(start: CalDate(2026, 11, 18), end: CalDate(2026, 11, 19))
        moved.title = "Shift (swapped)"
        engine.updateOccurrence(third, moved)
        await engine.refresh()
        occ = engine.occurrences(from: nov.0, through: nov.1)
        #expect(occ.filter { $0.seriesID == series.id }.map(\.title) == ["Shift", "Shift (swapped)", "Shift"])
        #expect(server.get { $0.writes }.suffix(2) == ["cancel", "exception"])
        // Hide the partner's calendar: gone from the view, still there underneath.
        engine.setVisible(engine.calendar(other)!, false)
        #expect(!engine.occurrences(from: nov.0, through: nov.1).contains { $0.title == "Their thing" })
        #expect(engine.occurrences(from: nov.0, through: nov.1, includeHidden: true).contains { $0.title == "Their thing" })
        await engine.refresh()
        #expect(server.get { $0.calendars.first { $0.id == other }?.visible } == false)
    }

    @Test func thisAndFollowing() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var f = third.event.fields
        f.title = "Gym (new place)"
        f.when = .allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 17))
        engine.updateFollowing(third, f)
        let local = engine.occurrences(from: nov.0, through: nov.1).map(\.title)
        #expect(local == ["Gym", "Gym", "Gym (new place)", "Gym (new place)", "Gym (new place)"])
        await engine.refresh()
        #expect(server.get { $0.writes }.last == "split")
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == local)
        #expect(engine.event(s.id)?.fields.recurrence?.until == CalDate(2026, 11, 15))
    }

    @Test func goneCalendarsDisappearWithTheirEvents() async {
        let (engine, server, _) = makeEngine()
        let other = server.addCalendar(owner: UUID(), role: .view)
        _ = server.externalCreate(other, allDay("theirs", 2026, 11, 7))
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 1)
        server.set { $0.calendars.removeAll { $0.id == other } } // revoked
        await engine.refresh()
        #expect(engine.calendar(other) == nil)
        #expect(engine.occurrences(from: nov.0, through: nov.1, includeHidden: true).isEmpty)
    }

    /// Regression: a write starts a background refresh; awaiting refresh() must
    /// not return until that write has been tried (it once returned at once).
    @Test func awaitingRefreshCoversAWriteAlreadyInFlight() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.delay = .milliseconds(80) }
        let e = engine.addEvent(to: own, allDay("slow network", 2026, 11, 4))
        // Let the write's own background refresh get going first (the live
        // failure: a refresh was already in flight when the caller awaited).
        for _ in 0..<1000 where !engine.isSyncing { await Task.yield() }
        #expect(engine.isSyncing)
        await engine.refresh()
        #expect(server.get { $0.events[e.id] } != nil)
        #expect(engine.pendingCount == 0)
    }

    /// Regression: concurrent refreshes once spun forever on the main actor.
    @Test(.timeLimit(.minutes(1))) func concurrentRefreshesAllFinish() async {
        let (engine, server, own) = makeEngine()
        server.set { $0.delay = .milliseconds(20) }
        var tasks: [Task<Void, Never>] = []
        for i in 0..<8 {
            tasks.append(Task { @MainActor in
                if i % 2 == 0 { engine.addEvent(to: own, allDay("e\(i)", 2026, 11, 1 + i)) }
                await engine.refresh()
            })
        }
        for t in tasks { await t.value }
        #expect(engine.pendingCount == 0)
        #expect(server.get { $0.events.count } == 4)
    }

    @Test func wipeForgetsEverything() async {
        let (engine, server, own) = makeEngine()
        _ = server.externalCreate(own, allDay("x", 2026, 11, 1))
        await engine.refresh()
        server.set { $0.offline = true }
        engine.addEvent(to: own, allDay("queued", 2026, 11, 2))
        engine.wipeLocalStore()
        #expect(engine.calendars.isEmpty && engine.pendingCount == 0)
        #expect(engine.occurrences(from: nov.0, through: nov.1).isEmpty)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(server.get { $0.writes }.isEmpty) // the queued write died with the wipe
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["x"])
    }
}

@MainActor
@Suite("Engine: delete following", .serialized)
struct DeleteFollowingTests {
    @Test func keepsEarlierOccurrencesAndTheirChanges() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        var occ = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }
        var early = occ[1].event.fields
        early.title = "Class (room 4)"
        engine.updateOccurrence(occ[1], early) // an earlier change that must survive
        await engine.refresh()
        occ = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }
        engine.deleteFollowing(occ[3])
        let local = engine.occurrences(from: nov.0, through: nov.1).map(\.title)
        #expect(local == ["Class", "Class (room 4)", "Class"])
        await engine.refresh()
        #expect(server.get { $0.writes }.suffix(2) == ["split", "delete"])
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == local)
        #expect(engine.pendingCount == 0 && engine.notices.isEmpty)
    }
}

@MainActor
@Suite("Engine: paged loads (R4)", .serialized)
struct PagedLoadTests {
    @Test func aBigPurgedCalendarLoadsCompletely() async {
        let (engine, server, own) = makeEngine()
        var made: [CalEvent] = []
        for i in 0..<14 { made.append(server.externalCreate(own, allDay("e\(i)", 2026, 11, 1 + i))) }
        server.externalDelete(made[13].id)
        server.purge()
        server.set { $0.pageLimit = 3 }
        await engine.refresh()
        #expect(engine.loadState == .loaded)
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 13)
        #expect(server.get { $0.syncs } >= 4 && server.get { $0.syncs } < 20) // paged, and it ended
    }

    @Test func aPurgeOfRowsWeHoldMidLoadReloadsInsteadOfKeepingAGhost() async {
        let (engine, server, own) = makeEngine()
        var made: [CalEvent] = []
        for i in 0..<9 { made.append(server.externalCreate(own, allDay("e\(i)", 2026, 11, 1 + i))) }
        server.set { $0.pageLimit = 3; $0.delay = .milliseconds(30) }
        // Mid-load (after page 1 lands), delete a row from page 1 and purge it.
        let refresh = Task { await engine.refresh() }
        for _ in 0..<500 where server.get({ $0.syncs }) < 1 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
        server.externalDelete(made[0].id)
        server.purge()
        await refresh.value
        await engine.refresh()
        let titles = Set(engine.occurrences(from: nov.0, through: nov.1).map(\.title))
        #expect(!titles.contains("e0"), "the deleted row survived as a ghost")
        #expect(titles.count == 8)
    }
}

/// Review R0/R1/R5/R11/R12/R17: writes made while another write about the
/// same event is on the wire, and chains of queued writes.
@MainActor
@Suite("Engine: write chains", .serialized)
struct WriteChainTests {
    /// Start the background push of a write and wait until it's on the wire.
    func waitUntilSending(_ engine: CalendarEngine) async {
        for _ in 0..<2000 where !engine.isSyncing { await Task.yield() }
    }

    @Test func anEditWhileTheCreateIsOnTheWireIsKept() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.delay = .milliseconds(150) }
        let e = engine.addEvent(to: own, allDay("Dentist", 2026, 11, 10))
        await waitUntilSending(engine)
        var f = e.fields
        f.title = "Dentist 3pm"
        engine.updateEvent(engine.event(e.id)!, f) // while the create is in flight
        #expect(engine.event(e.id)?.fields.title == "Dentist 3pm")
        server.set { $0.delay = .zero }
        await engine.refresh()
        await engine.refresh()
        #expect(server.get { $0.events[e.id]?.fields.title } == "Dentist 3pm")
        #expect(engine.event(e.id)?.fields.title == "Dentist 3pm")
        #expect(engine.notices.isEmpty && engine.pendingCount == 0)
    }

    @Test func aDeleteWhileTheCreateIsOnTheWireReallyDeletes() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.delay = .milliseconds(150) }
        let e = engine.addEvent(to: own, allDay("oops", 2026, 11, 11))
        await waitUntilSending(engine)
        engine.deleteEvent(engine.event(e.id)!)
        server.set { $0.delay = .zero }
        await engine.refresh()
        await engine.refresh()
        #expect(server.get { $0.events[e.id]?.deleted } == true, "the create landed and was never deleted")
        #expect(engine.event(e.id) == nil)
        #expect(engine.notices.isEmpty && engine.pendingCount == 0)
    }

    @Test func createThenThisAndFollowingOffline() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var f = third.event.fields
        f.title = "Gym (new place)"
        f.when = .allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 17))
        engine.updateFollowing(third, f)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        #expect(server.get { $0.writes } == ["create Gym", "split"])
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title).suffix(3) == ["Gym (new place)", "Gym (new place)", "Gym (new place)"])
    }

    @Test func editsToBothHalvesAfterAQueuedSplit() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        server.set { $0.offline = true }
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var nf = third.event.fields
        nf.when = .allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 17))
        engine.updateFollowing(third, nf)
        let newID = engine.occurrences(from: nov.0, through: nov.1).last!.seriesID!
        var old = engine.event(s.id)!.fields
        old.notes = "first half"
        engine.updateEvent(engine.event(s.id)!, old)
        var new = engine.event(newID)!.fields
        new.notes = "second half"
        engine.updateEvent(engine.event(newID)!, new)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        #expect(server.get { $0.events[s.id]?.fields.notes } == "first half")
        #expect(server.get { $0.events[newID]?.fields.notes } == "second half")
    }

    @Test func deletingTheSeriesAfterAQueuedSplitLeavesNoPhantom() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        server.set { $0.offline = true }
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var nf = third.event.fields
        nf.when = .allDay(start: CalDate(2026, 11, 16), end: CalDate(2026, 11, 17))
        engine.updateFollowing(third, nf)
        let newID = engine.occurrences(from: nov.0, through: nov.1).last!.seriesID!
        engine.deleteEvent(engine.event(s.id)!)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        // The new series exists on the server exactly as it does here.
        #expect(server.get { $0.events[newID] } != nil && engine.event(newID) != nil)
        #expect(server.get { $0.events[s.id]?.deleted } == true)
    }

    @Test func writesBuiltOnARefusedOneAreNotSentAnyway() async {
        let (engine, server, _) = makeEngine()
        let theirs = server.addCalendar(owner: UUID(), role: .view)
        await engine.refresh()
        server.set { $0.offline = true }
        let e = engine.addEvent(to: theirs, allDay("nope", 2026, 11, 5))
        var f = e.fields
        f.title = "still nope"
        engine.updateEvent(engine.event(e.id)!, f) // merged into the create while offline
        engine.setAlerts(for: engine.event(e.id)!, minutesBefore: [60])
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.notices.count == 1, "\(engine.notices.map(\.message))")
        #expect(engine.pendingCount <= 1) // the alert may still go (it's the person's own)
        // The create was tried once and refused; nothing built on it went out.
        let writes = server.get { $0.writes }
        #expect(writes.filter { $0.hasPrefix("create") }.count == 1)
        #expect(!writes.contains { $0.hasPrefix("update") })
    }
}

/// Review R7/R9/R18: a write applied on the server whose answer never came back.
@MainActor
@Suite("Engine: lost answers", .serialized)
struct LostAnswerTests {
    @Test func aLostUpdateAnswerIsNotACollision() async {
        let (engine, server, own) = makeEngine()
        let e = server.externalCreate(own, allDay("Dentist", 2026, 11, 10))
        await engine.refresh()
        var f = e.fields
        f.title = "Dentist 3pm"
        server.set { $0.loseNextAnswer = true }
        engine.updateEvent(engine.event(e.id)!, f)
        await engine.refresh() // applied, answer lost: stays queued
        await engine.refresh() // retried: the server already has it
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        #expect(engine.pendingCount == 0)
        #expect(engine.event(e.id)?.fields.title == "Dentist 3pm")
    }

    @Test func aLostDeleteAnswerIsNotNoLongerThere() async {
        let (engine, server, own) = makeEngine()
        let e = server.externalCreate(own, allDay("Dentist", 2026, 11, 10))
        await engine.refresh()
        server.set { $0.loseNextAnswer = true }
        engine.deleteEvent(engine.event(e.id)!)
        await engine.refresh()
        await engine.refresh()
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        #expect(engine.pendingCount == 0 && engine.event(e.id) == nil)
    }

    @Test func aLostSplitAnswerStillDeletesTheFuture() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        server.set { $0.loseNextAnswer = true }
        engine.deleteFollowing(third)
        await engine.refresh() // the split applied, its answer lost
        await engine.refresh() // retried: same split back, tail deleted
        #expect(engine.notices.isEmpty, "\(engine.notices.map(\.message))")
        #expect(engine.pendingCount == 0)
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Class", "Class"])
        let live = server.get { $0.events.values.filter { !$0.deleted && $0.masterID == nil }.count }
        #expect(live == 1, "the tail series survived on the server")
    }
}

/// R6/R53: a series whose rule the server sends in another weekday order keeps
/// its exceptions when only its title changes.
@MainActor
@Suite("Engine: rule order", .serialized)
struct RuleOrderTests {
    @Test func aTitleEditKeepsTheExceptionsOfASundaySeries() async {
        let (engine, server, own) = makeEngine()
        // As the old server sent it: Sunday (7) before Wednesday (3).
        let s = server.externalCreate(own, allDay("Gym", 2026, 11, 1, repeating: CalRecurrence(.weekly, weekdays: [7, 3])))
        await engine.refresh()
        let occ = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }
        engine.deleteOccurrence(occ[1])
        await engine.refresh()
        let before = engine.occurrences(from: nov.0, through: nov.1).count
        var f = engine.event(s.id)!.fields
        f.title = "Gym (renamed)"
        engine.updateEvent(engine.event(s.id)!, f)
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == before, "the cancelled occurrence came back")
    }
}

/// R3/R37/R36: "this and following" on a count-limited series, and with
/// Repeat = Never.
@MainActor
@Suite("Engine: following on counted series", .serialized)
struct FollowingCountTests {
    let all = (CalDate(2026, 11, 1), CalDate(2027, 3, 31))

    @Test func theNewSeriesGetsTheRemainingCount() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("PT", 2026, 11, 2, repeating: CalRecurrence(.weekly, count: 10)))
        await engine.refresh()
        let fourth = engine.occurrences(from: all.0, through: all.1).filter { $0.seriesID == s.id }[3]
        var f = engine.event(s.id)!.fields // the editor starts from the series' fields: count 10
        f.title = "PT (new clinic)"
        f.when = fourth.when
        engine.updateFollowing(fourth, f)
        await engine.refresh()
        let occ = engine.occurrences(from: all.0, through: all.1)
        #expect(occ.count == 10, "a 10-session series became \(occ.count)")
        #expect(occ.filter { $0.title == "PT (new clinic)" }.count == 7)
        #expect(engine.notices.isEmpty)
        _ = server
    }

    @Test func repeatNeverMakesTheRestOneEvent() async {
        let (engine, _, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Gym", 2026, 11, 2, repeating: CalRecurrence(.weekly)))
        await engine.refresh()
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var f = third.event.fields
        f.recurrence = nil // Repeat: Never
        f.when = third.when
        f.title = "Gym (last time)"
        engine.updateFollowing(third, f)
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Gym", "Gym", "Gym (last time)"])
    }
}

/// R19: reminders follow a split to the new series.
@MainActor
@Suite("Engine: reminders across a split", .serialized)
struct SplitReminderTests {
    @Test func theNewSeriesKeepsTheSeriesReminders() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let s = engine.addEvent(to: own, allDay("Class", 2026, 11, 2, repeating: CalRecurrence(.weekly)), alerts: [900])
        await engine.refresh()
        let third = engine.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == s.id }[2]
        var f = third.event.fields
        f.title = "Class (new room)"
        f.when = third.when
        engine.updateFollowing(third, f)
        await engine.refresh()
        let newID = engine.occurrences(from: nov.0, through: nov.1).last!.seriesID!
        #expect(newID != s.id)
        #expect(engine.alerts[newID] == [900])
        #expect(server.get { $0.alerts[newID]?.minutesBefore } == [900])
        #expect(engine.notices.isEmpty)
    }
}

/// R28: a label deleted elsewhere reaches this device on its events too.
@MainActor
@Suite("Engine: label deleted elsewhere", .serialized)
struct LabelDeletedElsewhereTests {
    @Test func eventsLoseTheLabelOnTheNextSync() async throws {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        let label = engine.saveLabel(name: "Work", color: .orange)!
        var f = allDay("Shift", 2026, 11, 5)
        f.labelID = label.id
        let e = engine.addEvent(to: own, f)
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).first?.color == .orange)
        try await server.externalDeleteLabel(label.id) // the owner's other phone
        await engine.refresh()
        #expect(engine.event(e.id)?.fields.labelID == nil)
        #expect(engine.labels.isEmpty)
        #expect(engine.occurrences(from: nov.0, through: nov.1).first?.color != .orange)
    }
}

/// R21/R39/R61: retry policy.
@MainActor
@Suite("Engine: retry policy", .serialized)
struct RetryPolicyTests {
    @Test func aWriteTheServerKeepsFailingOnGivesUpAndUnblocksTheQueue() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.failAllWrites = .serverFailed("internal error") }
        let stuck = engine.addEvent(to: own, allDay("stuck", 2026, 11, 3))
        for _ in 0..<20 where engine.notices.isEmpty { await engine.refresh() }
        // Refused after exactly the allowed number of server failures, not before.
        #expect(server.get { $0.failedWrites } == CalendarEngine.maxServerFailures)
        #expect(engine.notices.count == 1)
        #expect(engine.notices.first?.message.contains("kept failing") == true)
        #expect(engine.event(stuck.id) == nil && engine.pendingCount == 0)
        // The queue moves on.
        server.set { $0.failAllWrites = nil }
        engine.addEvent(to: own, allDay("next", 2026, 11, 4))
        await engine.refresh()
        #expect(server.get { $0.events.values.contains { $0.fields.title == "next" } })
    }

    @Test func timeSpentOfflineDoesntCountTowardGivingUp() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        engine.addEvent(to: own, allDay("long trip", 2026, 11, 3))
        for _ in 0..<12 { await engine.refresh() }
        server.set { $0.offline = false; $0.failNextWrite = .serverFailed("hiccup") }
        await engine.refresh() // one server failure after a dozen offline tries
        #expect(engine.notices.isEmpty, "gave up on the first server failure")
        await engine.refresh()
        #expect(engine.pendingCount == 0)
    }

    @Test func beingOfflineNeverGivesUp() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        engine.addEvent(to: own, allDay("later", 2026, 11, 3))
        for _ in 0..<(CalendarEngine.maxServerFailures * 3) { await engine.refresh() }
        #expect(engine.pendingCount == 1 && engine.notices.isEmpty)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.pendingCount == 0)
    }
}
