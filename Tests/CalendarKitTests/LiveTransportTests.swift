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

    /// The owner's and partner's pair calendar (the two test accounts are
    /// friends locally), opened from the side of `t`.
    func pair(_ t: ConnectCalendarTransport, with other: UUID) async throws -> CalCalendar {
        try await t.openPair(otherID: other)
    }
    func own(_ t: ConnectCalendarTransport) async throws -> CalCalendar { try await pair(t, with: live.partner) }

    @Test func bothSidesOpenTheSamePairAtTheComputedID() async throws {
        let a = try await pair(live.ownerT, with: live.partner)
        let b = try await pair(live.partnerT, with: live.owner)
        #expect(a.id == b.id)
        #expect(a.id == CalPairID.make(live.owner, live.partner))
        #expect(a.otherID == live.partner && b.otherID == live.owner)
        #expect(!a.frozen && a.listed)
        // Opening it again changes nothing (idempotent).
        #expect(try await pair(live.ownerT, with: live.partner).id == a.id)
        // Someone who isn't a friend: notFound, the same as nobody.
        await #expect(throws: CalTransportError.notFound) {
            _ = try await live.ownerT.openPair(otherID: UUID())
        }
    }

    @Test func roundTripsEveryShapeOfEvent() async throws {
        let t = live.ownerT
        let cal = try await own(t)
        let label = try await t.saveLabel(id: UUID(), calendarID: cal.id, name: "Doctor", color: .teal)
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
        // Something that isn't there (or isn't the caller's to know of): notFound.
        await #expect(throws: CalTransportError.notFound) {
            _ = try await p.updateEvent(id: UUID(), baseRev: 1, fields: e.fields)
        }
        // The other member edits; the owner's stale write is a conflict
        // carrying the partner's version.
        var moved = e.fields
        moved.title = "Dentist 3pm"
        let theirs = try await p.updateEvent(id: e.id, baseRev: e.rev, fields: moved)
        #expect(theirs.updatedBy == live.partner && theirs.createdBy == live.owner)
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
        // A cursor for a calendar the caller isn't in comes back gone.
        let gone = try await p.sync(cursors: [UUID(): 1])
        #expect(gone.gone.count == 1)

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

    /// Every word the entry editor offers is one the server takes: a type,
    /// location or initiator it doesn't know refuses the whole save ("Oral
    /// (giving)" once did). Reads PrivateChoices, so a new word is checked too.
    /// One entry, updated in place, to stay well under the write limit; the
    /// server's error names the word it refused.
    @Test func everyWordTheEditorOffersSaves() async throws {
        let t = live.ownerT, p = live.partnerT
        let cal = try await own(t)
        _ = try await t.setConsent(calendarID: cal.id, kind: .intimate, on: true)
        _ = try await p.setConsent(calendarID: cal.id, kind: .intimate, on: true)
        var c = CalPrivateContent(at: monday9, timeZone: chicago)
        c.solo = true
        c.types = PrivateChoices.types
        c.protection = PrivateChoices.protection
        c.positions = PrivateChoices.positions
        var entry = try await t.savePrivateEntry(CalPrivateEntry(calendarID: cal.id, content: c, createdBy: live.owner), baseRev: 0)
        let locations = [""] + PrivateChoices.locations
        for (n, place) in locations.enumerated() {
            entry.content.location = place
            entry.content.initiatedBy = PrivateChoices.initiated[n % PrivateChoices.initiated.count]
            entry = try await t.savePrivateEntry(entry, baseRev: entry.rev)
        }
        #expect(locations.count >= PrivateChoices.initiated.count)
        _ = try await t.deletePrivateEntry(id: entry.id, baseRev: entry.rev)
        _ = try await t.setConsent(calendarID: cal.id, kind: .intimate, on: false)
        _ = try await p.setConsent(calendarID: cal.id, kind: .intimate, on: false)
    }

    @Test func privateSettingsRoundTrip() async throws {
        let t = live.ownerT
        let cal = try await own(t)
        try await t.setCalendarPref(calendarID: cal.id, visible: false, color: .pink)
        let page = try await t.sync(cursors: [:])
        let mine = try #require(page.calendars.first { $0.id == cal.id })
        #expect(mine.displayColor == .pink && !mine.visible)
        // Private: the other member doesn't see it.
        let theirs = try #require(try await live.partnerT.sync(cursors: [:]).calendars.first { $0.id == cal.id })
        #expect(theirs.visible && theirs.prefColor == .none)
        try await t.setCalendarPref(calendarID: cal.id, visible: true, color: .none)
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
        // Both see the pair with the other, at the same id, before or after
        // the server has it.
        let mine = try #require(owner.pair(with: live.partner))
        let yours = try #require(partner.pair(with: live.owner))
        #expect(mine.id == yours.id)
        let nov = (CalDate(2026, 11, 1), CalDate(2026, 11, 30))

        // One adds a weekly series.
        let series = owner.addEvent(to: mine.id, CalEventFields(title: "PT",
            when: .allDay(start: CalDate(2026, 11, 2), end: CalDate(2026, 11, 3)), recurrence: CalRecurrence(.weekly, count: 4)))
        await owner.refresh()
        #expect(owner.pendingCount == 0 && owner.event(series.id)?.rev ?? 0 > 0)
        #expect(owner.notices.isEmpty)

        // The other sees it, edits one occurrence, adds an event.
        await partner.refresh()
        let occ = partner.occurrences(from: nov.0, through: nov.1).filter { $0.seriesID == series.id }
        #expect(occ.count == 4)
        var moved = occ[1].event.fields
        moved.title = "PT (moved)"
        moved.when = .allDay(start: CalDate(2026, 11, 10), end: CalDate(2026, 11, 11))
        partner.updateOccurrence(occ[1], moved)
        partner.addEvent(to: yours.id, CalEventFields(title: "Dentist", when: .allDay(start: CalDate(2026, 11, 12), end: CalDate(2026, 11, 13))))
        await partner.refresh()
        #expect(partner.pendingCount == 0 && partner.notices.isEmpty)

        // The first sees both.
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

        // One hides it: gone from their screen, still there for the other.
        partner.setHidden(try #require(partner.calendar(yours.id)), true)
        await partner.refresh()
        await owner.refresh()
        #expect(partner.occurrences(from: nov.0, through: nov.1).isEmpty)
        #expect(!owner.occurrences(from: nov.0, through: nov.1).isEmpty)
        partner.setHidden(try #require(partner.calendar(yours.id)), false)
        await partner.refresh()
    }
}
