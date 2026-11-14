import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures, sorted by what the caller should do about them.
public enum CalTransportError: Error, Sendable, Equatable {
    /// No token, or the server rejected it: the host's session is gone.
    case notAuthenticated
    /// It doesn't exist, or the caller may not know it does.
    case notFound
    /// The caller can see the calendar but not change it.
    case forbidden(String)
    /// Someone changed it first. `current` is the server's copy now.
    case conflict(current: CalEvent?)
    /// The request was refused as invalid (a message for people).
    case invalid(String)
    /// That id or occurrence is already taken.
    case exists(String)
    /// A cap was reached (events, labels, shares).
    case limit
    /// Too many writes: try again shortly.
    case slowDown
    /// The server couldn't be reached or failed: try again later.
    case unavailable(String)
    /// The server answered something this kit can't read.
    case badResponse(String)

    /// Worth trying again later unchanged (an offline write stays queued).
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .slowDown, .notAuthenticated: return true
        default: return false
        }
    }
}

/// The kit's view of the server. A protocol so tests and previews can fake it.
public protocol CalendarTransport: Sendable {
    func sync(cursors: [UUID: Int64], alertsCursor: Int64) async throws -> CalSyncPage

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

    func setAlerts(eventID: UUID, minutesBefore: [Int]) async throws -> CalAlert
    func setAlertDefaults(_ defaults: CalAlertDefaults) async throws -> CalAlertDefaults
    func setCalendarPref(calendarID: UUID, visible: Bool, color: CalColor) async throws
    func listContacts() async throws -> [CalContact]

    // Owner only.
    func updateCalendar(name: String?, color: CalColor?) async throws -> CalCalendar
    func saveLabel(id: UUID, name: String, color: CalColor) async throws -> CalLabel
    func deleteLabel(id: UUID) async throws
    func createGrant(granteeID: UUID, role: CalRole, expiresAt: Date?, label: String) async throws -> CalGrant
    func revokeGrant(id: UUID) async throws
    func listGrants() async throws -> [CalGrant]
    func listActivity(cursor: String?, limit: Int) async throws -> (rows: [CalActivity], next: String?)
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
        case .resourceExhausted: return msg == "slow down" ? .slowDown : .limit
        case .unavailable, .deadlineExceeded, .internalError, .unknown, .aborted, .canceled:
            return .unavailable(msg.isEmpty ? "\(e.code)" : msg)
        default: return .badResponse("\(e.code): \(msg)")
        }
    }

    // MARK: sync

    public func sync(cursors: [UUID: Int64], alertsCursor: Int64) async throws -> CalSyncPage {
        var req = Calendar_V1_SyncRequest()
        req.cursors = cursors.map { id, rev in
            var c = Calendar_V1_CalendarCursor()
            c.calendarID = id.uuidString.lowercased()
            c.rev = rev
            return c
        }
        req.alertsCursor = alertsCursor
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

    public func setAlerts(eventID: UUID, minutesBefore: [Int]) async throws -> CalAlert {
        var req = Calendar_V1_SetAlertsRequest()
        req.eventID = Wire.id(eventID)
        req.minutesBefore = minutesBefore.map(Int32.init)
        return try Wire.alert(value(await client.setAlerts(request: req, headers: try await headers())).alert)
    }

    public func setAlertDefaults(_ defaults: CalAlertDefaults) async throws -> CalAlertDefaults {
        var req = Calendar_V1_SetAlertDefaultsRequest()
        req.defaults = Wire.defaults(defaults)
        return Wire.defaults(try value(await client.setAlertDefaults(request: req, headers: try await headers())).defaults)
    }

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

    // MARK: owner

    public func updateCalendar(name: String?, color: CalColor?) async throws -> CalCalendar {
        var req = Calendar_V1_UpdateCalendarRequest()
        if let name { req.name = name }
        if let color { req.color = color.rawValue }
        return try Wire.calendar(value(await client.updateCalendar(request: req, headers: try await headers())).calendar)
    }

    public func saveLabel(id: UUID, name: String, color: CalColor) async throws -> CalLabel {
        var req = Calendar_V1_SaveLabelRequest()
        req.id = Wire.id(id)
        req.name = name
        req.color = color.rawValue
        return try Wire.label(value(await client.saveLabel(request: req, headers: try await headers())).label)
    }

    public func deleteLabel(id: UUID) async throws {
        var req = Calendar_V1_DeleteLabelRequest()
        req.id = Wire.id(id)
        _ = try value(await client.deleteLabel(request: req, headers: try await headers()))
    }

    public func createGrant(granteeID: UUID, role: CalRole, expiresAt: Date?, label: String) async throws -> CalGrant {
        var req = Calendar_V1_CreateGrantRequest()
        req.granteeID = Wire.id(granteeID)
        req.role = role == .edit ? .edit : .view
        req.expiresAt = expiresAt.map(Wire.ms) ?? 0
        req.label = label
        return try Wire.grant(value(await client.createGrant(request: req, headers: try await headers())).grant)
    }

    public func revokeGrant(id: UUID) async throws {
        var req = Calendar_V1_RevokeGrantRequest()
        req.grantID = Wire.id(id)
        _ = try value(await client.revokeGrant(request: req, headers: try await headers()))
    }

    public func listGrants() async throws -> [CalGrant] {
        try value(await client.listGrants(request: .init(), headers: try await headers())).grants.map(Wire.grant)
    }

    public func listActivity(cursor: String?, limit: Int) async throws -> (rows: [CalActivity], next: String?) {
        var req = Calendar_V1_ListActivityRequest()
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

    static func role(_ r: Calendar_V1_Role) throws -> CalRole {
        switch r {
        case .owner: return .owner
        case .edit: return .edit
        case .view: return .view
        default: throw CalTransportError.badResponse("unknown role")
        }
    }

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
        w.byWeekday = r.weekdays.compactMap { Calendar_V1_Weekday(rawValue: $0) } // ISO 1...7 = proto 1...7
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
        return CalRecurrence(freq, interval: max(1, Int(w.interval)),
                             weekdays: w.byWeekday.map(\.rawValue).filter { (1...7).contains($0) },
                             monthly: mode, until: w.hasUntil ? day(w.until) : nil,
                             count: w.count > 0 ? Int(w.count) : nil)
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
        CalCalendar(id: try uuid(w.id), ownerID: try uuid(w.ownerID), name: w.name, color: color(w.color),
                    role: try role(w.role), rev: w.rev,
                    grantExpiresAt: w.grantExpiresAt > 0 ? date(w.grantExpiresAt) : nil,
                    visible: w.visible, prefColor: color(w.prefColor))
    }

    static func label(_ w: Calendar_V1_Label) throws -> CalLabel {
        CalLabel(id: try uuid(w.id), calendarID: try uuid(w.calendarID), name: w.name, color: color(w.color), rev: w.rev)
    }

    static func alert(_ w: Calendar_V1_Alert) throws -> CalAlert {
        CalAlert(eventID: try uuid(w.eventID), minutesBefore: w.minutesBefore.map(Int.init), rev: w.rev)
    }

    static func defaults(_ d: CalAlertDefaults) -> Calendar_V1_AlertDefaults {
        var w = Calendar_V1_AlertDefaults()
        w.timed = d.timed.map(Int32.init)
        w.allDay = d.allDay.map(Int32.init)
        return w
    }

    static func defaults(_ w: Calendar_V1_AlertDefaults) -> CalAlertDefaults {
        CalAlertDefaults(timed: w.timed.map(Int.init), allDay: w.allDay.map(Int.init))
    }

    static func grant(_ w: Calendar_V1_Grant) throws -> CalGrant {
        CalGrant(id: try uuid(w.id), granteeID: try uuid(w.granteeID), role: try role(w.role),
                 createdAt: date(w.createdAt), expiresAt: w.expiresAt > 0 ? date(w.expiresAt) : nil, label: w.label)
    }

    static func syncPage(_ w: Calendar_V1_SyncResponse) throws -> CalSyncPage {
        CalSyncPage(
            calendars: try w.calendars.map(calendar),
            deltas: try w.deltas.map { d in
                CalDelta(calendarID: try uuid(d.calendarID),
                         events: try d.events.map(event),
                         labels: try d.labels.filter { !$0.deleted }.map(label),
                         deletedLabelIDs: try d.labels.filter(\.deleted).map { try uuid($0.id) },
                         rev: d.rev, hasMore: d.hasMore_p, reload: d.reload)
            },
            gone: try w.gone.map(uuid),
            alerts: try w.alerts.map(alert),
            alertsRev: w.alertsRev,
            alertDefaults: defaults(w.alertDefaults))
    }
}
