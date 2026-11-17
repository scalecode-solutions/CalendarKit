import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures, sorted by what the caller should do about them.
public enum CalTransportError: Error, Sendable, Equatable {
    /// No token, or the server rejected it: the host's session is gone.
    case notAuthenticated
    /// It doesn't exist, or the caller may not know it does.
    case notFound
    /// The calendar can't be changed now: its two people aren't friends any
    /// more (a frozen pair). The message is for people.
    case forbidden(String)
    /// Someone changed it first. `current` is the server's copy now.
    case conflict(current: CalEvent?)
    /// The request was refused as invalid (a message for people).
    case invalid(String)
    /// That id or occurrence is already taken.
    case exists(String)
    /// A cap was reached (events, labels).
    case limit
    /// Too many writes: try again shortly.
    case slowDown
    /// The server couldn't be reached: try again later (as long as it takes).
    case unavailable(String)
    /// The server answered with an internal failure: worth a few more tries,
    /// not forever (one write that always fails mustn't block the queue).
    case serverFailed(String)
    /// The server answered something this kit can't read.
    case badResponse(String)

    /// Worth trying again later unchanged (an offline write stays queued).
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .serverFailed, .slowDown, .notAuthenticated: return true
        default: return false
        }
    }
}

/// The kit's view of the server. A protocol so tests and previews can fake it.
public protocol CalendarTransport: Sendable {
    func sync(cursors: [UUID: CalCursor]) async throws -> CalSyncPage

    func createEvent(id: UUID, calendarID: UUID, fields: CalEventFields) async throws -> CalEvent
    /// An exception to one occurrence of a series (cancelled = removes it; then
    /// fields are ignored).
    func createException(id: UUID, calendarID: UUID, masterID: UUID, originalStart: CalOriginalStart,
                         fields: CalEventFields?, cancelled: Bool) async throws -> CalEvent
    func updateEvent(id: UUID, baseRev: Int64, fields: CalEventFields) async throws -> CalEvent
    /// Returns the delete's rev.
    func deleteEvent(id: UUID, baseRev: Int64) async throws -> Int64
    func splitSeries(masterID: UUID, baseRev: Int64, at originalStart: CalOriginalStart,
                     newID: UUID, fields: CalEventFields) async throws -> (old: CalEvent, new: CalEvent)

    func setCalendarPref(calendarID: UUID, visible: Bool, color: CalColor) async throws
    func listContacts() async throws -> [CalContact]

    /// Makes sure the caller's pair calendar with `otherID` exists on the
    /// server, and returns it (idempotent). NotFound when the two aren't friends.
    func openPair(otherID: UUID) async throws -> CalCalendar

    func saveLabel(id: UUID, calendarID: UUID, name: String, color: CalColor) async throws -> CalLabel
    func deleteLabel(id: UUID) async throws
    func listActivity(calendarID: UUID, cursor: String?, limit: Int) async throws -> (rows: [CalActivity], next: String?)

    // Private entries (0.8.0 design sprint, PROVISIONAL).
    /// Turns the caller's own consent for a kind on or off; returns the pair.
    func setConsent(calendarID: UUID, kind: CalConsentKind, on: Bool) async throws -> CalCalendar
    /// Creates (baseRev 0) or replaces an entry.
    func savePrivateEntry(_ e: CalPrivateEntry, baseRev: Int64) async throws -> CalPrivateEntry
    func deletePrivateEntry(id: UUID, baseRev: Int64) async throws -> Int64
    func savePartner(_ p: CalPartner) async throws -> CalPartner
    // Cycle (PROVISIONAL).
    func saveCycleDay(_ d: CalCycleDay) async throws -> CalCycleDay
    func deleteCycleDay(id: UUID) async throws -> Int64
    func saveCycleSettings(_ s: CalCycleSettings) async throws -> CalCycleSettings
}

public extension CalendarTransport {
    /// Delta cursors only (no load in progress).
    func sync(cursors: [UUID: Int64]) async throws -> CalSyncPage {
        try await sync(cursors: cursors.mapValues { CalCursor(rev: $0) })
    }
}

/// `CalendarTransport` over Connect/protobuf. Wraps the generated client and
/// injects the bearer token per call.
public struct ConnectCalendarTransport: CalendarTransport {
    private let client: Calendar_V1_CalendarServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec(),
                                          timeout: 30)
        self.client = Calendar_V1_CalendarServiceClient(client: ProtocolClient(httpClient: URLSessionHTTPClient(), config: config))
        self.tokenProvider = tokenProvider
    }

    // MARK: plumbing

    private func headers() async throws -> Headers {
        // No token → fail locally rather than send a request the server can only reject.
        guard let tok = await tokenProvider() else { throw CalTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T: ProtobufMessage>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        guard let e = r.error else { throw CalTransportError.badResponse("empty response") }
        throw Self.map(e)
    }

    static func map(_ e: ConnectError) -> CalTransportError {
        let msg = e.message ?? ""
        switch e.code {
        case .unauthenticated: return .notAuthenticated
        case .notFound: return .notFound
        case .permissionDenied: return .forbidden(msg)
        case .failedPrecondition:
            let current = (e.unpackedDetails() as [Calendar_V1_Event]).first.flatMap { try? Wire.event($0) }
            return .conflict(current: current)
        case .invalidArgument: return .invalid(msg)
        case .alreadyExists: return .exists(msg)
        case .resourceExhausted:
            // A rate limit says when to come back; a cap reached doesn't (R61).
            return e.metadata.keys.contains { $0.lowercased() == "retry-after" } ? .slowDown : .limit
        case .internalError, .unknown:
            return .serverFailed(msg.isEmpty ? "\(e.code)" : msg)
        case .unavailable, .deadlineExceeded, .aborted, .canceled:
            return .unavailable(msg.isEmpty ? "\(e.code)" : msg)
        default: return .badResponse("\(e.code): \(msg)")
        }
    }

    // MARK: sync

    public func sync(cursors: [UUID: CalCursor]) async throws -> CalSyncPage {
        var req = Calendar_V1_SyncRequest()
        req.cursors = cursors.map { id, cur in
            var c = Calendar_V1_CalendarCursor()
            c.calendarID = id.uuidString.lowercased()
            c.rev = cur.rev
            c.loadFrom = cur.loadFrom
            c.intimateRev = cur.intimate
            c.cycleRev = cur.cycle
            return c
        }
        return try Wire.syncPage(value(await client.sync(request: req, headers: try await headers())))
    }

    // MARK: events

    public func createEvent(id: UUID, calendarID: UUID, fields: CalEventFields) async throws -> CalEvent {
        var req = Calendar_V1_CreateEventRequest()
        req.id = Wire.id(id)
        req.calendarID = Wire.id(calendarID)
        req.fields = Wire.fields(fields)
        return try Wire.event(value(await client.createEvent(request: req, headers: try await headers())).event)
    }

    public func createException(id: UUID, calendarID: UUID, masterID: UUID, originalStart: CalOriginalStart,
                                fields: CalEventFields?, cancelled: Bool) async throws -> CalEvent {
        var req = Calendar_V1_CreateEventRequest()
        req.id = Wire.id(id)
        req.calendarID = Wire.id(calendarID)
        req.masterID = Wire.id(masterID)
        switch originalStart {
        case .date(let d): req.originalStartDate = Wire.day(d)
        case .instant(let t): req.originalStartAt = Wire.ms(t)
        }
        req.cancelled = cancelled
        if let fields, !cancelled { req.fields = Wire.fields(fields) }
        return try Wire.event(value(await client.createEvent(request: req, headers: try await headers())).event)
    }

    public func updateEvent(id: UUID, baseRev: Int64, fields: CalEventFields) async throws -> CalEvent {
        var req = Calendar_V1_UpdateEventRequest()
        req.id = Wire.id(id)
        req.baseRev = baseRev
        req.fields = Wire.fields(fields)
        return try Wire.event(value(await client.updateEvent(request: req, headers: try await headers())).event)
    }

    public func deleteEvent(id: UUID, baseRev: Int64) async throws -> Int64 {
        var req = Calendar_V1_DeleteEventRequest()
        req.id = Wire.id(id)
        req.baseRev = baseRev
        return try value(await client.deleteEvent(request: req, headers: try await headers())).rev
    }

    public func splitSeries(masterID: UUID, baseRev: Int64, at originalStart: CalOriginalStart,
                            newID: UUID, fields: CalEventFields) async throws -> (old: CalEvent, new: CalEvent) {
        var req = Calendar_V1_SplitSeriesRequest()
        req.masterID = Wire.id(masterID)
        req.baseRev = baseRev
        switch originalStart {
        case .date(let d): req.originalStartDate = Wire.day(d)
        case .instant(let t): req.originalStartAt = Wire.ms(t)
        }
        req.newID = Wire.id(newID)
        req.fields = Wire.fields(fields)
        let r = try value(await client.splitSeries(request: req, headers: try await headers()))
        return (try Wire.event(r.oldSeries), try Wire.event(r.newSeries))
    }

    // MARK: private settings

    public func setCalendarPref(calendarID: UUID, visible: Bool, color: CalColor) async throws {
        var req = Calendar_V1_SetCalendarPrefRequest()
        req.calendarID = Wire.id(calendarID)
        req.visible = visible
        req.color = color.rawValue
        _ = try value(await client.setCalendarPref(request: req, headers: try await headers()))
    }

    public func listContacts() async throws -> [CalContact] {
        let r = try value(await client.listContacts(request: .init(), headers: try await headers()))
        return try r.contacts.map {
            CalContact(id: try Wire.uuid($0.id), name: $0.name, avatar: $0.avatar.isEmpty ? nil : Data(base64Encoded: $0.avatar))
        }
    }

    // MARK: pairs

    public func openPair(otherID: UUID) async throws -> CalCalendar {
        var req = Calendar_V1_OpenPairRequest()
        req.otherID = Wire.id(otherID)
        return try Wire.calendar(value(await client.openPair(request: req, headers: try await headers())).calendar)
    }

    // MARK: private entries

    public func setConsent(calendarID: UUID, kind: CalConsentKind, on: Bool) async throws -> CalCalendar {
        var req = Calendar_V1_SetConsentRequest()
        req.calendarID = Wire.id(calendarID)
        req.kind = kind == .intimate ? .intimate : .cycle
        req.on = on
        return try Wire.calendar(value(await client.setConsent(request: req, headers: try await headers())).calendar)
    }

    public func savePrivateEntry(_ e: CalPrivateEntry, baseRev: Int64) async throws -> CalPrivateEntry {
        var req = Calendar_V1_SaveIntimateEntryRequest()
        req.id = Wire.id(e.id)
        req.calendarID = Wire.id(e.calendarID)
        req.baseRev = baseRev
        req.content = Wire.content(e.content)
        return try Wire.privateEntry(value(await client.saveIntimateEntry(request: req, headers: try await headers())).entry)
    }

    public func deletePrivateEntry(id: UUID, baseRev: Int64) async throws -> Int64 {
        var req = Calendar_V1_DeleteIntimateEntryRequest()
        req.id = Wire.id(id)
        req.baseRev = baseRev
        return try value(await client.deleteIntimateEntry(request: req, headers: try await headers())).rev
    }

    public func savePartner(_ p: CalPartner) async throws -> CalPartner {
        var req = Calendar_V1_SaveIntimatePartnerRequest()
        req.id = Wire.id(p.id)
        req.calendarID = Wire.id(p.calendarID)
        req.name = p.name
        req.color = p.color.rawValue
        req.archived = p.archived
        // Always its current flag: proto3 can't tell unset from false, and a
        // save without it clears the default.
        req.isDefault = p.isDefault && !p.archived
        return try Wire.partner(value(await client.saveIntimatePartner(request: req, headers: try await headers())).partner)
    }

    // MARK: cycle

    public func saveCycleDay(_ d: CalCycleDay) async throws -> CalCycleDay {
        var req = Calendar_V1_SaveCycleDayRequest()
        req.id = Wire.id(d.id)
        req.calendarID = Wire.id(d.calendarID)
        req.personID = Wire.id(d.personID)
        req.date = Wire.day(d.date)
        req.flow = d.flow?.rawValue ?? ""
        req.starts = d.starts
        req.ends = d.ends
        return try Wire.cycleDay(value(await client.saveCycleDay(request: req, headers: try await headers())).day)
    }

    public func deleteCycleDay(id: UUID) async throws -> Int64 {
        var req = Calendar_V1_DeleteCycleDayRequest()
        req.id = Wire.id(id)
        return try value(await client.deleteCycleDay(request: req, headers: try await headers())).rev
    }

    public func saveCycleSettings(_ s: CalCycleSettings) async throws -> CalCycleSettings {
        var req = Calendar_V1_SaveCycleSettingsRequest()
        req.calendarID = Wire.id(s.calendarID)
        req.personID = Wire.id(s.personID)
        req.cycleLength = Int32(s.cycleLength)
        req.periodLength = Int32(s.periodLength)
        return try Wire.cycleSettings(value(await client.saveCycleSettings(request: req, headers: try await headers())).settings)
    }

    // MARK: labels and history

    public func saveLabel(id: UUID, calendarID: UUID, name: String, color: CalColor) async throws -> CalLabel {
        var req = Calendar_V1_SaveLabelRequest()
        req.id = Wire.id(id)
        req.calendarID = Wire.id(calendarID)
        req.name = name
        req.color = color.rawValue
        return try Wire.label(value(await client.saveLabel(request: req, headers: try await headers())).label)
    }

    public func deleteLabel(id: UUID) async throws {
        var req = Calendar_V1_DeleteLabelRequest()
        req.id = Wire.id(id)
        _ = try value(await client.deleteLabel(request: req, headers: try await headers()))
    }

    public func listActivity(calendarID: UUID, cursor: String?, limit: Int) async throws -> (rows: [CalActivity], next: String?) {
        var req = Calendar_V1_ListActivityRequest()
        req.calendarID = Wire.id(calendarID)
        req.cursor = cursor ?? ""
        req.limit = Int32(limit)
        let r = try value(await client.listActivity(request: req, headers: try await headers()))
        let rows = try r.activity.map {
            CalActivity(id: try Wire.uuid($0.id), kind: $0.kind, actorID: UUID(uuidString: $0.actorID),
                        at: Wire.date($0.at), detail: $0.detail, eventID: UUID(uuidString: $0.eventID))
        }
        return (rows, r.nextCursor.isEmpty ? nil : r.nextCursor)
    }
}

// MARK: - wire ↔ kit

/// Conversions between the generated types and the kit's. Strict on the way in:
/// a malformed answer throws `badResponse` rather than producing a half-event.
enum Wire {
    static func id(_ u: UUID) -> String { u.uuidString.lowercased() }

    static func uuid(_ s: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else { throw CalTransportError.badResponse("bad id \(s)") }
        return u
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func day(_ d: Calendar_V1_Date) -> CalDate { CalDate(Int(d.year), Int(d.month), Int(d.day)) }
    static func day(_ d: CalDate) -> Calendar_V1_Date {
        var w = Calendar_V1_Date()
        w.year = Int32(d.year)
        w.month = Int32(d.month)
        w.day = Int32(d.day)
        return w
    }

    static func color(_ s: String) -> CalColor { CalColor(rawValue: s) ?? .none }

    // recurrence

    static func recurrence(_ r: CalRecurrence) -> Calendar_V1_Recurrence {
        var w = Calendar_V1_Recurrence()
        switch r.frequency {
        case .daily: w.freq = .daily
        case .weekly: w.freq = .weekly
        case .monthly: w.freq = .monthly
        case .yearly: w.freq = .yearly
        }
        w.interval = Int32(r.interval)
        // Canonical form: no weekdays off weekly (the server refuses them), sorted.
        w.byWeekday = CalRecurrenceExpander.canonical(r).weekdays.compactMap { Calendar_V1_Weekday(rawValue: $0) } // ISO 1...7 = proto 1...7
        if r.frequency == .monthly {
            switch r.monthly {
            case .dayOfMonth: w.monthly = .dayOfMonth
            case .nthWeekday: w.monthly = .nthWeekday
            case .lastWeekday: w.monthly = .lastWeekday
            }
        }
        if let u = r.until { w.until = day(u) }
        w.count = Int32(r.count ?? 0)
        return w
    }

    static func recurrence(_ w: Calendar_V1_Recurrence) throws -> CalRecurrence {
        let freq: CalFrequency
        switch w.freq {
        case .daily: freq = .daily
        case .weekly: freq = .weekly
        case .monthly: freq = .monthly
        case .yearly: freq = .yearly
        default: throw CalTransportError.badResponse("unknown frequency")
        }
        let mode: CalMonthlyMode
        switch w.monthly {
        case .nthWeekday: mode = .nthWeekday
        case .lastWeekday: mode = .lastWeekday
        default: mode = .dayOfMonth
        }
        return CalRecurrenceExpander.canonical(
            CalRecurrence(freq, interval: max(1, Int(w.interval)),
                          weekdays: w.byWeekday.map(\.rawValue).filter { (1...7).contains($0) },
                          monthly: mode, until: w.hasUntil ? day(w.until) : nil,
                          count: w.count > 0 ? Int(w.count) : nil))
    }

    // events

    static func fields(_ f: CalEventFields) -> Calendar_V1_EventFields {
        var w = Calendar_V1_EventFields()
        w.title = f.title
        w.notes = f.notes
        w.location = f.location
        switch f.when {
        case .allDay(let s, let e):
            w.allDay = true
            w.startDate = day(s)
            w.endDate = day(e)
        case .timed(let s, let e, let tz):
            w.startAt = ms(s)
            w.endAt = ms(e)
            w.timeZone = tz
        }
        w.labelID = f.labelID.map(id) ?? ""
        w.color = f.color.rawValue
        if let r = f.recurrence { w.recurrence = recurrence(r) }
        return w
    }

    static func event(_ w: Calendar_V1_Event) throws -> CalEvent {
        let when: CalWhen
        if w.deleted {
            when = .allDay(start: CalDate(1970, 1, 1), end: CalDate(1970, 1, 2)) // a tombstone carries no times
        } else if w.allDay {
            guard w.hasStartDate, w.hasEndDate else { throw CalTransportError.badResponse("all-day event without dates") }
            when = .allDay(start: day(w.startDate), end: day(w.endDate))
        } else {
            guard !w.timeZone.isEmpty else { throw CalTransportError.badResponse("timed event without a zone") }
            when = .timed(start: date(w.startAt), end: date(w.endAt), timeZone: w.timeZone)
        }
        var original: CalOriginalStart?
        if w.hasOriginalStartDate {
            original = .date(day(w.originalStartDate))
        } else if w.originalStartAt != 0 {
            original = .instant(date(w.originalStartAt))
        }
        return CalEvent(
            id: try uuid(w.id), calendarID: try uuid(w.calendarID),
            fields: CalEventFields(title: w.title, notes: w.notes, location: w.location, when: when,
                                   labelID: UUID(uuidString: w.labelID), color: color(w.color),
                                   recurrence: w.hasRecurrence ? try recurrence(w.recurrence) : nil),
            masterID: w.masterID.isEmpty ? nil : try uuid(w.masterID),
            originalStart: original, cancelled: w.cancelled,
            createdBy: UUID(uuidString: w.createdBy) ?? UUID(), updatedBy: UUID(uuidString: w.updatedBy) ?? UUID(),
            createdAt: date(w.createdAt), updatedAt: date(w.updatedAt), rev: w.rev, deleted: w.deleted)
    }

    // the rest

    static func calendar(_ w: Calendar_V1_Calendar) throws -> CalCalendar {
        var c = CalCalendar(id: try uuid(w.id), otherID: try uuid(w.otherID), name: w.name, rev: w.rev, frozen: w.frozen,
                            visible: w.visible, prefColor: color(w.prefColor))
        c.intimateMine = w.intimateMine
        c.intimateTheirs = w.intimateTheirs
        c.cycleMine = w.cycleMine
        c.cycleTheirs = w.cycleTheirs
        c.intimateRev = w.intimateRev
        c.cycleRev = w.cycleRev
        return c
    }

    static func cycleDay(_ w: Calendar_V1_CycleDay) throws -> CalCycleDay {
        CalCycleDay(id: try uuid(w.id), calendarID: try uuid(w.calendarID), personID: try uuid(w.personID),
                    date: day(w.date), flow: w.flow.isEmpty ? nil : CalFlow(rawValue: w.flow) ?? .medium,
                    starts: w.starts, ends: w.ends, rev: w.rev, deleted: w.deleted)
    }

    static func cycleSettings(_ w: Calendar_V1_CycleSettings) throws -> CalCycleSettings {
        CalCycleSettings(calendarID: try uuid(w.calendarID), personID: try uuid(w.personID),
                         cycleLength: Int(w.cycleLength), periodLength: Int(w.periodLength), rev: w.rev)
    }

    // private entries

    static func content(_ c: CalPrivateContent) -> Calendar_V1_IntimateContent {
        var w = Calendar_V1_IntimateContent()
        w.at = ms(c.at)
        w.timeZone = c.timeZone
        w.durationMin = Int32(c.durationMinutes)
        w.foreplayMin = Int32(c.foreplayMinutes)
        w.partnerIds = c.partnerIDs.map(id)
        w.solo = c.solo
        w.types = c.types
        w.protection = c.protection
        w.finishedInside = c.finishedInside.sorted { $0.key.uuidString < $1.key.uuidString }.map { k, v in
            var f = Calendar_V1_FinishedInside()
            f.partnerID = id(k)
            f.value = v
            return f
        }
        w.orgasmsMe = Int32(c.orgasmsMe)
        w.orgasmsPartner = Int32(c.orgasmsPartner)
        w.initiatedBy = c.initiatedBy
        w.location = c.location
        w.locationNote = c.locationNote
        w.satisfaction = Int32(c.satisfaction)
        w.notes = c.notes
        w.quickLog = c.quickLog
        w.positions = c.positions
        w.subjectID = c.subjectID.map(id) ?? ""
        return w
    }

    static func content(_ w: Calendar_V1_IntimateContent) -> CalPrivateContent {
        var c = CalPrivateContent(at: date(w.at), timeZone: w.timeZone.isEmpty ? TimeZone.current.identifier : w.timeZone)
        c.durationMinutes = Int(w.durationMin)
        c.foreplayMinutes = Int(w.foreplayMin)
        c.partnerIDs = w.partnerIds.compactMap(UUID.init(uuidString:))
        c.solo = w.solo
        c.types = w.types
        c.protection = w.protection
        c.finishedInside = Dictionary(w.finishedInside.compactMap { f in UUID(uuidString: f.partnerID).map { ($0, f.value) } },
                                      uniquingKeysWith: { a, _ in a })
        c.orgasmsMe = Int(w.orgasmsMe)
        c.orgasmsPartner = Int(w.orgasmsPartner)
        c.initiatedBy = w.initiatedBy
        c.location = w.location
        c.locationNote = w.locationNote
        c.satisfaction = Int(w.satisfaction)
        c.notes = w.notes
        c.quickLog = w.quickLog
        c.positions = w.positions
        c.subjectID = UUID(uuidString: w.subjectID)
        return c
    }

    static func privateEntry(_ w: Calendar_V1_IntimateEntry) throws -> CalPrivateEntry {
        CalPrivateEntry(id: try uuid(w.id), calendarID: try uuid(w.calendarID), content: content(w.content),
                        createdBy: UUID(uuidString: w.createdBy) ?? UUID(), updatedBy: UUID(uuidString: w.updatedBy),
                        rev: w.rev, deleted: w.deleted)
    }

    static func partner(_ w: Calendar_V1_IntimatePartner) throws -> CalPartner {
        CalPartner(id: try uuid(w.id), calendarID: try uuid(w.calendarID), ownerID: UUID(uuidString: w.ownerID),
                   name: w.name, color: color(w.color),
                   archived: w.archived, isDefault: w.isDefault, rev: w.rev, deleted: w.deleted)
    }

    static func label(_ w: Calendar_V1_Label) throws -> CalLabel {
        CalLabel(id: try uuid(w.id), calendarID: try uuid(w.calendarID), name: w.name, color: color(w.color), rev: w.rev)
    }

    static func syncPage(_ w: Calendar_V1_SyncResponse) throws -> CalSyncPage {
        CalSyncPage(
            calendars: try w.calendars.map(calendar),
            deltas: try w.deltas.map { d in
                CalDelta(calendarID: try uuid(d.calendarID),
                         events: try d.events.map(event),
                         labels: try d.labels.filter { !$0.deleted }.map(label),
                         deletedLabelIDs: try d.labels.filter(\.deleted).map { try uuid($0.id) },
                         rev: d.rev, hasMore: d.hasMore_p, reload: d.reload, loadFrom: d.loadFrom,
                         privateDelta: CalPrivateDelta(entries: try d.intimateEntries.map(privateEntry),
                                                       partners: try d.intimatePartners.map(partner),
                                                       rev: d.intimateRev, hasMore: d.intimateHasMore,
                                                       reset: d.intimateReset),
                         cycleDelta: CalCycleDelta(days: try d.cycleDays.map(cycleDay),
                                                   settings: try d.cycleSettings.map(cycleSettings),
                                                   rev: d.cycleRev, hasMore: d.cycleHasMore, reset: d.cycleReset))
            },
            gone: try w.gone.map(uuid))
    }
}
