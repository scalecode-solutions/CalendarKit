import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-25 step 2 (design sprint): the private stream's data path beyond the
/// basics in PrivateEntryTests: the other member's rows arriving, conflicts,
/// deletes, partners, what's shown where, and freezing.
@MainActor
@Suite("Private data", .serialized)
struct PrivateDataTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let nov16 = Date(timeIntervalSince1970: 1_794_841_200) // Mon 2026-11-16 09:00 Chicago

    /// A pair with intimate entries on for both members, synced.
    private func consented() async -> (CalendarEngine, FakeServer, UUID) {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        engine.setConsent(engine.calendar(own)!, .intimate, true)
        await engine.refresh()
        return (engine, server, own)
    }

    private func content(_ at: Date, solo: Bool = true) -> CalPrivateContent {
        var c = CalPrivateContent(at: at, timeZone: chicago.identifier)
        c.solo = solo
        return c
    }

    /// The other member writes a row on the server.
    @discardableResult
    private func external(_ server: FakeServer, _ cal: UUID, id: UUID = UUID(), at: Date, notes: String = "",
                          by: UUID = UUID(), deleted: Bool = false) -> CalPrivateEntry {
        var out: CalPrivateEntry!
        server.set { s in
            let r = (s.privateRev[cal] ?? 0) + 1
            s.privateRev[cal] = r
            var c = CalPrivateContent(at: at, timeZone: "America/Chicago")
            c.solo = true
            c.notes = notes
            let createdBy = s.privates[id]?.createdBy ?? by
            out = CalPrivateEntry(id: id, calendarID: cal, content: c, createdBy: createdBy, updatedBy: by, rev: r, deleted: deleted)
            s.privates[id] = out
        }
        return out
    }

    private func externalPartner(_ server: FakeServer, _ p: CalPartner) {
        server.set { s in
            let r = (s.privateRev[p.calendarID] ?? 0) + 1
            s.privateRev[p.calendarID] = r
            var q = p
            q.rev = r
            s.partners[p.id] = q
        }
    }

    private func day(_ engine: CalendarEngine, _ d: CalDate = CalDate(2026, 11, 16), only: Set<UUID>? = nil) -> [CalPrivateEntry] {
        engine.privateEntries(from: d, through: d, zone: chicago, only: only)
    }

    @Test func theOtherMembersEntriesArriveChangeAndGo() async {
        let (engine, server, own) = await consented()
        let theirs = external(server, own, at: nov16, notes: "first")
        await engine.refresh()
        #expect(day(engine).map(\.content.notes) == ["first"])
        external(server, own, id: theirs.id, at: nov16, notes: "second")
        await engine.refresh()
        #expect(day(engine).map(\.content.notes) == ["second"])
        external(server, own, id: theirs.id, at: nov16, deleted: true)
        await engine.refresh()
        #expect(day(engine).isEmpty)
        // Nothing was queued by any of it.
        #expect(engine.pendingCount == 0)
    }

    /// The server refuses a stale save (someone changed it first). The row
    /// must not stay stuck on the phone's version: the server's comes back.
    @Test func aConflictedSaveEndsOnTheServersVersion() async throws {
        let (engine, server, own) = await consented()
        var mine = CalPrivateEntry(calendarID: own, content: content(nov16), createdBy: engine.config.currentUserID)
        engine.savePrivate(mine)
        await engine.refresh()
        mine = try #require(day(engine).first)
        // The other member edits it on the server; this phone hasn't seen it.
        server.set { s in
            let r = (s.privateRev[own] ?? 0) + 1
            s.privateRev[own] = r
            s.privates[mine.id]!.content.notes = "theirs"
            s.privates[mine.id]!.rev = r
        }
        mine.content.notes = "mine"
        engine.savePrivate(mine) // based on the old rev: refused
        await engine.refresh()
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(engine.pendingCount == 0)
        #expect(day(engine).map(\.content.notes) == ["theirs"])
    }

    @Test func aDeleteMadeOfflineLandsLater() async throws {
        let (engine, server, own) = await consented()
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: content(nov16), createdBy: engine.config.currentUserID))
        await engine.refresh()
        let e = try #require(day(engine).first)
        server.set { $0.offline = true }
        engine.deletePrivate(e)
        #expect(day(engine).isEmpty)
        await engine.refresh()
        #expect(engine.pendingCount == 1)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.pendingCount == 0)
        #expect(server.get { $0.privates[e.id]?.deleted } == true)
        #expect(day(engine).isEmpty)
    }

    /// Deleting a row the other member already deleted is quiet: it's gone
    /// either way.
    @Test func deletingWhatTheOtherAlreadyDeletedIsQuiet() async throws {
        let (engine, server, own) = await consented()
        let theirs = external(server, own, at: nov16)
        await engine.refresh()
        let e = try #require(day(engine).first)
        server.set { $0.privates[theirs.id] = nil } // gone (purged) on the server
        engine.deletePrivate(e)
        await engine.refresh()
        #expect(engine.notices.isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(day(engine).isEmpty)
    }

    @Test func partnersArriveSortArchivedLastAndGoWhenDeleted() async throws {
        let (engine, server, own) = await consented()
        let zoe = CalPartner(calendarID: own, name: "zoe")
        let alex = CalPartner(calendarID: own, name: "Alex", archived: true)
        let bo = CalPartner(calendarID: own, name: "Bo", color: .orange)
        for p in [zoe, alex, bo] { externalPartner(server, p) }
        await engine.refresh()
        let cal = try #require(engine.calendar(own))
        #expect(engine.partners(of: cal).map(\.name) == ["Bo", "zoe", "Alex"])
        var gone = bo
        gone.deleted = true
        externalPartner(server, gone)
        await engine.refresh()
        #expect(engine.partners(of: cal).map(\.name) == ["zoe", "Alex"])
    }

    @Test func aPartnerAddedHereReachesTheServer() async throws {
        let (engine, server, own) = await consented()
        let p = CalPartner(calendarID: own, name: "Sam", color: .teal)
        engine.savePartner(p)
        #expect(engine.partners(of: engine.calendar(own)!).map(\.name) == ["Sam"])
        await engine.refresh()
        #expect(server.get { $0.partners[p.id]?.name } == "Sam")
        #expect(engine.pendingCount == 0)
    }

    /// The day an entry falls on is the viewer's: 11:30 PM in Chicago on the
    /// 16th is the 17th in New York.
    @Test func entriesFallOnTheViewersDay() async {
        let (engine, _, own) = await consented()
        let late = Date(timeIntervalSince1970: 1_794_841_200 + 14.5 * 3600) // 23:30 Chicago
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: content(late), createdBy: engine.config.currentUserID))
        await engine.refresh()
        let ny = TimeZone(identifier: "America/New_York")!
        #expect(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).count == 1)
        #expect(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: ny).isEmpty)
        #expect(engine.privateEntries(from: CalDate(2026, 11, 17), through: CalDate(2026, 11, 17), zone: ny).count == 1)
    }

    /// A hidden pair's entries don't show in the all-pairs view; a focus on it
    /// (`only`) still shows them, the same as its events.
    @Test func aHiddenPairsEntriesShowOnlyInItsFocus() async throws {
        let (engine, server, own) = await consented()
        external(server, own, at: nov16)
        await engine.refresh()
        engine.setVisible(try #require(engine.calendar(own)), false)
        #expect(day(engine).isEmpty)
        #expect(day(engine, only: [own]).count == 1)
    }

    /// Entries are kept per pair: one pair's consent going off clears only
    /// that pair.
    @Test func consentOffClearsOnlyThatPair() async throws {
        let (engine, server, own) = await consented()
        let other = server.addPair(name: "Second")
        server.externalConsent(other, true)
        await engine.refresh()
        engine.setConsent(try #require(engine.calendar(other)), .intimate, true)
        await engine.refresh()
        external(server, own, at: nov16)
        external(server, other, at: nov16)
        await engine.refresh()
        #expect(day(engine).count == 2)
        server.externalConsent(other, false)
        await engine.refresh()
        #expect(day(engine).map(\.calendarID) == [own])
    }

    /// When the two stop being friends the server resets both consents
    /// (decision 1): the phone drops the pair's entries and partners.
    @Test func aFrozenPairDropsItsPrivateRows() async throws {
        let (engine, server, own) = await consented()
        external(server, own, at: nov16)
        externalPartner(server, CalPartner(calendarID: own, name: "Sam"))
        await engine.refresh()
        #expect(day(engine).count == 1)
        server.set { s in
            let i = s.calendars.firstIndex { $0.id == own }!
            s.calendars[i].frozen = true
            s.calendars[i].intimateMine = false
            s.calendars[i].intimateTheirs = false
        }
        await engine.refresh()
        #expect(day(engine).isEmpty)
        #expect(engine.partners(of: try #require(engine.calendar(own))).isEmpty)
        #expect(engine.calendar(own)?.intimateMine == false)
    }

    /// A save queued while offline, and consent goes off before it lands: it
    /// is refused, removed here, with one notice, and nothing stays queued.
    @Test func aQueuedSaveAfterConsentWentOffIsDroppedWithANotice() async {
        let (engine, server, own) = await consented()
        server.set { $0.offline = true }
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: content(nov16), createdBy: engine.config.currentUserID))
        server.externalConsent(own, false)
        server.set { $0.offline = false }
        await engine.refresh()
        await engine.refresh()
        #expect(day(engine).isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.notices.count == 1)
        #expect(server.get(\.privates).isEmpty)
    }

    /// A private change never touches the event stream: a pair's events
    /// survive a private reset.
    @Test func aPrivateResetLeavesEventsAlone() async {
        let (engine, server, own) = await consented()
        _ = server.externalCreate(own, allDay("Work", 2026, 11, 20))
        external(server, own, at: nov16)
        await engine.refresh()
        server.externalConsent(own, false)
        await engine.refresh()
        #expect(day(engine).isEmpty)
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Work"])
    }

    /// The private rows are kept in the store: a new engine on the same store
    /// shows them before any sync.
    @Test func privateRowsSurviveAReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pdt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = UUID()
        let server = FakeServer(me: me)
        let own = server.addCalendar(owner: me, role: .owner)
        func engine() -> CalendarEngine {
            CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me,
                                                  tokenProvider: { "t" }, storeDirectory: dir), transport: server)
        }
        server.externalConsent(own, true)
        let first = engine()
        await first.refresh()
        first.setConsent(try #require(first.calendar(own)), .intimate, true)
        await first.refresh()
        external(server, own, at: nov16)
        await first.refresh()
        #expect(day(first).count == 1)
        first.stop()
        server.set { $0.offline = true }
        let second = engine()
        await second.refresh()
        #expect(day(second).count == 1)
    }
}

/// The person's default partner per pair (design review, 2026-11-16): on the device,
/// per account and pair, and gone once that name is removed.
@MainActor
@Suite("Default partner", .serialized)
struct DefaultPartnerTests {
    @Test func setReadClearAndRemoved() async throws {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        engine.setConsent(try #require(engine.calendar(own)), .intimate, true)
        await engine.refresh()
        let cal = try #require(engine.calendar(own))
        defer { engine.setDefaultPartner(nil, in: cal) }
        #expect(engine.defaultPartner(in: cal) == nil)
        let jordan = CalPartner(calendarID: own, name: "Jordan", color: .teal)
        engine.savePartner(jordan)
        engine.setDefaultPartner(jordan.id, in: cal)
        #expect(engine.defaultPartner(in: cal) == jordan.id)
        // Another account on this device has its own.
        let other = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: UUID(),
                                                          tokenProvider: { "t" }), transport: server)
        #expect(other.defaultPartner(in: cal) == nil)
        // Removed (archived): no longer the default.
        var removed = jordan
        removed.archived = true
        engine.savePartner(removed)
        #expect(engine.defaultPartner(in: cal) == nil)
        // A name that isn't on the list at all isn't either.
        engine.setDefaultPartner(UUID(), in: cal)
        #expect(engine.defaultPartner(in: cal) == nil)
        engine.setDefaultPartner(nil, in: cal)
        #expect(UserDefaults.standard.string(forKey: CalendarEngine.defaultPartnerKey(engine.config.currentUserID, own)) == nil)
    }
}
