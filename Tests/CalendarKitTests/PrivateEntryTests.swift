import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-25 (design sprint): private entries live in their own stream on a
/// pair, shown only while both members have consented, and dropped from the
/// phone when either turns it off.
@MainActor
@Suite("Private entries", .serialized)
struct PrivateEntryTests {
    private let nov16 = Date(timeIntervalSince1970: 1_794_841_200) // Mon 2026-11-16 09:00 Chicago
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func entry(_ engine: CalendarEngine, _ cal: UUID, partners: [UUID] = [], solo: Bool = false) -> CalPrivateEntry {
        var c = CalPrivateContent(at: nov16, timeZone: chicago.identifier)
        c.partnerIDs = partners
        c.solo = solo
        return CalPrivateEntry(calendarID: cal, content: c, createdBy: engine.config.currentUserID)
    }

    private func onDay(_ engine: CalendarEngine) -> [CalPrivateEntry] {
        engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago)
    }

    @Test func nothingShowsUntilBothConsent() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        engine.setConsent(engine.calendar(own)!, .intimate, true)
        await engine.refresh()
        #expect(engine.calendar(own)?.intimateMine == true && engine.calendar(own)?.intimateOn == false)
        // The other member hasn't: the server takes nothing, and nothing shows.
        engine.savePrivate(entry(engine, own, solo: true))
        await engine.refresh()
        #expect(onDay(engine).isEmpty)
        #expect(server.get(\.privates).isEmpty)
        #expect(engine.notices.count == 1)

        server.externalConsent(own, true)
        await engine.refresh()
        #expect(engine.calendar(own)?.intimateOn == true)
        engine.savePrivate(entry(engine, own, solo: true))
        await engine.refresh()
        #expect(onDay(engine).count == 1)
        #expect(server.get(\.privates).count == 1)
        #expect(engine.pendingCount == 0)
    }

    @Test func turningConsentOffClearsThePhone() async {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        engine.setConsent(engine.calendar(own)!, .intimate, true)
        engine.savePrivate(entry(engine, own, solo: true))
        await engine.refresh()
        #expect(onDay(engine).count == 1)
        // The other member turns it off: the next sync drops it here.
        server.externalConsent(own, false)
        await engine.refresh()
        #expect(onDay(engine).isEmpty)
        // Back on: it comes back from the server, from scratch.
        server.externalConsent(own, true)
        await engine.refresh()
        #expect(onDay(engine).count == 1)
    }

    /// The person's own default partner (design review, 2026-11-16): a quick log
    /// starts with it, so its heart is solid; a removed partner is no default.
    @Test func aQuickLogTakesTheDefaultPartner() async throws {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        let pair = engine.calendar(own)!
        engine.setConsent(pair, .intimate, true)
        await engine.refresh()
        defer { engine.setDefaultPartner(nil, in: pair) }
        let jordan = CalPartner(calendarID: own, name: "Jordan")
        engine.savePartner(jordan)
        await engine.refresh()
        #expect(engine.defaultPartner(in: pair) == nil)
        engine.setDefaultPartner(jordan.id, in: pair)
        #expect(engine.defaultPartner(in: pair) == jordan.id)
        let q = engine.quickLog(in: pair, at: nov16)
        #expect(q.content.partnerIDs == [jordan.id] && !q.content.needsWho && q.content.quickLog)
        #expect(engine.hearts(onDay(engine)).first?.hollow == false)

        // Removed: no longer anyone's default, and a quick log is hollow again.
        var gone = try #require(engine.partners(of: pair).first)
        gone.archived = true
        engine.savePartner(gone)
        await engine.refresh()
        #expect(engine.defaultPartner(in: pair) == nil)
        #expect(engine.quickLog(in: pair, at: nov16).content.needsWho)
    }

    /// Who on a row: one name, or for an older entry naming several, the
    /// first and "+n" (one pick per entry since the design review's dropdown).
    @Test func severalPartnersReadAsTheFirstPlusTheRest() {
        let cal = UUID()
        let a = CalPartner(calendarID: cal, name: "Jordan"), b = CalPartner(calendarID: cal, name: "Casey")
        #expect(PrivateEntryRow.names([a.id], partners: [a, b]) == "Jordan")
        #expect(PrivateEntryRow.names([a.id, b.id], partners: [a, b]) == "Jordan +1")
        #expect(PrivateEntryRow.names([], partners: [a]) == "Someone")
    }

    /// The grid's strip holds two marks at most (MVCALE-50): beside a period
    /// drop, two authors' hearts become one with the day's total, in the color
    /// of whoever logged more (the viewer's own on a tie); without a drop,
    /// both stay.
    @Test func aDropAndTwoAuthorsShowOneHeartWithTheTotal() {
        let me = UUID(), them = UUID()
        let mine = CalHeart(author: me, color: .blue, count: 1, hollow: false)
        let theirs = CalHeart(author: them, color: .teal, count: 2, hollow: true)
        #expect(DayMarks.hearts([mine, theirs], besideADrop: false, me: me) == [mine, theirs])
        let merged = DayMarks.hearts([mine, theirs], besideADrop: true, me: me)
        #expect(merged.count == 1 && merged[0].count == 3 && merged[0].color == .teal && !merged[0].hollow)
        let tie = DayMarks.hearts([CalHeart(author: them, color: .teal, count: 1, hollow: false), mine],
                                  besideADrop: true, me: me)
        #expect(tie.count == 1 && tie[0].color == .blue && tie[0].count == 2)
        #expect(DayMarks.hearts([mine], besideADrop: true, me: me) == [mine])
    }

    /// Which drop a day gets: filled for a logged period, fainter for spotting,
    /// outlined for an expected one, none in the fertile window.
    @Test func dropsFollowTheCycleMark() {
        #expect(DropMark.kind(.logged(.heavy)) == .logged)
        #expect(DropMark.kind(.logged(.spotting)) == .spotting)
        #expect(DropMark.kind(.predictedPeriod) == .expected)
        #expect(DropMark.kind(.fertile(ovulation: true)) == nil)
        #expect(DropMark.kind(nil) == nil)
    }

    /// Partners belong to whoever adds them (MVCALE-51): mine are offered to
    /// me, theirs only name their entries; an entry for them uses their list,
    /// and its heart is theirs.
    @Test func partnersAreEachPersonsOwnAndAnEntryUsesItsSubjectsList() async throws {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        let pair = try #require(engine.calendar(own))
        engine.setConsent(pair, .intimate, true)
        await engine.refresh()
        let me = engine.config.currentUserID, them = pair.otherID
        engine.savePartner(CalPartner(calendarID: own, name: "Jordan"))
        let riley = CalPartner(calendarID: own, ownerID: them, name: "Riley")
        server.externalPartner(riley)
        await engine.refresh()
        let jordan = try #require(engine.myPartners(of: pair).first)
        #expect(jordan.ownerID == me && jordan.name == "Jordan")
        #expect(engine.myPartners(of: pair).map(\.name) == ["Jordan"])
        #expect(Set(engine.partners(of: pair).map(\.name)) == ["Riley", "Jordan"])
        // Their partner is no default of mine, and I can't change it.
        engine.setDefaultPartner(riley.id, in: pair)
        #expect(engine.defaultPartner(in: pair) == nil)
        engine.setDefaultPartner(nil, in: pair)
        var renamed = try #require(engine.partners(of: pair).first { $0.id == riley.id })
        renamed.name = "Rylee"
        engine.savePartner(renamed)
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(server.get { $0.partners[riley.id]?.name } == "Riley")

        // An entry for them, with their partner: saved, and the heart is theirs.
        var c = CalPrivateContent(at: nov16)
        c.subjectID = them
        c.partnerIDs = [riley.id]
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: c, createdBy: me))
        await engine.refresh()
        let entry = try #require(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).first)
        #expect(entry.subject == them && entry.createdBy == me && entry.rev > 0)
        #expect(engine.hearts([entry]).map(\.author) == [them])
        // Mine naming their partner: refused, gone.
        var wrong = CalPrivateContent(at: nov16)
        wrong.partnerIDs = [riley.id]
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: wrong, createdBy: me))
        await engine.refresh()
        #expect(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).count == 1)
        #expect(engine.notices.count == 2)
    }

    /// An entry from before owners naming the other person's partner stays
    /// editable (grandfathered); dropping that partner and adding it back is
    /// refused, since it's no longer one the entry names.
    @Test func anOldEntryNamingTheirPartnerStaysEditable() async throws {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        let pair = try #require(engine.calendar(own))
        engine.setConsent(pair, .intimate, true)
        await engine.refresh()
        let me = engine.config.currentUserID
        let riley = CalPartner(calendarID: own, ownerID: pair.otherID, name: "Riley")
        server.externalPartner(riley)
        var c = CalPrivateContent(at: nov16)
        c.partnerIDs = [riley.id]
        let old = CalPrivateEntry(calendarID: own, content: c, createdBy: me)
        server.set { s in
            let r = (s.privateRev[own] ?? 0) + 1
            s.privateRev[own] = r
            var e = old
            e.rev = r
            s.privates[old.id] = e
        }
        await engine.refresh()
        var e = try #require(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).first)
        e.content.notes = "kept"
        engine.savePrivate(e)
        await engine.refresh()
        #expect(engine.notices.isEmpty)
        #expect(server.get { $0.privates[old.id]?.content.notes } == "kept")
        // Dropped, then added back: refused.
        e = try #require(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).first)
        e.content.partnerIDs = []
        e.content.solo = true
        engine.savePrivate(e)
        await engine.refresh()
        e = try #require(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).first)
        e.content.solo = false
        e.content.partnerIDs = [riley.id]
        engine.savePrivate(e)
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(server.get { $0.privates[old.id]?.content.solo } == true)
    }

    @Test func aQuickLogIsHollowUntilWhoIsSet() async throws {
        let (engine, server, own) = makeEngine()
        server.externalConsent(own, true)
        await engine.refresh()
        engine.setConsent(engine.calendar(own)!, .intimate, true)
        await engine.refresh()
        let q = engine.quickLog(in: engine.calendar(own)!, at: nov16)
        #expect(q.content.needsWho && q.content.quickLog)
        let hearts = engine.hearts(onDay(engine))
        #expect(hearts.count == 1 && hearts[0].hollow)
        var filled = try #require(engine.privateEntries(from: CalDate(2026, 11, 16), through: CalDate(2026, 11, 16), zone: chicago).first)
        filled.content.solo = true
        engine.savePrivate(filled)
        await engine.refresh()
        #expect(engine.hearts(onDay(engine)).first?.hollow == false)
        #expect(server.get { $0.privates.values.first?.content.solo } == true)
    }

    /// Plan decision 9: one heart per author; the partner's color when all of
    /// an author's entries name partners of one color, else the author's.
    @Test func heartsArePerAuthorInThePartnersColorElseTheAuthors() {
        let me = UUID(), them = UUID(), cal = UUID()
        let riley = CalPartner(calendarID: cal, name: "Riley", color: .orange)
        let sam = CalPartner(calendarID: cal, name: "Sam")
        let partners = [riley.id: riley, sam.id: sam]
        func e(_ by: UUID, _ ps: [UUID], quick: Bool = false) -> CalPrivateEntry {
            var c = CalPrivateContent(at: Date(timeIntervalSince1970: 0))
            c.partnerIDs = ps
            c.quickLog = quick
            return CalPrivateEntry(calendarID: cal, content: c, createdBy: by)
        }
        let color: (CalPrivateEntry) -> CalColor = { $0.createdBy == me ? .indigo : .teal }
        // Mine with Riley (orange) twice: one orange heart, count 2.
        var h = CalHeart.hearts([e(me, [riley.id]), e(me, [riley.id])], partners: partners, authorColor: color)
        #expect(h.count == 1 && h[0].color == .orange && h[0].count == 2)
        // Sam has no color: the author's.
        h = CalHeart.hearts([e(me, [sam.id])], partners: partners, authorColor: color)
        #expect(h[0].color == .indigo)
        // Mixed partners in one author's day: the author's.
        h = CalHeart.hearts([e(me, [riley.id]), e(me, [sam.id])], partners: partners, authorColor: color)
        #expect(h[0].color == .indigo)
        // Both members log: two hearts, the other's in the pair's color.
        h = CalHeart.hearts([e(me, [riley.id]), e(them, [])], partners: partners, authorColor: color)
        #expect(h.count == 2)
        #expect(h.first { $0.author == them }?.color == .teal && h.first { $0.author == them }?.hollow == true)
    }
}
