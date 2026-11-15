import Foundation
import Testing
@testable import CalendarKit

/// Round trips against a REAL local mvCalendar, through the real Connect
/// transport. Skipped unless the runner passes the environment (only
/// scripts/live-test.sh does: it mints the tokens, checks the accounts are
/// clean, and wipes them afterwards). TEST accounts only, never a real person's.
struct Live: Sendable {
    let base: URL
    let owner: UUID
    let partner: UUID
    let ownerToken: String
    let partnerToken: String

    static let env: Live? = {
        let e = ProcessInfo.processInfo.environment
        guard let b = e["CAL_LIVE_BASE"], let base = URL(string: b),
              let o = e["CAL_LIVE_OWNER"].flatMap(UUID.init(uuidString:)),
              let p = e["CAL_LIVE_PARTNER"].flatMap(UUID.init(uuidString:)),
              let ot = e["CAL_LIVE_OWNER_TOKEN"], let pt = e["CAL_LIVE_PARTNER_TOKEN"] else { return nil }
        return Live(base: base, owner: o, partner: p, ownerToken: ot, partnerToken: pt)
    }()

    var ownerT: ConnectCalendarTransport { ConnectCalendarTransport(baseURL: base, tokenProvider: { [t = ownerToken] in t }) }
    var partnerT: ConnectCalendarTransport { ConnectCalendarTransport(baseURL: base, tokenProvider: { [t = partnerToken] in t }) }
}

@Suite("Live transport", .serialized, .enabled(if: Live.env != nil, "set by scripts/live-test.sh"))
struct LiveTransportTests {
    let live = Live.env!
    let chicago = "America/Chicago"
    // Mon 2026-11-16 09:00 Chicago.
    let monday9 = Date(timeIntervalSince1970: 1_794_841_200)

    func own(_ t: ConnectCalendarTransport) async throws -> CalCalendar {
        let page = try await t.sync(cursors: [:])
        return try #require(page.calendars.first { $0.isOwn })
    }

    @Test func roundTripsEveryShapeOfEvent() async throws {
        let t = live.ownerT
        let cal = try await own(t)
        let label = try await t.saveLabel(id: UUID(), name: "Doctor", color: .teal)
        let timed = CalEventFields(title: "PT 🦵", notes: "bring the band\nline 2", location: "Clinic, Suite 4",
                                   when: .timed(start: monday9, end: monday9.addingTimeInterval(3600), timeZone: chicago),
                                   labelID: label.id, color: .orange,
                                   recurrence: CalRecurrence(.weekly, interval: 2, weekdays: [1, 3], count: 6))
        let allDay = CalEventFields(title: "Work", when: .allDay(start: CalDate(2026, 11, 20), end: CalDate(2026, 11, 22)),
                                    recurrence: CalRecurrence(.monthly, monthly: .lastWeekday, until: CalDate(2027, 6, 30)))
        // Nov 20 2026 isn't a last Friday: the server must refuse, and say why.
        await #expect(throws: CalTransportError.self) {
            _ = try await t.createEvent(id: UUID(), calendarID: cal.id, fields: allDay)
        }
        var lastFriday = allDay
        lastFriday.when = .allDay(start: CalDate(2026, 11, 27), end: CalDate(2026, 11, 28))
        let a = try await t.createEvent(id: UUID(), calendarID: cal.id, fields: timed)
        let b = try await t.createEvent(id: UUID(), calendarID: cal.id, fields: lastFriday)
        #expect(a.fields == timed)
        #expect(b.fields == lastFriday)
        #expect(a.createdBy == live.owner)

        // The same events come back identical through Sync.
        let page = try await t.sync(cursors: [:])
        let delta = try #require(page.deltas.first { $0.calendarID == cal.id })
        #expect(delta.events.first { $0.id == a.id }?.fields == timed)
        #expect(delta.events.first { $0.id == b.id }?.fields == lastFriday)
        #expect(delta.labels.contains { $0.id == label.id && $0.name == "Doctor" && $0.color == .teal })

        // An exception, then a delta from the cursor holds only it.
        let second = monday9.addingTimeInterval(2 * 86_400) // the Wednesday
        let ex = try await t.createException(id: UUID(), calendarID: cal.id, masterID: a.id,
                                             originalStart: .instant(second), fields: nil, cancelled: true)
        #expect(ex.cancelled && ex.masterID == a.id && ex.originalStart == .instant(second))
        let next = try await t.sync(cursors: [cal.id: delta.rev])
        #expect(next.deltas.first?.events.map(\.id) == [ex.id])

        // Delete the series: the delta carries tombstones for it and its exception.
        _ = try await t.deleteEvent(id: a.id, baseRev: a.rev)
        let after = try await t.sync(cursors: [cal.id: next.deltas.first!.rev])
        let tomb = after.deltas.first?.events ?? []
        #expect(Set(tomb.map(\.id)) == [a.id, ex.id] && tomb.allSatisfy(\.deleted))
        try await t.deleteLabel(id: label.id)
        let labelGone = try await t.sync(cursors: [cal.id: after.deltas.first!.rev])
        #expect(labelGone.deltas.first?.deletedLabelIDs == [label.id])
    }

    @Test func errorsMapToWhatTheEngineNeeds() async throws {
        let t = live.ownerT, p = live.partnerT
        let cal = try await own(t)
        let e = try await t.createEvent(id: UUID(), calendarID: cal.id,
                                        fields: CalEventFields(title: "Dentist", when: .allDay(start: CalDate(2026, 12, 1), end: CalDate(2026, 12, 2))))
        // A stranger to the calendar: notFound.
        await #expect(throws: CalTransportError.notFound) {
            _ = try await p.updateEvent(id: e.id, baseRev: e.rev, fields: e.fields)
        }
        // Shared as view: forbidden.
        let g = try await t.createGrant(granteeID: live.partner, role: .view, expiresAt: nil, label: "")
        #expect(g.role == .view)
        do {
            _ = try await p.createEvent(id: UUID(), calendarID: cal.id, fields: e.fields)
            Issue.record("viewer could write")
        } catch let err as CalTransportError {
            guard case .forbidden = err else { Issue.record("want forbidden, got \(err)"); return }
        }
        // Edit share; the partner edits; the owner's stale write is a conflict
        // carrying the partner's version.
        _ = try await t.createGrant(granteeID: live.partner, role: .edit, expiresAt: nil, label: "")
        var moved = e.fields
        moved.title = "Dentist 3pm"
        let theirs = try await p.updateEvent(id: e.id, baseRev: e.rev, fields: moved)
        do {
            _ = try await t.updateEvent(id: e.id, baseRev: e.rev, fields: e.fields)
            Issue.record("stale write went through")
        } catch CalTransportError.conflict(let current) {
            #expect(current?.rev == theirs.rev && current?.fields.title == "Dentist 3pm")
        }
        // Invalid input carries the server's words.
        do {
            var bad = e.fields
            bad.when = .timed(start: monday9, end: monday9, timeZone: "Mars/Olympus")
            _ = try await t.createEvent(id: UUID(), calendarID: cal.id, fields: bad)
            Issue.record("bad zone accepted")
        } catch CalTransportError.invalid(let msg) {
            #expect(msg == "bad time zone")
        }
        // The partner's view of it, then revoke: the calendar is gone.
        let pc = try await own(p)
        let seen = try await p.sync(cursors: [pc.id: 0])
        let shared = try #require(seen.calendars.first { $0.ownerID == live.owner })
        #expect(shared.role == .edit && shared.visible)
        try await t.revokeGrant(id: g.id)
        let gone = try await p.sync(cursors: [shared.id: 1])
        #expect(gone.gone == [shared.id])

        // No token at all is notAuthenticated, without a request.
        let none = ConnectCalendarTransport(baseURL: live.base, tokenProvider: { nil })
        await #expect(throws: CalTransportError.notAuthenticated) {
            _ = try await none.sync(cursors: [:])
        }
        let forged = ConnectCalendarTransport(baseURL: live.base, tokenProvider: { "a.b.c" })
        await #expect(throws: CalTransportError.notAuthenticated) {
            _ = try await forged.sync(cursors: [:])
        }
        // Nothing listening: unavailable (retryable).
        let down = ConnectCalendarTransport(baseURL: URL(string: "http://127.0.0.1:9")!, tokenProvider: { "x" })
        do {
            _ = try await down.sync(cursors: [:])
            Issue.record("talked to nothing")
        } catch let err as CalTransportError {
            #expect(err.isRetryable, "\(err)")
        }
    }

    @Test func privateSettingsRoundTrip() async throws {
        let t = live.ownerT
        let cal = try await own(t)
        try await t.setCalendarPref(calendarID: cal.id, visible: true, color: .pink)
        let page = try await t.sync(cursors: [:])
        #expect(page.calendars.first { $0.isOwn }?.displayColor == .pink)
        let renamed = try await t.updateCalendar(name: "Owner", color: .blue)
        #expect(renamed.name == "Owner" && renamed.color == .blue && renamed.displayColor == .pink)
        let contacts = try await t.listContacts()
        #expect(contacts.contains { $0.id == live.partner })
    }

    /// R6 + the step-4 tolerance, end to end (Frond's ask): the same update sent
    /// twice (a lost answer, retried) conflicts on the second send, and the
    /// server's current copy must equal our fields exactly, weekday order
    /// included, or a retry would become a false "someone else changed it".
    @Test func aRetriedWeeklyUpdateMatchesWhatTheServerHolds() async throws {
        let t = live.ownerT
        let cal = try await own(t)
        let rule = CalRecurrence(.weekly, weekdays: [7, 1, 5, 3]) // Sunday listed first on purpose
        let f0 = CalEventFields(title: "Standup", when: .timed(start: monday9, end: monday9.addingTimeInterval(900), timeZone: chicago),
                                recurrence: rule)
        let e = try await t.createEvent(id: UUID(), calendarID: cal.id, fields: f0)
        var f1 = e.fields
        f1.title = "Standup (moved)"
        f1.recurrence = CalRecurrenceExpander.normalized(rule, first: e.fields.when.firstDay)
        let first = try await t.updateEvent(id: e.id, baseRev: e.rev, fields: f1)
        #expect(first.fields == f1, "server copy: \(String(describing: first.fields.recurrence))")
        do {
            _ = try await t.updateEvent(id: e.id, baseRev: e.rev, fields: f1) // the retry
            Issue.record("a stale base rev was accepted")
        } catch CalTransportError.conflict(let current?) {
            #expect(current.fields == f1, "the retry would read as someone else's change")
            #expect(current.updatedBy == live.owner)
        }
        _ = try await t.deleteEvent(id: e.id, baseRev: first.rev)
    }

    // MARK: two real engines (owner + partner)

    @MainActor func engine(_ user: UUID, _ token: String) -> CalendarEngine {
        let e = CalendarEngine(config: CalendarConfig(baseURL: live.base, currentUserID: user, tokenProvider: { token }))
        e.storeInMemory = true
        return e
    }

    @MainActor @Test func twoPeopleOneCalendar() async throws {
        let owner = engine(live.owner, live.ownerToken), partner = engine(live.partner, live.partnerToken)
        await owner.refresh()
        await partner.refresh()
        let own = try #require(owner.ownCalendar)
        let nov = (CalDate(2026, 11, 1), CalDate(2026, 11, 30))

        // The owner adds a weekly series, then shares as edit.
        let series = owner.addEvent(to: own.id, CalEventFields(title: "PT",
            when: .allDay(start: CalDate(2026, 11, 2), end: CalDate(2026, 11, 3)), recurrence: CalRecurrence(.weekly, count: 4)))
        await owner.refresh()
        #expect(owner.pendingCount == 0 && owner.event(series.id)?.rev ?? 0 > 0)
        _ = try await owner.share(with: live.partner, role: .edit)

        // The partner sees it, edits one occurrence, adds an event.
        await partner.refresh()
        let theirs = try #require(partner.calendars.first { $0.ownerID == live.owner })
        #expect(theirs.role == .edit)
        let occ = partner.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == series.id }
        #expect(occ.count == 4)
        var moved = occ[1].event.fields
        moved.title = "PT (moved)"
        moved.when = .allDay(start: CalDate(2026, 11, 10), end: CalDate(2026, 11, 11))
        partner.updateOccurrence(occ[1], moved)
        partner.addEvent(to: theirs.id, CalEventFields(title: "Dentist", when: .allDay(start: CalDate(2026, 11, 12), end: CalDate(2026, 11, 13))))
        await partner.refresh()
        #expect(partner.pendingCount == 0 && partner.notices.isEmpty)

        // The owner sees both.
        await owner.refresh()
        // (Other tests in this suite leave their own events on the calendar.)
        let titles = owner.occurrences(from: nov.0, through: nov.1).map(\.title).filter { $0.hasPrefix("PT") || $0 == "Dentist" }
        #expect(titles == ["PT", "PT (moved)", "Dentist", "PT", "PT"])

        // A real race: both edit the series from the same rev, each engine
        // pushing in the background. Whoever reaches the server first wins;
        // the other gets a notice; both end up showing the winner's version.
        let base = try #require(owner.event(series.id))
        var a = base.fields; a.title = "PT (owner)"
        var b = base.fields; b.title = "PT (partner)"
        owner.updateEvent(base, a)
        partner.updateEvent(try #require(partner.event(series.id)), b)
        await owner.refresh()
        await partner.refresh()
        await owner.refresh() // the winner's copy reaches whichever synced first
        let ownerTitle = owner.event(series.id)?.fields.title, partnerTitle = partner.event(series.id)?.fields.title
        #expect(owner.notices.count + partner.notices.count == 1, "exactly one side loses")
        #expect(ownerTitle == partnerTitle)
        let winner = owner.notices.isEmpty ? "PT (owner)" : "PT (partner)"
        #expect(ownerTitle == winner)
        #expect(owner.pendingCount == 0 && partner.pendingCount == 0)

        // Revoke: the partner's copy of the calendar disappears.
        let grants = try await owner.grants()
        for g in grants { try await owner.revoke(g) }
        await partner.refresh()
        #expect(partner.calendar(theirs.id) == nil)
        #expect(partner.occurrences(from: nov.0, through: nov.1, includeHidden: true).isEmpty)
    }
}
