import Foundation
import Observation
import os

private let log = Logger(subsystem: "CalendarKit", category: "engine")

/// Something the person should know about a write that didn't land.
public struct CalNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let message: String
}

/// The kit coordinator. Hosts build it inert, `start()` it when the calendar is
/// on screen, `stop()` it when it goes away, and call `wipeLocalStore()` on
/// sign-out (the engine lifetime law, as GarageEngine).
///
/// Writes are applied locally at once and queued; the queue is replayed in
/// order before every sync. A write the server refuses for good, or one that
/// lost a race with someone else's change, is dropped with a notice and its
/// calendar is reloaded from the server: the cache never drifts from the truth.
/// A write that can't get through (offline, slow down, signed out) waits.
@MainActor
@Observable
public final class CalendarEngine {
    public enum LoadState: Sendable, Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// Every calendar the person can see (own first), with their display prefs.
    public private(set) var calendars: [CalCalendar] = []
    /// Labels of every visible calendar, by name.
    public private(set) var labels: [CalLabel] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var isSyncing = false
    /// A sync problem worth showing (cleared by the next good sync).
    public private(set) var lastError: String?
    /// Writes the server refused or that lost a race, newest last.
    public private(set) var notices: [CalNotice] = []
    /// Writes waiting for the server.
    public private(set) var pendingCount = 0
    public private(set) var alertDefaults = CalAlertDefaults()
    /// The person's reminders, by event.
    public private(set) var alerts: [UUID: [Int]] = [:]
    /// Bumped on every change to cached data: views re-query occurrences on it.
    public private(set) var revision = 0
    /// Names and avatars of the person's friends (and themselves), from the
    /// server's directory. In memory, refreshed every few minutes.
    public private(set) var people: [UUID: CalContact] = [:]
    private var peopleLoadedAt: Date?

    public let config: CalendarConfig
    private let transport: any CalendarTransport
    private var store: CalendarStore?
    private var refreshTask: Task<Void, Never>?
    /// The refresh running now (refreshes never overlap).
    private var inflight: Task<Void, Never>?
    /// Bumped by stop() and wipe: work that started before must not write after.
    private var generation = 0

    /// Tests use an in-memory store.
    var storeInMemory = false

    private let reminders: ReminderScheduler
    /// How far ahead reminders are planned.
    var reminderHorizonDays = 35

    public init(config: CalendarConfig, transport: (any CalendarTransport)? = nil,
                reminderCenter: (any ReminderCenter)? = nil) {
        self.config = config
        self.transport = transport ?? config.transport
        self.reminders = ReminderScheduler(center: reminderCenter ?? SystemReminderCenter())
    }

    /// The reminder replan running now, if any (tests await it).
    private(set) var replanTask: Task<Void, Never>?
    private var replanAgain = false

    /// Re-plan reminders without holding up the caller. The notification center
    /// can wait a long time (a permission prompt still up): a sync must never
    /// wait on it. One replan at a time; a request during one runs once more after.
    func scheduleReplan() {
        guard replanTask == nil else { replanAgain = true; return }
        replanTask = Task { [weak self] in
            repeat {
                self?.replanAgain = false
                await self?.replanReminders()
            } while self?.replanAgain == true
            self?.replanTask = nil
        }
    }

    /// Re-plan local reminders from the cache (after every sync; hosts also
    /// call it when the app comes to the foreground).
    public func replanReminders(now: Date = Date()) async {
        guard config.remindersEnabled, store != nil, !isWiped else { return }
        let zone = TimeZone.current
        let today = CalDate(now, in: zone)
        let plan = ReminderPlanner.plan(occurrences: occurrences(from: today.adding(days: -1),
                                                                 through: today.adding(days: reminderHorizonDays), zone: zone),
                                        alerts: alerts, now: now, zone: zone, budget: config.reminderBudget,
                                        me: config.currentUserID, defaults: alertDefaults)
        log.debug("reminders: planning \(plan.count, privacy: .public)")
        guard !isWiped else { return }
        let (added, removed) = await reminders.apply(plan)
        log.debug("reminders: +\(added, privacy: .public) -\(removed, privacy: .public)")
    }

    public var ownCalendar: CalCalendar? { calendars.first(where: \.isOwn) }

    /// Calendars the person may add events to.
    public var writableCalendars: [CalCalendar] { calendars.filter { $0.role.canWrite } }

    // MARK: lifecycle

    /// Open the cache and keep it fresh while started. Idempotent.
    public func start() {
        isWiped = false
        guard refreshTask == nil else { return }
        openStore()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.config.refreshInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop refreshing. Safe to call repeatedly.
    public func stop() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Set by wipeLocalStore(), cleared by start(): after a sign-out nothing
    /// still in flight may refresh, write to the cache or plan reminders, or
    /// the signed-out person's calendar comes back (R16).
    private(set) var isWiped = false
    /// Bumped by wipeLocalStore(): a write that lands afterwards mustn't touch
    /// the (wiped) cache.
    private var wipes = 0

    /// Sign-out: stop, then delete the cache (and queued writes) for this user.
    public func wipeLocalStore() {
        stop()
        wipes += 1
        // Clear reminders after any replan already running, so it can't add
        // them back behind the clear (R15, R40).
        let r = reminders, running = replanTask
        replanTask = nil
        Task { await running?.value; await r.clear() }
        // Open (if this launch never did) and wipe BEFORE marking the engine
        // signed out: openStore() refuses once isWiped is set, and a sign-out
        // that never opened the store left the last person's cache on disk.
        if store == nil { openStore() }
        store?.wipeAll()
        store = nil
        isWiped = true
        calendars = []
        labels = []
        alerts = [:]
        people = [:]
        peopleLoadedAt = nil
        notices = []
        pendingCount = 0
        loadState = .idle
        lastError = nil
        occurrenceCache.removeAll()
        publishedEventChanges = -1
        revision += 1
    }

    private func openStore() {
        guard store == nil, !isWiped else { return }
        do {
            store = try CalendarStore(userID: config.currentUserID, appGroup: config.appGroup, inMemory: storeInMemory)
        } catch {
            log.error("store failed to open: \(error.localizedDescription, privacy: .public)")
            store = try? CalendarStore(userID: config.currentUserID, appGroup: nil, inMemory: true)
        }
        publish()
    }

    /// Publish the cache to the views. Only what changed is assigned, and
    /// `revision` moves only when something did, so a sync that brought
    /// nothing new doesn't make every view rebuild (R22).
    private func publish() {
        guard let store else { return }
        var changed = store.eventChanges != publishedEventChanges
        publishedEventChanges = store.eventChanges
        let cals = store.calendars().map(\.0)
        if cals != calendars { calendars = cals; changed = true }
        let visible = Set(cals.map(\.id))
        let ls = store.labels().filter { visible.contains($0.calendarID) }
        if ls != labels { labels = ls; changed = true }
        let al = store.alerts()
        if al != alerts { alerts = al; changed = true }
        let defaults = store.alertDefaults
        if defaults != alertDefaults { alertDefaults = defaults; changed = true }
        let pc = store.pendingCount
        if pc != pendingCount { pendingCount = pc; changed = true }
        if changed { revision += 1 }
    }
    private var publishedEventChanges = -1

    public func dismissNotice(_ n: CalNotice) { notices.removeAll { $0.id == n.id } }

    private func loadPeopleIfStale() async {
        if let at = peopleLoadedAt, Date().timeIntervalSince(at) < 600 { return }
        let list: [CalContact]
        do { list = try await transport.listContacts() } catch {
            log.error("contacts failed: \(String(describing: error), privacy: .public)")
            return
        }
        log.debug("contacts: \(list.count, privacy: .public)")
        people = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        peopleLoadedAt = Date()
    }

    /// What to call a calendar: its own name, else its owner's.
    public func displayName(_ c: CalCalendar) -> String {
        if !c.name.isEmpty { return c.name }
        if let p = people[c.ownerID] { return p.name }
        return c.isOwn ? "My calendar" : "Shared calendar"
    }

    /// The owner of a calendar, if the directory knows them.
    public func owner(of c: CalCalendar) -> CalContact? { people[c.ownerID] }

    // MARK: reading

    /// What to draw between two days (inclusive), in the viewer's zone, from
    /// the calendars they've chosen to show (pass `includeHidden` for all).
    public func occurrences(from: CalDate, through: CalDate, zone: TimeZone = .current,
                            includeHidden: Bool = false) -> [CalOccurrence] {
        guard let store else { return [] }
        // Built once per (cache contents, published state, range): a view body
        // pass that only moved the selection, or a sync that changed nothing,
        // reuses it (R22).
        let key = OccurrenceKey(events: store.eventChanges, revision: revision, from: from, through: through,
                                zone: zone.identifier, hidden: includeHidden)
        if let hit = occurrenceCache[key] { return hit }
        if let any = occurrenceCache.keys.first, any.events != key.events || any.revision != key.revision {
            occurrenceCache.removeAll(keepingCapacity: true)
        }
        if occurrenceCache.count >= 8 { occurrenceCache.removeAll(keepingCapacity: true) }
        let built = buildOccurrences(store, from: from, through: through, zone: zone, includeHidden: includeHidden)
        occurrenceCache[key] = built
        return built
    }

    private struct OccurrenceKey: Hashable {
        let events: Int, revision: Int
        let from: CalDate, through: CalDate
        let zone: String, hidden: Bool
    }
    private var occurrenceCache: [OccurrenceKey: [CalOccurrence]] = [:]

    private func buildOccurrences(_ store: CalendarStore, from: CalDate, through: CalDate, zone: TimeZone,
                                  includeHidden: Bool) -> [CalOccurrence] {
        let cals = calendars.filter { includeHidden || $0.visible }
        var events = store.events(in: cals.map(\.id), from: from.adding(days: -1), through: through.adding(days: 1))
        // An occurrence moved outside its series' days (the last one moved past
        // the end, the first before the start) is found by its own days; its
        // series has to come along to be expanded (R10, R26).
        let missing = Set(events.compactMap(\.masterID)).subtracting(events.map(\.id))
        if !missing.isEmpty { events += store.events(ids: missing) }
        let series = events.filter(\.isSeries).map(\.id)
        let exceptions = series.isEmpty ? [] : store.exceptions(of: series)
        return OccurrenceBuilder.build(events: events, exceptions: exceptions,
                                       calendars: Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0) }),
                                       labels: Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) }),
                                       from: from, through: through, zone: zone)
    }

    public func event(_ id: UUID) -> CalEvent? { store?.event(id) }

    public func calendar(_ id: UUID) -> CalCalendar? { calendars.first { $0.id == id } }

    /// The reminders in effect for an occurrence (what the planner schedules
    /// and what a detail view should show): explicit ones, else the person's
    /// defaults for events someone else added.
    public func effectiveAlerts(for o: CalOccurrence) -> [Int] {
        ReminderPlanner.effective(o, alerts: alerts, me: config.currentUserID, defaults: alertDefaults)
    }

    public func labels(of calendarID: UUID) -> [CalLabel] { labels.filter { $0.calendarID == calendarID } }

    // MARK: refresh

    /// Push queued writes, then pull every change. When it returns, everything
    /// queued before the call has been tried: a caller arriving while a refresh
    /// runs waits for it, then runs its own (one at a time, never overlapping).
    public func refresh() async {
        while let running = inflight { await running.value }
        guard !isWiped else { return } // signed out meanwhile: nothing to sync
        let task = Task { [weak self] in
            await self?.runRefresh()
            self?.inflight = nil // cleared by the task itself, so no waiter ever sees a finished one
        }
        inflight = task
        await task.value
    }

    private func runRefresh() async {
        openStore()
        isSyncing = true
        defer { isSyncing = false }
        let gen = generation
        if calendars.isEmpty { loadState = .loading }
        await flush(gen)
        guard gen == generation, let store else { return }
        do {
            for _ in 0..<200 { // pages
                let page = try await transport.sync(cursors: store.cursors(), alertsCursor: store.alertsCursor)
                guard gen == generation else { return }
                apply(page, to: store)
                store.save()
                publish()
                // More of a calendar (or calendars the server didn't get to),
                // or more alerts: ask again.
                if !page.deltas.contains(where: \.hasMore) && !page.alertsHasMore { break }
            }
            store.lastSync = Date()
            store.save()
            lastError = nil
            loadState = .loaded
            await loadPeopleIfStale()
            scheduleReplan()
        } catch let e as CalTransportError {
            guard gen == generation else { return }
            lastError = Self.describe(e)
            if calendars.isEmpty { loadState = .failed(lastError ?? "") }
        } catch {
            guard gen == generation else { return }
            lastError = "Couldn't sync"
        }
    }

    private func apply(_ page: CalSyncPage, to store: CalendarStore) {
        let now = Set(page.calendars.map(\.id))
        for (c, _) in store.calendars() where !now.contains(c.id) {
            store.removeCalendar(c.id)
        }
        store.setCalendars(page.calendars)
        let held = store.cursors()
        // Events deleted here and not yet sent: a page (perhaps built before
        // the delete reached the server) mustn't bring them back (R41).
        let deleting = Set(store.pending().compactMap { (_, w) -> UUID? in
            if case .delete(let id, _, _) = w { return id }
            return nil
        })
        // A calendar this device holds nothing confirmed for (cursor 0) that the
        // server sends no delta for has nothing on the server: drop leftovers.
        let withDelta = Set(page.deltas.map(\.calendarID))
        for c in page.calendars where (held[c.id]?.rev ?? 0) == 0 && !withDelta.contains(c.id) {
            store.clearForReload(c.id)
        }
        for d in page.deltas {
            // Only the first page of a load (or a reload) starts from nothing;
            // later pages of the same load add to it.
            if d.reload || (held[d.calendarID]?.rev ?? 0) == 0 {
                store.clearForReload(d.calendarID)
            }
            store.applyServerEvents(d.events, skip: deleting)
            for l in d.labels { store.putLabel(l) }
            for id in d.deletedLabelIDs { store.removeLabel(id) }
            // loadFrom stays set until a page says has_more is false. If that
            // last answer is lost, the next delta still carries it; that's safe
            // (loadFrom ≤ rev, so the server only judges purges more strictly).
            store.setCursor(d.calendarID, d.rev, loadFrom: d.loadFrom)
        }
        for a in page.alerts { store.putAlert(a) }
        // The server's cursor is right even when it cut the list (it's then the
        // last alert sent), so no guessing from a count (R58, R66).
        store.alertsCursor = page.alertsRev
        store.alertDefaults = page.alertDefaults
    }

    // MARK: the write queue

    /// The queued write being sent right now. enqueue() never merges into or
    /// drops it: a change made while it's on the wire is queued after it (and
    /// rebased onto its answer), or it would be lost when it lands.
    private var inFlight: UUID?

    private func flush(_ gen: Int) async {
        guard let store else { return }
        let w0 = wipes
        // Re-read the queue before each write: a refused write drops the ones
        // built on it, and writes made meanwhile join the end.
        for _ in 0..<1000 {
            guard gen == generation, let (pid, w) = store.pending().first else { return }
            inFlight = pid
            do {
                try await perform(w, pid: pid, store: store, alive: { [weak self] in self?.wipes == w0 })
                inFlight = nil
                guard wipes == w0 else { return }
                // It happened on the server: off the queue even if stop() came
                // meanwhile, or it would be sent again (R13, R14).
                store.dropPending(pid)
                guard gen == generation else { store.save(); publish(); return }
            } catch is CancellationError {
                inFlight = nil
                return // signed out while it was on the wire
            } catch let e as CalTransportError where e.isRetryable && !gaveUp(e, pid: pid, store: store) {
                inFlight = nil
                guard wipes == w0 else { return }
                store.bumpAttempts(pid)
                if case .serverFailed = e { store.bumpServerFailures(pid) }
                store.save()
                if gen == generation { lastError = Self.describe(e) }
                break // keep the order: everything after waits too
            } catch {
                inFlight = nil
                guard gen == generation, wipes == w0 else { return }
                store.dropPending(pid)
                refused(w, error: error, store: store)
            }
            refreshPendingFlags(store)
            store.save()
            publish()
        }
    }

    /// A write the server keeps failing on (an internal error, not being
    /// offline) stops being retried after a few tries and is refused with a
    /// notice, so it can't hold up everything queued behind it (R21/R39).
    static let maxServerFailures = 5

    private func gaveUp(_ e: CalTransportError, pid: UUID, store: CalendarStore) -> Bool {
        guard case .serverFailed = e else { return false }
        return store.serverFailures(pid) + 1 >= Self.maxServerFailures
    }

    /// What the server answered for an event, applied: later queued writes
    /// about it were built on the rev it had then, so they're rebased onto this
    /// one. While any are still waiting, the local copy (which already shows
    /// them) keeps its fields and takes only the new rev; an event deleted
    /// locally meanwhile isn't brought back.
    private func landed(_ e: CalEvent, after pid: UUID, store: CalendarStore) {
        let waiting = rebase(e.id, to: e.rev, after: pid, store: store)
        guard waiting else { return store.put(e, pending: true) }
        guard var local = store.event(e.id) else { return }
        // Server-owned bookkeeping comes from the answer; the fields stay local
        // (the queued write carries them, and its own answer brings back the
        // server's normalisation).
        local.rev = e.rev
        local.createdBy = e.createdBy
        local.createdAt = e.createdAt
        local.updatedBy = e.updatedBy
        local.updatedAt = e.updatedAt
        store.put(local, pending: true)
    }

    /// Point later queued writes about `id` at `rev`. Returns whether any wait.
    @discardableResult
    private func rebase(_ id: UUID, to rev: Int64, after pid: UUID, store: CalendarStore) -> Bool {
        var waiting = false
        for (qpid, q) in store.pending() where qpid != pid {
            switch q {
            case .update(let qid, _, let f) where qid == id:
                store.replacePending(qpid, with: .update(id: qid, baseRev: rev, fields: f)); waiting = true
            case .delete(let qid, _, let cal) where qid == id:
                store.replacePending(qpid, with: .delete(id: qid, baseRev: rev, calendarID: cal)); waiting = true
            case .split(let m, _, let at, let ns, let discard) where m == id:
                store.replacePending(qpid, with: .split(masterID: m, baseRev: rev, at: at, newSeries: ns, discardNew: discard)); waiting = true
            case .alerts:
                break // the person's reminders aren't event fields
            default:
                if q.eventID == id { waiting = true }
            }
        }
        return waiting
    }

    /// Send one write and apply what the server answered.
    private func perform(_ w: PendingWrite, pid: UUID, store: CalendarStore, alive: @escaping () -> Bool = { true }) async throws {
        // After each answer, before touching the cache: signed out meanwhile?
        func live<T>(_ v: T) throws -> T {
            guard alive() else { throw CancellationError() }
            return v
        }
        switch w {
        case .create(let e):
            landed(try live(try await transport.createEvent(id: e.id, calendarID: e.calendarID, fields: e.fields)), after: pid, store: store)
        case .exception(let e):
            let saved = try await transport.createException(id: e.id, calendarID: e.calendarID, masterID: e.masterID!,
                                                            originalStart: e.originalStart!, fields: e.fields, cancelled: e.cancelled)
            landed(try live(saved), after: pid, store: store)
        case .update(let id, let base, let fields):
            do {
                landed(try live(try await transport.updateEvent(id: id, baseRev: base, fields: fields)), after: pid, store: store)
            } catch CalTransportError.conflict(let current?) where current.fields == fields && current.updatedBy == config.currentUserID {
                // A retry of an update whose answer was lost: the server
                // already has exactly this change, from us. Done, not a race.
                landed(try live(current), after: pid, store: store)
            }
        case .delete(let id, let base, _):
            do {
                _ = try await transport.deleteEvent(id: id, baseRev: base)
            } catch CalTransportError.notFound {
                // Already gone (a retry whose answer was lost, or someone else
                // deleted it): what we wanted either way.
            }
            _ = try live(())
            store.removeEvent(id)
            store.removeExceptions(of: id)
        case .split(let master, let base, let at, let s, let discardNew):
            let r = try live(try await transport.splitSeries(masterID: master, baseRev: base, at: at, newID: s.id, fields: s.fields))
            landed(r.old, after: pid, store: store)
            if discardNew {
                // "Delete this and following": the tail goes at once. It's never
                // put in the store, so nothing can be queued against its id. On a
                // retry the server returns the same split (idempotent by the new
                // id), and a tail already deleted is fine.
                if !r.new.deleted {
                    do { _ = try await transport.deleteEvent(id: r.new.id, baseRev: r.new.rev) }
                    catch CalTransportError.notFound {}
                }
            } else {
                landed(r.new, after: pid, store: store)
            }
        case .alerts(let id, let minutes):
            store.putAlert(try live(try await transport.setAlerts(eventID: id, minutesBefore: minutes)))
        case .alertDefaults(let d):
            store.alertDefaults = try live(try await transport.setAlertDefaults(d))
        case .pref(let id, let visible, let color):
            try await transport.setCalendarPref(calendarID: id, visible: visible, color: color)
        case .saveLabel(let l):
            store.putLabel(try live(try await transport.saveLabel(id: l.id, name: l.name, color: l.color)))
        case .deleteLabel(let id, _):
            try await transport.deleteLabel(id: id)
        case .updateCalendar(let name, let color):
            let c = try live(try await transport.updateCalendar(name: name, color: color))
            store.updateCalendar(c.id) { $0.name = c.name; $0.color = c.color }
        }
    }

    /// A write the server won't take: tell the person, and reload its calendar
    /// so the optimistic change disappears.
    private func refused(_ w: PendingWrite, error: Error, store: CalendarStore) {
        let title = w.eventID.flatMap { store.event($0)?.fields.title }
        let what = title.map { "“\($0)”" } ?? "a change"
        let message: String
        switch error as? CalTransportError {
        case .conflict(let current)?:
            if let current { store.put(current, pending: false) }
            message = "Someone else changed \(what) first, so your change wasn't saved."
        case .forbidden?:
            message = "You can view this calendar but not change it, so \(what) wasn't saved."
        case .notFound?:
            message = "\(what.prefix(1).uppercased() + what.dropFirst()) is no longer there, so your change wasn't saved."
        case .invalid(let m)?:
            message = "\(what.prefix(1).uppercased() + what.dropFirst()) couldn't be saved: \(m)."
        case .limit?:
            message = "That calendar is full, so \(what) wasn't saved."
        case .serverFailed?:
            message = "The calendar server kept failing, so \(what) wasn't saved."
        default:
            message = "\(what.prefix(1).uppercased() + what.dropFirst()) couldn't be saved."
        }
        notices.append(CalNotice(message: message))
        switch w {
        case .create(let e), .exception(let e):
            store.removeEvent(e.id) // it never existed on the server
        default: break
        }
        if let id = w.eventID { store.setPending(id, false) }
        if let cal = w.calendarID(lookup: { store.event($0)?.calendarID }) {
            store.resetCursor(cal)
        }
        // Later writes about the same event were built on this one: drop them too.
        if let id = w.eventID {
            for (pid, other) in store.pending() where other.eventID == id { store.dropPending(pid) }
        }
    }

    private func refreshPendingFlags(_ store: CalendarStore) {
        store.syncPendingFlags(waiting: Set(store.pending().compactMap { $0.1.eventID }))
    }

    /// Queue a write, merging it into one already waiting for the same event.
    private func enqueue(_ w: PendingWrite, store: CalendarStore) {
        // Never merge into, or drop, the write on the wire.
        let queued = store.pending().filter { $0.0 != inFlight }
        switch w {
        case .update(let id, _, let fields):
            for (pid, q) in queued {
                switch q {
                case .create(var e) where e.id == id:
                    e.fields = fields
                    store.replacePending(pid, with: .create(e)); return
                case .exception(var e) where e.id == id:
                    e.fields = fields
                    e.cancelled = false
                    store.replacePending(pid, with: .exception(e)); return
                case .update(let qid, let base, _) where qid == id:
                    store.replacePending(pid, with: .update(id: id, baseRev: base, fields: fields)); return
                default: continue
                }
            }
        case .delete(let id, _, let cal):
            var sawCreate = false
            for (pid, q) in queued where q.eventID == id {
                // A split made another series that still has to happen; the
                // delete of this one is rebased onto the split's answer.
                if case .split = q { continue }
                if case .create = q { sawCreate = true }
                if case .exception = q { sawCreate = true }
                if case .update(_, let base, _) = q {
                    store.dropPending(pid)
                    store.enqueue(.delete(id: id, baseRev: base, calendarID: cal))
                    return
                }
                store.dropPending(pid)
            }
            if sawCreate { return } // never reached the server: nothing to delete there
        case .alerts(let id, _):
            for (pid, q) in queued { if case .alerts(id, _) = q { store.replacePending(pid, with: w); return } }
        case .pref(let id, _, _):
            for (pid, q) in queued { if case .pref(id, _, _) = q { store.replacePending(pid, with: w); return } }
        case .alertDefaults:
            for (pid, q) in queued { if case .alertDefaults = q { store.replacePending(pid, with: w); return } }
        default: break
        }
        store.enqueue(w)
    }

    /// Record a local change and push it soon.
    private func commit(_ w: PendingWrite) {
        guard let store else { return }
        enqueue(w, store: store)
        refreshPendingFlags(store)
        store.save()
        publish()
        Task { [weak self] in await self?.refresh() }
    }

    private func newEvent(id: UUID = UUID(), calendarID: UUID, fields: CalEventFields,
                          masterID: UUID? = nil, original: CalOriginalStart? = nil, cancelled: Bool = false) -> CalEvent {
        var f = fields
        if let r = f.recurrence { f.recurrence = CalRecurrenceExpander.normalized(r, first: f.when.firstDay) }
        let me = config.currentUserID
        return CalEvent(id: id, calendarID: calendarID, fields: f, masterID: masterID, originalStart: original,
                        cancelled: cancelled, createdBy: me, updatedBy: me, createdAt: Date(), updatedAt: Date(),
                        rev: 0, deleted: false)
    }

    // MARK: writing events

    /// Add an event (or a series) to a calendar the person may write to.
    /// `alerts`: the person's reminders for it; nil = their defaults (timed or
    /// all-day), [] = none.
    @discardableResult
    public func addEvent(to calendarID: UUID, _ fields: CalEventFields, alerts minutes: [Int]? = nil) -> CalEvent {
        openStore() // a write before the first refresh must not be lost
        let e = newEvent(calendarID: calendarID, fields: fields)
        store?.put(e, pending: true)
        commit(.create(e))
        let chosen = minutes ?? (fields.when.isAllDay ? alertDefaults.allDay : alertDefaults.timed)
        if !chosen.isEmpty { setAlerts(for: e, minutesBefore: chosen) }
        return e
    }

    /// Change a single event, a whole series, or an exception.
    public func updateEvent(_ event: CalEvent, _ fields: CalEventFields) {
        openStore() // a write before the first refresh must not be lost
        guard let store, var e = store.event(event.id) else { return }
        var f = fields
        if let r = f.recurrence { f.recurrence = CalRecurrenceExpander.normalized(r, first: f.when.firstDay) }
        let timingChanged = e.isSeries && (e.fields.when != f.when
            || e.fields.recurrence.map(CalRecurrenceExpander.canonical) != f.recurrence.map(CalRecurrenceExpander.canonical))
        e.fields = f
        e.cancelled = false
        e.updatedBy = config.currentUserID
        store.put(e, pending: true)
        if timingChanged { store.removeExceptions(of: e.id) } // the server drops them too
        commit(.update(id: e.id, baseRev: e.rev, fields: f))
    }

    /// Delete a single event, a whole series (with its exceptions), or an
    /// exception (its occurrence goes back to the series).
    public func deleteEvent(_ event: CalEvent) {
        openStore() // a write before the first refresh must not be lost
        guard let store, let e = store.event(event.id) else { return }
        store.removeEvent(e.id)
        if e.isSeries { store.removeExceptions(of: e.id) }
        commit(.delete(id: e.id, baseRev: e.rev, calendarID: e.calendarID))
    }

    /// Change just this occurrence of a series.
    public func updateOccurrence(_ o: CalOccurrence, _ fields: CalEventFields) {
        openStore() // a write before the first refresh must not be lost
        guard let series = o.seriesID, let original = o.originalStart else {
            return updateEvent(o.event, fields)
        }
        if o.event.isException { return updateEvent(o.event, fields) }
        var f = fields
        f.recurrence = nil
        let x = newEvent(calendarID: o.event.calendarID, fields: f, masterID: series, original: original)
        store?.put(x, pending: true)
        commit(.exception(x))
    }

    /// Remove just this occurrence of a series (or delete a single event).
    public func deleteOccurrence(_ o: CalOccurrence) {
        openStore() // a write before the first refresh must not be lost
        guard let series = o.seriesID, let original = o.originalStart else { return deleteEvent(o.event) }
        guard let store else { return }
        if o.event.isException { store.removeEvent(o.event.id) } // the cancellation replaces it
        let x = newEvent(calendarID: o.event.calendarID, fields: o.event.fields, masterID: series,
                         original: original, cancelled: true)
        store.put(x, pending: true)
        commit(.exception(x))
    }

    /// Change this and every later occurrence: the series ends before it and a
    /// new series starts there. The first occurrence changes the whole series.
    public func updateFollowing(_ o: CalOccurrence, _ fields: CalEventFields) {
        openStore() // a write before the first refresh must not be lost
        guard let store, let seriesID = o.seriesID, let original = o.originalStart,
              let series = store.event(seriesID), let rule = series.fields.recurrence else {
            return updateEvent(o.event, fields)
        }
        let firstDay = series.fields.when.firstDay
        let splitDay: CalDate
        switch original {
        case .date(let d): splitDay = d
        case .instant(let t):
            if case .timed(_, _, let tz) = series.fields.when { splitDay = CalDate(t, in: TimeZone(identifier: tz) ?? .gmt) } else { return }
        }
        guard splitDay > firstDay else { return updateEvent(series, fields) }
        var f = fields
        // Repeat = Never means just what it says: the rest becomes this one
        // event (R36). A count left as it was means the series' total: the
        // new series gets what's left, not the whole count again (R3).
        if let total = rule.count, f.recurrence?.count == total {
            let before = CalRecurrenceExpander.dates(rule, first: firstDay, through: splitDay.adding(days: -1)).count
            f.recurrence?.count = max(1, total - before)
        }
        let newSeries = newEvent(calendarID: series.calendarID, fields: f)
        var old = series
        old.fields.recurrence?.count = nil
        old.fields.recurrence?.until = splitDay.adding(days: -1)
        store.put(old, pending: true)
        store.put(newSeries, pending: true)
        commit(.split(masterID: series.id, baseRev: series.rev, at: original, newSeries: newSeries, discardNew: false))
        // Everyone's reminders follow the split on the server (it copies them
        // in the same transaction, when all-day/timed matches). Show ours at
        // once; the next sync brings the server's copy.
        if let minutes = store.alerts()[series.id], f.when.isAllDay == series.fields.when.isAllDay {
            store.putAlert(CalAlert(eventID: newSeries.id, minutesBefore: minutes, rev: 0))
            store.save()
            publish()
        }
    }

    /// Delete this and every later occurrence (earlier ones, and their
    /// changes, stay). The first occurrence deletes the whole series.
    public func deleteFollowing(_ o: CalOccurrence) {
        openStore() // a write before the first refresh must not be lost
        guard let store, let seriesID = o.seriesID, let original = o.originalStart,
              let series = store.event(seriesID) else { return deleteOccurrence(o) }
        let splitDay: CalDate
        switch original {
        case .date(let d): splitDay = d
        case .instant(let t):
            guard case .timed(_, _, let tz) = series.fields.when else { return }
            splitDay = CalDate(t, in: TimeZone(identifier: tz) ?? .gmt)
        }
        guard splitDay > series.fields.when.firstDay else { return deleteEvent(series) }
        // The server splits at the occurrence (dropping only the tail's
        // exceptions) and the tail is deleted; an "until" edit would instead
        // drop every exception of the series.
        let tail = newEvent(calendarID: series.calendarID, fields: o.event.fields)
        var old = series
        old.fields.recurrence?.count = nil
        old.fields.recurrence?.until = splitDay.adding(days: -1)
        store.put(old, pending: true)
        // The tail's exceptions go with it (the server drops them too).
        var seriesZone = TimeZone.gmt
        if case .timed(_, _, let tz) = series.fields.when { seriesZone = TimeZone(identifier: tz) ?? .gmt }
        for x in store.exceptions(of: [series.id]) {
            let day: CalDate?
            switch x.originalStart {
            case .date(let d): day = d
            case .instant(let t): day = CalDate(t, in: seriesZone)
            case nil: day = nil
            }
            if let day, day >= splitDay { store.removeEvent(x.id) }
        }
        var tailFields = o.event.fields
        if tailFields.recurrence == nil { tailFields.recurrence = series.fields.recurrence }
        commit(.split(masterID: series.id, baseRev: series.rev, at: original,
                      newSeries: CalEvent(id: tail.id, calendarID: tail.calendarID, fields: tailFields, masterID: nil,
                                          originalStart: nil, cancelled: false, createdBy: tail.createdBy, updatedBy: tail.updatedBy,
                                          createdAt: tail.createdAt, updatedAt: tail.updatedAt, rev: 0, deleted: false),
                      discardNew: true))
    }

    // MARK: private settings

    public func setAlerts(for event: CalEvent, minutesBefore: [Int]) {
        openStore() // a write before the first refresh must not be lost
        guard let store else { return }
        store.putAlert(CalAlert(eventID: event.id, minutesBefore: minutesBefore, rev: 0))
        commit(.alerts(eventID: event.id, minutes: minutesBefore))
    }

    public func setAlertDefaults(_ d: CalAlertDefaults) {
        openStore() // a write before the first refresh must not be lost
        store?.alertDefaults = d
        commit(.alertDefaults(d))
    }

    /// Show or hide a calendar on this person's screens.
    public func setVisible(_ calendar: CalCalendar, _ visible: Bool) {
        openStore() // a write before the first refresh must not be lost
        store?.updateCalendar(calendar.id) { $0.visible = visible }
        commit(.pref(calendarID: calendar.id, visible: visible, color: calendar.prefColor))
    }

    /// This person's color for a calendar (`.none` = the owner's).
    public func setColor(_ calendar: CalCalendar, _ color: CalColor) {
        openStore() // a write before the first refresh must not be lost
        store?.updateCalendar(calendar.id) { $0.prefColor = color }
        commit(.pref(calendarID: calendar.id, visible: calendar.visible, color: color))
    }

    // MARK: owner

    public func renameOwnCalendar(_ name: String?, color: CalColor?) {
        openStore() // a write before the first refresh must not be lost
        guard let own = ownCalendar else { return }
        store?.updateCalendar(own.id) { c in
            if let name { c.name = name }
            if let color { c.color = color }
        }
        commit(.updateCalendar(name: name, color: color))
    }

    @discardableResult
    public func saveLabel(id: UUID = UUID(), name: String, color: CalColor) -> CalLabel? {
        openStore() // a write before the first refresh must not be lost
        guard let own = ownCalendar else { return nil }
        let l = CalLabel(id: id, calendarID: own.id, name: name, color: color, rev: 0)
        store?.putLabel(l)
        commit(.saveLabel(l))
        return l
    }

    public func deleteLabel(_ label: CalLabel) {
        openStore() // a write before the first refresh must not be lost
        guard let store else { return }
        store.removeLabel(label.id)
        for e in store.allEvents() where e.fields.labelID == label.id {
            var c = e
            c.fields.labelID = nil
            store.put(c, pending: store.isPending(e.id))
        }
        commit(.deleteLabel(id: label.id, calendarID: label.calendarID))
    }

    // Sharing is online-only: it needs the server's answer (who, whether allowed).

    public func contacts() async throws -> [CalContact] { try await transport.listContacts() }
    public func grants() async throws -> [CalGrant] { try await transport.listGrants() }

    @discardableResult
    public func share(with person: UUID, role: CalRole = .view, until: Date? = nil, note: String = "") async throws -> CalGrant {
        try await transport.createGrant(granteeID: person, role: role, expiresAt: until, label: note)
    }

    public func revoke(_ grant: CalGrant) async throws { try await transport.revokeGrant(id: grant.id) }

    public func activity(cursor: String? = nil, limit: Int = 50) async throws -> (rows: [CalActivity], next: String?) {
        try await transport.listActivity(cursor: cursor, limit: limit)
    }

    static func describe(_ e: CalTransportError) -> String {
        switch e {
        case .notAuthenticated: return "Couldn't verify — try again"
        case .unavailable: return "Can't reach the calendar right now"
        case .serverFailed: return "The calendar server is having trouble"
        case .slowDown: return "Too many changes at once — trying again shortly"
        default: return "Couldn't sync"
        }
    }
}
