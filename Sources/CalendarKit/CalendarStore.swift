import Foundation
import SwiftData
import os

private let log = Logger(subsystem: "CalendarKit", category: "store")

// The store's versioned schema. Rule (the host app's, for any App-Group
// SwiftData store): never reshape a shipped @Model in place. To change one,
// freeze it as a nested @Model inside CalendarSchemaV1 (same class name), add
// CalendarSchemaV2 with the live model, and add a MigrationStage.
//
// Events are kept as their encoded `CalEvent` (Codable, so new fields can be
// added with defaults) plus a few plain columns for queries. Nothing here is
// the truth: the server is. The whole store can be wiped and rebuilt by a sync.
enum CalendarSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [CalendarRecord.self, EventRecord.self, LabelRecord.self, AlertRecord.self,
         SyncStateRecord.self, PendingWriteRecord.self]
    }
}

enum CalendarMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CalendarSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

@Model
final class CalendarRecord {
    @Attribute(.unique) var id: UUID
    var payload: Data      // CalCalendar
    var cursor: Int64      // how far this device has synced it
    var position: Int      // the server's order (own first)
    /// While a paged full load is under way: the rev it started at (0 = none).
    /// Defaulted so existing (Lab) stores migrate automatically.
    var loadFrom: Int64 = 0

    init(id: UUID, payload: Data, cursor: Int64, position: Int) {
        self.id = id
        self.payload = payload
        self.cursor = cursor
        self.position = position
    }
}

@Model
final class EventRecord {
    @Attribute(.unique) var id: UUID
    var calendarID: UUID
    var masterID: UUID?
    var payload: Data      // CalEvent
    /// Day numbers (yyyymmdd) for range queries: the first day, and the last
    /// day it can touch (a series: its until, or Int.max when open-ended).
    var firstDay: Int
    var lastDay: Int
    /// Local changes are waiting to reach the server: a sync mustn't overwrite them.
    var pending: Bool

    init(_ e: CalEvent, payload: Data, pending: Bool) {
        id = e.id
        calendarID = e.calendarID
        masterID = e.masterID
        self.payload = payload
        (firstDay, lastDay) = EventRecord.span(e)
        self.pending = pending
    }

    static func dayNumber(_ d: CalDate) -> Int { d.year * 10_000 + d.month * 100 + d.day }

    static func span(_ e: CalEvent) -> (Int, Int) {
        let first = e.fields.when.firstDay
        var last: CalDate
        switch e.fields.when {
        case .allDay(_, let end): last = end.adding(days: -1)
        case .timed(_, let end, let tz):
            // A day either side: the viewer's zone can differ from the event's.
            last = CalDate(end, in: TimeZone(identifier: tz) ?? .gmt).adding(days: 1)
        }
        if let r = e.fields.recurrence, e.masterID == nil {
            // A counted series ends at its last occurrence: store that, so a
            // finished "10 sessions" isn't fetched and expanded forever (R50).
            let end = r.until ?? r.count.flatMap { CalRecurrenceExpander.dates(r, first: first, limit: $0).last }
            guard let end else { return (dayNumber(first.adding(days: -1)), .max) }
            last = end.adding(days: first.days(to: last) + 1)
        }
        return (dayNumber(first.adding(days: -1)), dayNumber(last))
    }
}

@Model
final class LabelRecord {
    @Attribute(.unique) var id: UUID
    var calendarID: UUID
    var payload: Data      // CalLabel

    init(id: UUID, calendarID: UUID, payload: Data) {
        self.id = id
        self.calendarID = calendarID
        self.payload = payload
    }
}

@Model
final class AlertRecord {
    @Attribute(.unique) var eventID: UUID
    var payload: Data      // CalAlert

    init(eventID: UUID, payload: Data) {
        self.eventID = eventID
        self.payload = payload
    }
}

/// One row: the alerts cursor and the person's alert defaults.
@Model
final class SyncStateRecord {
    var alertsCursor: Int64
    var defaults: Data     // CalAlertDefaults
    var lastSync: Date?

    init(alertsCursor: Int64, defaults: Data) {
        self.alertsCursor = alertsCursor
        self.defaults = defaults
    }
}

/// A write made on this device, not yet confirmed by the server. Replayed in
/// `seq` order.
@Model
final class PendingWriteRecord {
    @Attribute(.unique) var id: UUID
    var seq: Int64
    var payload: Data      // PendingWrite
    var attempts: Int
    /// Internal server failures only (being offline doesn't count toward
    /// giving up). Defaulted so existing (Lab) stores migrate automatically.
    var serverFailures: Int = 0
    var createdAt: Date

    init(id: UUID, seq: Int64, payload: Data) {
        self.id = id
        self.seq = seq
        self.payload = payload
        attempts = 0
        createdAt = Date()
    }
}

/// A write waiting for the server.
enum PendingWrite: Codable, Equatable, Sendable {
    case create(CalEvent)
    case exception(CalEvent)
    case update(id: UUID, baseRev: Int64, fields: CalEventFields)
    /// calendarID: where it was, so a refusal can reload that calendar (the
    /// local copy is already gone by then). Optional so queues stored before it
    /// still decode.
    case delete(id: UUID, baseRev: Int64, calendarID: UUID? = nil)
    /// discardNew: "delete this and all future" (the tail is deleted at once).
    case split(masterID: UUID, baseRev: Int64, at: CalOriginalStart, newSeries: CalEvent, discardNew: Bool)
    case alerts(eventID: UUID, minutes: [Int])
    case alertDefaults(CalAlertDefaults)
    case pref(calendarID: UUID, visible: Bool, color: CalColor)
    case saveLabel(CalLabel)
    case deleteLabel(id: UUID, calendarID: UUID)
    case updateCalendar(name: String?, color: CalColor?)

    /// The event this write is about, if any (to mark it pending).
    var eventID: UUID? {
        switch self {
        case .create(let e), .exception(let e): return e.id
        case .update(let id, _, _), .delete(let id, _, _): return id
        case .split(let m, _, _, _, _): return m
        default: return nil
        }
    }

    /// The calendar to reload from the server if the write is refused.
    func calendarID(lookup: (UUID) -> UUID?) -> UUID? {
        switch self {
        case .create(let e), .exception(let e): return e.calendarID
        case .update(let id, _, _): return lookup(id)
        case .delete(let id, _, let c): return c ?? lookup(id)
        case .split(_, _, _, let s, _): return s.calendarID
        case .saveLabel(let l): return l.calendarID
        case .deleteLabel(_, let c): return c
        default: return nil
        }
    }
}

/// The local cache: one SwiftData store per user (`Calendar-<uid>.store`), in
/// the host's App Group when given. Main-actor confined.
@MainActor
final class CalendarStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userID: UUID, appGroup: String?, inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: CalendarSchemaV1.self)
        let name = "Calendar-\(userID.uuidString)"
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        } else if let appGroup,
                  let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            config = ModelConfiguration(name, schema: schema, url: base.appending(path: "\(name).store"))
        } else {
            config = ModelConfiguration(name, schema: schema)
        }
        container = try ModelContainer(for: schema, migrationPlan: CalendarMigrationPlan.self, configurations: config)
    }

    func encode<T: Encodable>(_ v: T) -> Data { (try? encoder.encode(v)) ?? Data() }
    func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? { try? decoder.decode(t, from: d) }

    /// Bumped by every change to cached events, so the engine can tell when
    /// occurrences it built are stale (R22).
    private(set) var eventChanges = 0

    func save() {
        do { try context.save() } catch { log.error("save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: calendars

    func calendars() -> [(CalCalendar, cursor: Int64)] {
        let rows = (try? context.fetch(FetchDescriptor<CalendarRecord>(sortBy: [SortDescriptor(\.position)]))) ?? []
        return rows.compactMap { r in decode(CalCalendar.self, r.payload).map { ($0, r.cursor) } }
    }

    func cursors() -> [UUID: CalCursor] {
        Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<CalendarRecord>())) ?? []).map {
            ($0.id, CalCursor(rev: $0.cursor, loadFrom: $0.loadFrom))
        })
    }

    private func calendarRecord(_ id: UUID) -> CalendarRecord? {
        try? context.fetch(FetchDescriptor<CalendarRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// The server's list of calendars: upsert in order; cursors are kept.
    func setCalendars(_ cals: [CalCalendar]) {
        for (i, c) in cals.enumerated() {
            if let r = calendarRecord(c.id) {
                r.payload = encode(c)
                r.position = i
            } else {
                context.insert(CalendarRecord(id: c.id, payload: encode(c), cursor: 0, position: i))
            }
        }
    }

    func setCursor(_ id: UUID, _ rev: Int64, loadFrom: Int64 = 0) {
        guard let r = calendarRecord(id) else { return }
        r.cursor = rev
        r.loadFrom = loadFrom
    }

    /// Make the next sync reload this calendar from scratch.
    func resetCursor(_ id: UUID) { setCursor(id, 0) }

    func updateCalendar(_ id: UUID, _ change: (inout CalCalendar) -> Void) {
        guard let r = calendarRecord(id), var c = decode(CalCalendar.self, r.payload) else { return }
        change(&c)
        r.payload = encode(c)
    }

    /// A calendar the person can no longer see: drop it and everything in it.
    func removeCalendar(_ id: UUID) {
        eventChanges += 1
        if let r = calendarRecord(id) { context.delete(r) }
        try? context.delete(model: EventRecord.self, where: #Predicate { $0.calendarID == id })
        try? context.delete(model: LabelRecord.self, where: #Predicate { $0.calendarID == id })
    }

    // MARK: events

    func event(_ id: UUID) -> CalEvent? { eventRecord(id).flatMap { decode(CalEvent.self, $0.payload) } }

    private func eventRecord(_ id: UUID) -> EventRecord? {
        try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.id == id })).first
    }

    /// Write an event (pending = a local change the server hasn't confirmed).
    func put(_ e: CalEvent, pending: Bool) {
        eventChanges += 1
        if let r = eventRecord(e.id) {
            r.payload = encode(e)
            r.calendarID = e.calendarID
            r.masterID = e.masterID
            (r.firstDay, r.lastDay) = EventRecord.span(e)
            r.pending = pending
        } else {
            context.insert(EventRecord(e, payload: encode(e), pending: pending))
        }
    }

    func isPending(_ id: UUID) -> Bool { eventRecord(id)?.pending ?? false }

    /// Apply a sync page's events in one fetch (not two per event, R48):
    /// tombstones remove, the rest upsert; events with local changes still
    /// waiting, or in `skip`, are left alone.
    func applyServerEvents(_ events: [CalEvent], skip: Set<UUID>) {
        guard !events.isEmpty else { return }
        eventChanges += 1
        let ids = events.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        var byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in events where !skip.contains(e.id) {
            let r = byID[e.id]
            if r?.pending == true { continue }
            if e.deleted {
                if let r { context.delete(r); byID[e.id] = nil }
            } else if let r {
                r.payload = encode(e)
                r.calendarID = e.calendarID
                r.masterID = e.masterID
                (r.firstDay, r.lastDay) = EventRecord.span(e)
            } else {
                let n = EventRecord(e, payload: encode(e), pending: false)
                context.insert(n)
                byID[e.id] = n
            }
        }
    }

    /// Make the pending flags match the queue: only rows flagged now or about
    /// to be are touched, no payload decoded (R24).
    func syncPendingFlags(waiting: Set<UUID>) {
        let flagged = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.pending }))) ?? []
        for r in flagged where !waiting.contains(r.id) { r.pending = false }
        guard !waiting.isEmpty else { return }
        let ids = Array(waiting)
        let rows = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for r in rows where !r.pending { r.pending = true }
    }

    func setPending(_ id: UUID, _ pending: Bool) { eventRecord(id)?.pending = pending }

    func removeEvent(_ id: UUID) {
        eventChanges += 1
        if let r = eventRecord(id) { context.delete(r) }
    }

    /// Remove a series' exceptions (not pending ones).
    func removeExceptions(of master: UUID) {
        eventChanges += 1
        try? context.delete(model: EventRecord.self, where: #Predicate { $0.masterID == master && !$0.pending })
    }

    /// Before a full load of a calendar: forget what the server will resend
    /// (local pending changes stay).
    func clearForReload(_ calendarID: UUID) {
        eventChanges += 1
        try? context.delete(model: EventRecord.self, where: #Predicate { $0.calendarID == calendarID && !$0.pending })
        try? context.delete(model: LabelRecord.self, where: #Predicate { $0.calendarID == calendarID })
    }

    /// Events of these calendars that can touch [from, through] (day numbers).
    func events(in calendars: [UUID], from: CalDate, through: CalDate) -> [CalEvent] {
        let lo = EventRecord.dayNumber(from), hi = EventRecord.dayNumber(through)
        let ids = calendars
        let rows = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate {
            ids.contains($0.calendarID) && $0.firstDay <= hi && $0.lastDay >= lo
        }))) ?? []
        return rows.compactMap { decode(CalEvent.self, $0.payload) }
    }

    /// Events by id (the series of exceptions found by their own days).
    func events(ids: Set<UUID>) -> [CalEvent] {
        let wanted = Array(ids)
        let rows = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { wanted.contains($0.id) }))) ?? []
        return rows.compactMap { decode(CalEvent.self, $0.payload) }
    }

    /// Exceptions of the given series (for expansion).
    func exceptions(of masters: [UUID]) -> [CalEvent] {
        let ids = Set(masters)
        let rows = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.masterID != nil }))) ?? []
        return rows.filter { $0.masterID.map(ids.contains) ?? false }.compactMap { decode(CalEvent.self, $0.payload) }
    }

    func allEvents() -> [CalEvent] {
        ((try? context.fetch(FetchDescriptor<EventRecord>())) ?? []).compactMap { decode(CalEvent.self, $0.payload) }
    }

    // MARK: labels

    func labels() -> [CalLabel] {
        ((try? context.fetch(FetchDescriptor<LabelRecord>())) ?? []).compactMap { decode(CalLabel.self, $0.payload) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func putLabel(_ l: CalLabel) {
        let id = l.id
        if let r = try? context.fetch(FetchDescriptor<LabelRecord>(predicate: #Predicate { $0.id == id })).first {
            r.payload = encode(l)
        } else {
            context.insert(LabelRecord(id: l.id, calendarID: l.calendarID, payload: encode(l)))
        }
    }

    func removeLabel(_ id: UUID) {
        try? context.delete(model: LabelRecord.self, where: #Predicate { $0.id == id })
    }

    // MARK: alerts + state

    func alerts() -> [UUID: [Int]] {
        let rows = (try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { r in decode(CalAlert.self, r.payload).map { (r.eventID, $0.minutesBefore) } })
    }

    func putAlert(_ a: CalAlert) {
        let id = a.eventID
        if let r = try? context.fetch(FetchDescriptor<AlertRecord>(predicate: #Predicate { $0.eventID == id })).first {
            r.payload = encode(a)
        } else {
            context.insert(AlertRecord(eventID: a.eventID, payload: encode(a)))
        }
    }

    private func state() -> SyncStateRecord {
        if let s = try? context.fetch(FetchDescriptor<SyncStateRecord>()).first { return s }
        let s = SyncStateRecord(alertsCursor: 0, defaults: encode(CalAlertDefaults()))
        context.insert(s)
        return s
    }

    var alertsCursor: Int64 {
        get { state().alertsCursor }
        set { state().alertsCursor = newValue }
    }

    var alertDefaults: CalAlertDefaults {
        get { decode(CalAlertDefaults.self, state().defaults) ?? CalAlertDefaults() }
        set { state().defaults = encode(newValue) }
    }

    var lastSync: Date? {
        get { state().lastSync }
        set { state().lastSync = newValue }
    }

    // MARK: pending writes

    func pending() -> [(UUID, PendingWrite)] {
        let rows = (try? context.fetch(FetchDescriptor<PendingWriteRecord>(sortBy: [SortDescriptor(\.seq)]))) ?? []
        return rows.compactMap { r in decode(PendingWrite.self, r.payload).map { (r.id, $0) } }
    }

    var pendingCount: Int { (try? context.fetchCount(FetchDescriptor<PendingWriteRecord>())) ?? 0 }

    func enqueue(_ w: PendingWrite) {
        let last = (try? context.fetch(FetchDescriptor<PendingWriteRecord>(sortBy: [SortDescriptor(\.seq, order: .reverse)])).first?.seq) ?? 0
        context.insert(PendingWriteRecord(id: UUID(), seq: last + 1, payload: encode(w)))
    }

    func replacePending(_ id: UUID, with w: PendingWrite) {
        if let r = try? context.fetch(FetchDescriptor<PendingWriteRecord>(predicate: #Predicate { $0.id == id })).first {
            r.payload = encode(w)
        }
    }

    func dropPending(_ id: UUID) {
        try? context.delete(model: PendingWriteRecord.self, where: #Predicate { $0.id == id })
    }

    func serverFailures(_ id: UUID) -> Int {
        (try? context.fetch(FetchDescriptor<PendingWriteRecord>(predicate: #Predicate { $0.id == id })).first?.serverFailures) ?? 0
    }

    func bumpServerFailures(_ id: UUID) {
        if let r = try? context.fetch(FetchDescriptor<PendingWriteRecord>(predicate: #Predicate { $0.id == id })).first {
            r.serverFailures += 1
        }
    }

    func bumpAttempts(_ id: UUID) {
        if let r = try? context.fetch(FetchDescriptor<PendingWriteRecord>(predicate: #Predicate { $0.id == id })).first {
            r.attempts += 1
        }
    }

    /// Sign-out: delete everything.
    func wipeAll() {
        eventChanges += 1
        try? context.delete(model: CalendarRecord.self)
        try? context.delete(model: EventRecord.self)
        try? context.delete(model: LabelRecord.self)
        try? context.delete(model: AlertRecord.self)
        try? context.delete(model: SyncStateRecord.self)
        try? context.delete(model: PendingWriteRecord.self)
        save()
    }
}
