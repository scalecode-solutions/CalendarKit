import Foundation
import UIKit
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

    /// The person's pair calendars, one per friend, by the other person's name:
    /// those on the server, and, for friends nobody has opened one with yet,
    /// one shown from the contact list at its computed id (`listed` false).
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

    public init(config: CalendarConfig, transport: (any CalendarTransport)? = nil) {
        self.config = config
        self.transport = transport ?? config.transport
    }

    /// Pairs the person may add to: every one that isn't frozen.
    public var writableCalendars: [CalCalendar] { calendars.filter { !$0.frozen } }

    /// The person's pair calendar with someone (shown even before it exists on
    /// the server), if they're a friend or were.
    public func pair(with person: UUID) -> CalCalendar? { calendars.first { $0.otherID == person } }

    /// The person's own color, the kit's accent. Kept on this device.
    public var myColor: CalColor = CalendarEngine.storedMyColor() {
        didSet {
            UserDefaults.standard.set(myColor.rawValue, forKey: Self.myColorKey)
            publish()
        }
    }
    static let myColorKey = "CalendarKit.myColor"
    static func storedMyColor() -> CalColor {
        CalColor(rawValue: UserDefaults.standard.string(forKey: myColorKey) ?? "") ?? .none
    }

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
    /// still in flight may refresh or write to the cache, or
    /// the signed-out person's calendar comes back (R16).
    private(set) var isWiped = false
    /// Bumped by wipeLocalStore(): a write that lands afterwards mustn't touch
    /// the (wiped) cache.
    private var wipes = 0

    /// Sign-out: stop, then delete the cache (and queued writes) for this user.
    public func wipeLocalStore() {
        stop()
        wipes += 1
        // Open (if this launch never did) and wipe BEFORE marking the engine
        // signed out: openStore() refuses once isWiped is set, and a sign-out
        // that never opened the store left the last person's cache on disk.
        if store == nil { openStore() }
        if let store, storeOnDisk {
            store.wipeAll()
        } else {
            // The store on disk isn't the one open (it wouldn't open, as while
            // the phone is locked): delete its files by path instead. Wiping
            // an in-memory stand-in left the real cache behind.
            store = nil
            CalendarStore.deleteFiles(userID: config.currentUserID, appGroup: config.appGroup,
                                      directory: config.storeDirectory, inMemory: storeInMemory)
        }
        store = nil
        storeOnDisk = false
        isWiped = true
        calendars = []
        labels = []
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

    /// Whether `store` is the user's real store (on disk, or the in-memory
    /// one tests ask for), not a stand-in after a failed open.
    private var storeOnDisk = false
    /// Whether the phone's protected files can be read now. A seam for tests.
    var protectedDataAvailable: @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    private var lockedNoticeShown = false

    /// Whether a change can be saved now: the store is open (or opens). False
    /// while the phone is locked and the store's files are protected; the
    /// editor keeps its sheet open then, rather than lose the change.
    public func canSave() -> Bool {
        openStore()
        return store != nil
    }

    private func openStore() {
        guard store == nil, !isWiped else { return }
        do {
            let opened = try CalendarStore(userID: config.currentUserID, appGroup: config.appGroup,
                                           directory: config.storeDirectory, inMemory: storeInMemory)
            // From before pair calendars (0.7.0): its calendars and queued
            // writes can't be read, and their server rows are gone too.
            if opened.holdsAnOldModel() {
                log.notice("store held the per-person model: wiped for pair calendars")
                opened.wipeAll()
            }
            store = opened
            storeOnDisk = true
            lockedNoticeShown = false
        } catch {
            log.error("store failed to open: \(error.localizedDescription, privacy: .public)")
            guard protectedDataAvailable() else {
                // Locked: its files can't be read yet. Stay closed and try again
                // on the next refresh or write, rather than an in-memory store
                // that would swallow this launch's writes.
                if !lockedNoticeShown {
                    lockedNoticeShown = true
                    notices.append(CalNotice(message: "Unlock your phone to use the calendar."))
                }
                return
            }
            // A store that won't open while unlocked (damaged): carry on in
            // memory for this launch, and sync refills it.
            store = try? CalendarStore(userID: config.currentUserID, appGroup: nil, inMemory: true)
            storeOnDisk = false
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
        if store.privateChanges != publishedPrivateChanges { publishedPrivateChanges = store.privateChanges; changed = true }
        // Automatic colors before the comparison, so an unchanged list still
        // compares equal and doesn't rebuild the views. New or changed ones are
        // remembered, so the next friend doesn't move them.
        let stored = store.calendars().map(\.0)
        // Friends nobody has opened a pair with yet: shown at the pair's id.
        let me = config.currentUserID
        let have = Set(stored.map(\.otherID))
        var unopened: [CalCalendar] = []
        for p in people.values where p.id != me && !have.contains(p.id) {
            var c = CalCalendar(id: CalPairID.make(me, p.id), otherID: p.id)
            c.listed = false
            unopened.append(c)
        }
        let all = (stored + unopened).sorted {
            (displayName($0).lowercased(), $0.id.uuidString) < (displayName($1).lowercased(), $1.id.uuidString)
        }
        let cals = CalCalendar.assignAutoColors(all, own: myColor)
        for now in cals where stored.contains(where: { $0.id == now.id && $0.autoColor != now.autoColor }) {
            store.updateCalendar(now.id) { $0.autoColor = now.autoColor }
        }
        if cals != calendars { calendars = cals; changed = true }
        let visible = Set(cals.map(\.id))
        let ls = store.labels().filter { visible.contains($0.calendarID) }
        if ls != labels { labels = ls; changed = true }
        let pc = store.pendingCount
        if pc != pendingCount { pendingCount = pc; changed = true }
        if changed { revision += 1 }
    }
    private var publishedEventChanges = -1
    private var publishedPrivateChanges = -1

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
        publish() // friends without a pair yet show up as pairs
    }

    /// What to call a pair: its own name, else the other person's, else
    /// "Someone" (a friend no longer, or an account gone).
    public func displayName(_ c: CalCalendar) -> String {
        if !c.name.isEmpty { return c.name }
        if let p = people[c.otherID], !p.name.isEmpty { return p.name }
        return "Someone"
    }

    /// The other person in a pair, if the directory knows them (nil for
    /// someone who isn't a friend any more).
    public func person(of c: CalCalendar) -> CalContact? { people[c.otherID] }

    // MARK: reading

    /// What to draw between two days (inclusive), in the viewer's zone, from
    /// the pairs they've chosen to show (pass `includeHidden` for all). `only`
    /// narrows it to some pairs, hidden or not (a focused pair still shows);
    /// `byAuthor` colors by who added each event (inside one pair).
    public func occurrences(from: CalDate, through: CalDate, zone: TimeZone = .current,
                            includeHidden: Bool = false, only: Set<UUID>? = nil,
                            byAuthor: Bool = false) -> [CalOccurrence] {
        guard let store else { return [] }
        // Built once per (cache contents, published state, range): a view body
        // pass that only moved the selection, or a sync that changed nothing,
        // reuses it (R22).
        let key = OccurrenceKey(events: store.eventChanges, revision: revision, from: from, through: through,
                                zone: zone.identifier, hidden: includeHidden, only: only, byAuthor: byAuthor)
        if let hit = occurrenceCache[key] { return hit }
        if let any = occurrenceCache.keys.first, any.events != key.events || any.revision != key.revision {
            occurrenceCache.removeAll(keepingCapacity: true)
        }
        if occurrenceCache.count >= 8 { occurrenceCache.removeAll(keepingCapacity: true) }
        let built = buildOccurrences(store, from: from, through: through, zone: zone, includeHidden: includeHidden,
                                     only: only, byAuthor: byAuthor)
        occurrenceCache[key] = built
        return built
    }

    private struct OccurrenceKey: Hashable {
        let events: Int, revision: Int
        let from: CalDate, through: CalDate
        let zone: String, hidden: Bool
        let only: Set<UUID>?, byAuthor: Bool
    }
    private var occurrenceCache: [OccurrenceKey: [CalOccurrence]] = [:]

    private func buildOccurrences(_ store: CalendarStore, from: CalDate, through: CalDate, zone: TimeZone,
                                  includeHidden: Bool, only: Set<UUID>?, byAuthor: Bool) -> [CalOccurrence] {
        let cals = calendars.filter { c in only.map { $0.contains(c.id) } ?? (includeHidden || c.visible) }
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
                                       from: from, through: through, zone: zone,
                                       byAuthor: byAuthor ? (config.currentUserID, accentColor) : nil)
    }

    public func event(_ id: UUID) -> CalEvent? { store?.event(id) }

    public func calendar(_ id: UUID) -> CalCalendar? { calendars.first { $0.id == id } }

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
                let page = try await transport.sync(cursors: store.cursors())
                guard gen == generation else { return }
                apply(page, to: store)
                store.save()
                publish()
                // More of a calendar (or calendars the server didn't get to):
                // ask again.
                if !page.deltas.contains(where: { $0.hasMore || $0.privateDelta.hasMore || $0.cycleDelta.hasMore }) { break }
            }
            store.lastSync = Date()
            moveLegacyDefaults()
            store.save()
            lastError = nil
            loadState = .loaded
            await loadPeopleIfStale()
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
        // A pair this device started on that the server hasn't listed yet
        // stays: its OpenPair is still queued.
        for (c, _) in store.calendars() where !now.contains(c.id) && c.listed {
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
            // A delta that only carries the private stream leaves events alone.
            let heldRev = held[d.calendarID]?.rev ?? 0
            if !d.reload && d.events.isEmpty && d.labels.isEmpty && d.deletedLabelIDs.isEmpty && d.rev == heldRev {
                applyPrivate(d.privateDelta, calendarID: d.calendarID, held: held[d.calendarID]?.intimate ?? 0, store: store)
                applyCycle(d.cycleDelta, calendarID: d.calendarID, store: store)
                continue
            }
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
            applyPrivate(d.privateDelta, calendarID: d.calendarID, held: held[d.calendarID]?.intimate ?? 0, store: store)
            applyCycle(d.cycleDelta, calendarID: d.calendarID, store: store)
        }
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
        case .pref(let id, let visible, let color):
            try await transport.setCalendarPref(calendarID: id, visible: visible, color: color)
        case .saveLabel(let l):
            store.putLabel(try live(try await transport.saveLabel(id: l.id, calendarID: l.calendarID, name: l.name, color: l.color)))
        case .deleteLabel(let id, _):
            try await transport.deleteLabel(id: id)
        case .savePrivate(let e, let base):
            let saved = try live(try await transport.savePrivateEntry(e, baseRev: base))
            // Later queued saves of the same entry were built on this one.
            for (qpid, q) in store.pending() where qpid != pid {
                if case .savePrivate(let qe, _) = q, qe.id == e.id { store.replacePending(qpid, with: .savePrivate(qe, baseRev: saved.rev)) }
                if case .deletePrivate(let qid, _, let c) = q, qid == e.id { store.replacePending(qpid, with: .deletePrivate(id: qid, baseRev: saved.rev, calendarID: c)) }
            }
            let waiting = store.pending().contains { (qpid, q) in
                if case .savePrivate(let qe, _) = q, qe.id == e.id, qpid != pid { return true }
                return false
            }
            if !waiting { store.putPrivate(saved, pending: false) }
        case .deletePrivate(let id, let base, _):
            do { _ = try await transport.deletePrivateEntry(id: id, baseRev: base) } catch CalTransportError.notFound {}
            _ = try live(())
            store.removePrivate(id)
        case .savePartner(let p):
            store.putPartner(try live(try await transport.savePartner(p)))
        case .saveCycleDay(let d):
            store.putCycleDay(try live(try await transport.saveCycleDay(d)))
        case .deleteCycleDay(let id, _):
            do { _ = try await transport.deleteCycleDay(id: id) } catch CalTransportError.notFound {}
            _ = try live(())
            store.removePrivate(id)
        case .saveCycleSettings(let st):
            store.putCycleSettings(try live(try await transport.saveCycleSettings(st)))
        case .consent(let id, let kind, let on):
            let c = try live(try await transport.setConsent(calendarID: id, kind: kind, on: on))
            store.updateCalendar(id) { local in
                var n = c
                n.autoColor = local.autoColor
                n.intimateCursor = local.intimateCursor
                n.cycleCursor = local.cycleCursor
                local = n
            }
        case .openPair(let other, let id):
            let c = try live(try await transport.openPair(otherID: other))
            guard c.id == id else { throw CalTransportError.badResponse("the pair's id isn't the one computed") }
            // Listed from now on; this device's colour and the local prefs stay.
            store.updateCalendar(id) { local in
                var n = c
                n.autoColor = local.autoColor
                n.visible = local.visible
                n.prefColor = local.prefColor
                local = n
            }
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
            message = "You two aren't friends any more, so this calendar can't be changed: \(what) wasn't saved."
        case .notFound? where isPrivateWrite(w):
            message = "Intimate entries are on only when you both turn them on, so that wasn't saved."
        case .notFound? where isOpenPair(w):
            message = "You can't keep a calendar with this person right now, so your changes weren't saved."
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
        // A pair that can't be written (frozen) or opened (not friends): every
        // write queued for it would be refused the same way. Drop them all now,
        // with this one notice, not one per write.
        if let cal = w.calendarID(lookup: { store.event($0)?.calendarID }),
           (error as? CalTransportError).map({ if case .forbidden = $0 { return true }; return isOpenPair(w) }) == true {
            for (pid, other) in store.pending() where other.calendarID(lookup: { store.event($0)?.calendarID }) == cal {
                // A frozen pair still takes the person's own prefs (hiding it
                // is the point), so those stay queued; a pair that was never
                // opened takes nothing.
                if case .pref = other, !isOpenPair(w) { continue }
                store.dropPending(pid)
                if case .create(let e) = other { store.removeEvent(e.id) }
                if case .exception(let e) = other { store.removeEvent(e.id) }
            }
            if isOpenPair(w) { store.removeCalendar(cal) } // never on the server: nothing to keep
        }
        notices.append(CalNotice(message: message))
        switch w {
        case .savePrivate(let e, let base) where base == 0:
            store.removePrivate(e.id) // it never existed on the server
        case .savePrivate(let e, _):
            // Refused for good (someone changed it first): stop holding the
            // local version and reload the pair's private stream, so the
            // server's copy lands (Leaf's test, PrivateDataTests).
            if let local = store.privateEntry(e.id) { store.putPrivate(local, pending: false) }
            store.setPrivateCursor(e.calendarID, 0)
        case .deletePrivate(_, _, let cal):
            store.setPrivateCursor(cal, 0)
        // The rest of the private stream, the same way (Torsion's review,
        // MVCALE-28): a new row that was refused never existed on the server,
        // so it goes; a changed one is reloaded from the server's copy.
        case .savePartner(let p) where p.rev == 0:
            store.removePrivate(p.id)
        case .savePartner(let p):
            store.setPrivateCursor(p.calendarID, 0)
        case .saveCycleDay(let d) where d.rev == 0:
            store.removePrivate(d.id)
        case .saveCycleDay(let d):
            store.setCycleCursor(d.calendarID, 0)
        case .deleteCycleDay(_, let cal):
            store.setCycleCursor(cal, 0)
        case .saveCycleSettings(let st) where st.rev == 0:
            store.removePrivate(CalendarStore.settingsID(st))
        case .saveCycleSettings(let st):
            store.setCycleCursor(st.calendarID, 0)
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

    /// One calendar's cycle changes: a reset drops its cycle rows; else
    /// tombstones go, the rest is upserted, and the cycle cursor moves on.
    private func applyCycle(_ d: CalCycleDelta, calendarID: UUID, store: CalendarStore) {
        if d.reset {
            store.clearCycle(calendarID)
            return
        }
        for day in d.days {
            if day.deleted { store.removePrivate(day.id) } else { store.putCycleDay(day) }
        }
        for st in d.settings { store.putCycleSettings(st) }
        if d.rev > 0 { store.setCycleCursor(calendarID, d.rev) }
    }

    private func isPrivateWrite(_ w: PendingWrite) -> Bool {
        switch w {
        case .savePrivate, .deletePrivate, .savePartner, .saveCycleDay, .deleteCycleDay, .saveCycleSettings: return true
        default: return false
        }
    }

    private func isOpenPair(_ w: PendingWrite) -> Bool {
        if case .openPair = w { return true }
        return false
    }

    /// One calendar's private changes: a reset drops everything held for it;
    /// else tombstones go and the rest is upserted (a private row with a
    /// change still waiting is left alone), and the private cursor moves on.
    private func applyPrivate(_ d: CalPrivateDelta, calendarID: UUID, held: Int64, store: CalendarStore) {
        if d.reset {
            store.clearPrivate(calendarID)
            return
        }
        guard d.rev > 0 || !d.entries.isEmpty || !d.partners.isEmpty else { return }
        if held == 0 && d.rev > 0 && !d.hasMore { /* a full load: nothing older to keep */ }
        for e in d.entries {
            if e.deleted { store.removePrivate(e.id) }
            else if !store.isPrivatePending(e.id) { store.putPrivate(e, pending: false) }
        }
        for p in d.partners {
            if p.deleted { store.removePrivate(p.id) } else { store.putPartner(p) }
        }
        if d.rev > 0 { store.setPrivateCursor(calendarID, d.rev) }
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
        case .pref(let id, _, _):
            for (pid, q) in queued { if case .pref(id, _, _) = q { store.replacePending(pid, with: w); return } }
        default: break
        }
        store.enqueue(w)
    }

    /// Record a local change and push it soon.
    private func commit(_ w: PendingWrite) {
        guard let store else { return }
        // The first write (or pref) to a pair the server hasn't listed: open it
        // there first. Only then, never as a sweep over every friend: OpenPair
        // counts against the write budget.
        if let id = w.calendarID(lookup: { store.event($0)?.calendarID }),
           let pair = calendars.first(where: { $0.id == id }), !pair.listed,
           !store.pending().contains(where: { if case .openPair(_, id) = $0.1 { return true }; return false }) {
            store.putUnlistedPair(pair)
            enqueue(.openPair(otherID: pair.otherID, calendarID: id), store: store)
        }
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
    @discardableResult
    public func addEvent(to calendarID: UUID, _ fields: CalEventFields) -> CalEvent {
        openStore() // a write before the first refresh must not be lost
        let e = newEvent(calendarID: calendarID, fields: fields)
        store?.put(e, pending: true)
        commit(.create(e))
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

    /// Show or hide a calendar on this person's screens.
    public func setVisible(_ calendar: CalCalendar, _ visible: Bool) {
        openStore() // a write before the first refresh must not be lost
        if !calendar.listed { store?.putUnlistedPair(calendar) }
        store?.updateCalendar(calendar.id) { $0.visible = visible }
        commit(.pref(calendarID: calendar.id, visible: visible, color: calendar.prefColor))
    }

    /// Hide a pair from this person's screens (the other person never knows),
    /// or show it again. Nothing on it is deleted.
    public func setHidden(_ calendar: CalCalendar, _ hidden: Bool) { setVisible(calendar, !hidden) }

    /// This person's color for a pair (`.none` = automatic).
    public func setColor(_ calendar: CalCalendar, _ color: CalColor) {
        openStore() // a write before the first refresh must not be lost
        if !calendar.listed { store?.putUnlistedPair(calendar) }
        store?.updateCalendar(calendar.id) { $0.prefColor = color }
        commit(.pref(calendarID: calendar.id, visible: calendar.visible, color: color))
    }

    // MARK: labels

    @discardableResult
    public func saveLabel(id: UUID = UUID(), in calendar: CalCalendar, name: String, color: CalColor) -> CalLabel? {
        openStore() // a write before the first refresh must not be lost
        guard !calendar.frozen else { return nil }
        let l = CalLabel(id: id, calendarID: calendar.id, name: name, color: color, rev: 0)
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

    // MARK: private entries (0.8.0 design sprint, PROVISIONAL)

    /// The person's own consent for a kind on a pair. Intimate entries show
    /// only once both members have turned it on.
    public func setConsent(_ calendar: CalCalendar, _ kind: CalConsentKind, _ on: Bool) {
        openStore() // a write before the first refresh must not be lost
        if !calendar.listed { store?.putUnlistedPair(calendar) }
        store?.updateCalendar(calendar.id) { c in
            switch kind {
            case .intimate: c.intimateMine = on
            case .cycle: c.cycleMine = on
            }
        }
        commit(.consent(calendarID: calendar.id, kind: kind, on: on))
    }

    /// Add or change a private entry (shown at once, sent in order).
    public func savePrivate(_ entry: CalPrivateEntry) {
        openStore() // a write before the first refresh must not be lost
        guard let store else { return }
        var e = entry
        e.updatedBy = config.currentUserID
        let base = store.privateEntry(e.id)?.rev ?? 0
        store.putPrivate(e, pending: true)
        commit(.savePrivate(e, baseRev: base))
    }

    /// Log one now. Who is the person's default partner when they have one;
    /// else it's left to fill in later (a hollow heart).
    @discardableResult
    public func quickLog(in calendar: CalCalendar, at: Date = Date()) -> CalPrivateEntry {
        var content = CalPrivateContent(at: at)
        content.quickLog = true
        if let p = defaultPartner(in: calendar) { content.partnerIDs = [p] }
        let e = CalPrivateEntry(calendarID: calendar.id, content: content, createdBy: config.currentUserID)
        savePrivate(e)
        return e
    }

    public func deletePrivate(_ entry: CalPrivateEntry) {
        openStore() // a write before the first refresh must not be lost
        guard let store else { return }
        let base = store.privateEntry(entry.id)?.rev ?? entry.rev
        store.removePrivate(entry.id)
        commit(.deletePrivate(id: entry.id, baseRev: base, calendarID: entry.calendarID))
    }

    /// Add or change a name on a pair's partner list (shared by both).
    /// A new partner is the person's own; only its owner changes one (the
    /// server refuses anyone else, MVCALE-51).
    public func savePartner(_ partner: CalPartner) {
        openStore() // a write before the first refresh must not be lost
        var p = partner
        if p.ownerID == nil && store?.partners().contains(where: { $0.id == p.id }) != true {
            p.ownerID = config.currentUserID
        }
        store?.putPartner(p)
        commit(.savePartner(p))
    }

    /// The private entries the person may see: on pairs where both members
    /// consented, between two days (in the viewer's zone).
    public func privateEntries(from: CalDate, through: CalDate, zone: TimeZone = .current,
                               only: Set<UUID>? = nil) -> [CalPrivateEntry] {
        _ = revision
        guard let store else { return [] }
        let on = Set(calendars.filter { c in c.intimateOn && (only.map { $0.contains(c.id) } ?? c.visible) }.map(\.id))
        return store.privateEntries()
            .filter { on.contains($0.calendarID) && !$0.deleted }
            .filter { let d = $0.day(in: zone); return d >= from && d <= through }
            .sorted { $0.content.at < $1.content.at }
    }

    // MARK: cycle (0.8.0 design sprint, PROVISIONAL)

    /// Log (or change) a day of someone's cycle on a pair: either member may
    /// log for whoever tracks theirs there (the server refuses anyone else).
    public func logCycleDay(in calendar: CalCalendar, for person: UUID, on day: CalDate, flow: CalFlow) {
        openStore() // a write before the first refresh must not be lost
        guard let store, calendar.tracksCycle(person, me: config.currentUserID) else { return }
        let existing = store.cycleDays().first { $0.calendarID == calendar.id && $0.personID == person && $0.date == day && !$0.deleted }
        let d = CalCycleDay(id: existing?.id ?? UUID(), calendarID: calendar.id, personID: person, date: day, flow: flow,
                            rev: existing?.rev ?? 0)
        store.putCycleDay(d)
        commit(.saveCycleDay(d))
    }

    public func removeCycleDay(_ day: CalCycleDay) {
        openStore() // a write before the first refresh must not be lost
        store?.removePrivate(day.id)
        commit(.deleteCycleDay(id: day.id, calendarID: day.calendarID))
    }

    public func saveCycleSettings(_ settings: CalCycleSettings) {
        openStore() // a write before the first refresh must not be lost
        store?.putCycleSettings(settings)
        commit(.saveCycleSettings(settings))
    }

    /// Whose cycles a pair tracks: each member who has turned tracking on
    /// (MVCALE-51), you first.
    public func cyclePeople(in calendar: CalCalendar) -> [UUID] {
        _ = revision
        let me = config.currentUserID
        return [me, calendar.otherID].filter { calendar.tracksCycle($0, me: me) }
    }

    /// The estimator for one person's cycle on a pair (only while they track it).
    public func cycle(of person: UUID, in calendar: CalCalendar) -> CalCycleEstimator? {
        _ = revision
        guard calendar.tracksCycle(person, me: config.currentUserID), let store else { return nil }
        let days = store.cycleDays().filter { $0.calendarID == calendar.id && $0.personID == person }
        let settings = store.cycleSettings().first { $0.calendarID == calendar.id && $0.personID == person }
        return CalCycleEstimator(days: days, settings: settings)
    }

    /// The person's own default partner on a pair: new entries and quick logs
    /// start with it. Synced (MVCALE-51): it's a flag on the partner, so both
    /// phones know it. nil when unset or removed.
    public func defaultPartner(in calendar: CalCalendar) -> UUID? {
        defaultPartner(of: config.currentUserID, in: calendar)
    }

    /// Anyone's default on a pair: "Intimate for <name>" starts with theirs.
    public func defaultPartner(of person: UUID, in calendar: CalCalendar) -> UUID? {
        partners(of: calendar).first { $0.ownerID == person && $0.isDefault && !$0.archived }?.id
    }

    /// Make one of your partners your default (nil: none). Saved like any
    /// change to it; the server clears your previous default.
    public func setDefaultPartner(_ id: UUID?, in calendar: CalCalendar) {
        for p in myPartners(of: calendar) {
            let want = p.id == id && !p.archived
            guard p.isDefault != want else { continue }
            var q = p
            q.isDefault = want
            savePartner(q)
        }
    }

    /// Before defaults synced, they lived on the device (0.8.0): the first sync
    /// with the new build sends a stored one up once, then forgets it.
    static func legacyDefaultPartnerKey(_ me: UUID, _ pair: UUID) -> String {
        "CalendarKit.defaultPartner.\(me.uuidString.lowercased()).\(pair.uuidString.lowercased())"
    }

    private func moveLegacyDefaults() {
        let me = config.currentUserID
        for c in calendars where c.intimateOn && !c.frozen {
            let key = Self.legacyDefaultPartnerKey(me, c.id)
            guard let raw = UserDefaults.standard.string(forKey: key) else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            guard defaultPartner(in: c) == nil, let id = UUID(uuidString: raw),
                  myPartners(of: c).contains(where: { $0.id == id && !$0.archived }) else { continue }
            setDefaultPartner(id, in: c)
        }
    }

    /// The person's own partners on a pair (MVCALE-51): what the editor's
    /// Who, Privacy and the default offer. The other member's, and any from
    /// before partners had an owner, only name old entries (`partners(of:)`).
    public func myPartners(of calendar: CalCalendar) -> [CalPartner] {
        partners(of: calendar).filter { $0.ownerID == config.currentUserID }
    }

    /// Every partner on a pair, both members' (archived ones last): for
    /// naming entries and coloring hearts.
    public func partners(of calendar: CalCalendar) -> [CalPartner] {
        _ = revision
        return (store?.partners() ?? []).filter { $0.calendarID == calendar.id && !$0.deleted }
            .sorted { ($0.archived ? 1 : 0, $0.name.lowercased()) < ($1.archived ? 1 : 0, $1.name.lowercased()) }
    }

    /// A day's hearts (plan decision 9): one per author, the partner's color
    /// when every partner of the author's entries shares one, else the
    /// author's (the person's own accent, or the pair's color for the other's).
    public func hearts(_ entries: [CalPrivateEntry]) -> [CalHeart] {
        let partners = Dictionary((store?.partners() ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return CalHeart.hearts(entries, partners: partners) { e in
            e.subject == self.config.currentUserID ? self.accentColor
                : (self.calendar(e.calendarID)?.displayColor ?? .gray)
        }
    }

    // Online only: they need the server's answer.

    public func contacts() async throws -> [CalContact] { try await transport.listContacts() }

    /// A pair's history: both people's changes, newest first. Empty for a pair
    /// the server doesn't have yet.
    public func activity(of calendar: CalCalendar, cursor: String? = nil, limit: Int = 50) async throws -> (rows: [CalActivity], next: String?) {
        guard calendar.listed else { return ([], nil) }
        return try await transport.listActivity(calendarID: calendar.id, cursor: cursor, limit: limit)
    }

    static func describe(_ e: CalTransportError) -> String {
        switch e {
        case .notAuthenticated: return "Couldn't verify — try again"
        case .unavailable: return "Can't reach the calendar right now"
        case .serverFailed: return "The calendar server is having trouble"
        case .slowDown: return "Too many requests — trying again shortly"
        default: return "Couldn't sync"
        }
    }
}
