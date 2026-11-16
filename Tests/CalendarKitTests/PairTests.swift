import Foundation
import SwiftData
import Testing
@testable import CalendarKit

/// MVCALE-36: pair calendars in the kit. A calendar belongs to two people; its
/// id is computed from them, so a pair is on screen (from the contact list)
/// before the server has it, and its first write opens it there.
@MainActor
@Suite("Pair calendars", .serialized)
struct PairTests {
    /// The server's test vector (mvCalendar's proto header): both sides must
    /// compute the same id, whichever way round.
    @Test func thePairIDMatchesTheServer() {
        let a = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!
        let want = UUID(uuidString: "c9c6b72d-04bc-597b-a586-756693e23e3e")!
        #expect(CalPairID.make(a, b) == want)
        #expect(CalPairID.make(b, a) == want)
        #expect(CalPairID.make(a, a) != want)
    }

    /// Lower first by bytes: ids whose strings and bytes would sort the same
    /// way still give one id, and a different pair a different one.
    @Test func thePairIDIsTheSameEitherWayAndDiffersPerPair() {
        for _ in 0..<200 {
            let a = UUID(), b = UUID(), c = UUID()
            #expect(CalPairID.make(a, b) == CalPairID.make(b, a))
            #expect(CalPairID.make(a, b) != CalPairID.make(a, c))
        }
    }

    @Test func aFriendWithNoPairYetShowsAtTheComputedIDWithoutAskingTheServer() async {
        let (engine, server, _) = makeEngine()
        let friend = server.addFriend(name: "Sam")
        await engine.refresh()
        let pair = engine.pair(with: friend)
        #expect(pair?.id == CalPairID.make(engine.config.currentUserID, friend))
        #expect(pair?.listed == false)
        #expect(engine.displayName(pair!) == "Sam")
        // Starting never sweeps OpenPair over the friends (it costs writes).
        await engine.refresh()
        #expect(server.get(\.opened).isEmpty)
        #expect(!server.get(\.writes).contains("openPair"))
    }

    @Test func theFirstWriteOpensThePairFirstAndOnlyOnce() async {
        let (engine, server, _) = makeEngine()
        let friend = server.addFriend()
        await engine.refresh()
        let pair = engine.pair(with: friend)!
        engine.addEvent(to: pair.id, allDay("Lunch", 2026, 11, 20))
        engine.addEvent(to: pair.id, allDay("Movie", 2026, 11, 21))
        // On screen at once, before the server has anything.
        #expect(engine.occurrences(from: nov.0, through: nov.1).count == 2)
        await engine.refresh()
        #expect(server.get(\.writes) == ["openPair", "create Lunch", "create Movie"])
        #expect(engine.pair(with: friend)?.listed == true)
        #expect(engine.pendingCount == 0 && engine.notices.isEmpty)
        #expect(server.get { $0.events.values.map(\.fields.title).sorted() } == ["Lunch", "Movie"])
        // Later writes don't open it again.
        engine.addEvent(to: pair.id, allDay("Again", 2026, 11, 22))
        await engine.refresh()
        #expect(server.get(\.writes).filter { $0 == "openPair" }.count == 1)
    }

    /// A sync that runs while the pair's opening is still held up (throttled)
    /// mustn't drop the pair, or what was added to it, from the screen.
    @Test func aSyncBeforeThePairOpensKeepsIt() async {
        let (engine, server, _) = makeEngine()
        let friend = server.addFriend()
        await engine.refresh()
        let pair = engine.pair(with: friend)!
        server.set { $0.failNextWrite = .slowDown }
        engine.addEvent(to: pair.id, allDay("Lunch", 2026, 11, 20))
        await engine.refresh() // OpenPair throttled; the sync still runs
        #expect(engine.pendingCount == 2)
        #expect(engine.occurrences(from: nov.0, through: nov.1).map(\.title) == ["Lunch"])
        await engine.refresh()
        #expect(engine.pendingCount == 0 && engine.pair(with: friend)?.listed == true)
        #expect(server.get { $0.events.values.map(\.fields.title) } == ["Lunch"])
    }

    @Test func hidingAPairNobodyOpenedOpensItFirst() async {
        let (engine, server, _) = makeEngine()
        let friend = server.addFriend()
        await engine.refresh()
        engine.setHidden(engine.pair(with: friend)!, true)
        #expect(engine.pair(with: friend)?.visible == false)
        await engine.refresh()
        #expect(server.get(\.writes) == ["openPair", "pref"])
        #expect(engine.pair(with: friend)?.visible == false && engine.pair(with: friend)?.listed == true)
    }

    @Test func aPairThatCantBeOpenedDropsItsWritesWithOneNotice() async {
        let (engine, server, _) = makeEngine()
        let friend = server.addFriend()
        await engine.refresh()
        let pair = engine.pair(with: friend)!
        server.set { $0.offline = true }
        engine.addEvent(to: pair.id, allDay("One", 2026, 11, 20))
        engine.addEvent(to: pair.id, allDay("Two", 2026, 11, 21))
        await engine.refresh()
        // Unfriended before the writes got out.
        server.set { $0.offline = false; $0.friends.removeAll() }
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(engine.notices.first?.message.contains("can't keep a calendar with this person") == true)
        #expect(engine.pendingCount == 0)
        #expect(engine.occurrences(from: nov.0, through: nov.1, includeHidden: true).isEmpty)
        #expect(!server.get(\.writes).contains("create"))
    }

    @Test func aFrozenPairRefusesWritesWithOneNoticeAndCantBeWrittenTo() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { s in s.calendars[0].frozen = false }
        server.set { $0.offline = true }
        engine.addEvent(to: own, allDay("One", 2026, 11, 20))
        engine.addEvent(to: own, allDay("Two", 2026, 11, 21))
        engine.addEvent(to: own, allDay("Three", 2026, 11, 22))
        await engine.refresh()
        // They unfriend meanwhile: the pair freezes.
        server.set { $0.offline = false; $0.calendars[0].frozen = true }
        await engine.refresh()
        #expect(engine.notices.count == 1, "one notice for the pair, not one per write")
        #expect(engine.notices.first?.message.contains("aren't friends any more") == true)
        #expect(engine.pendingCount == 0)
        #expect(engine.occurrences(from: nov.0, through: nov.1).isEmpty)
        #expect(engine.calendar(own)?.frozen == true)
        #expect(!engine.writableCalendars.contains { $0.id == own })
    }

    /// The server still takes a hide on a frozen pair: a hide queued beside
    /// refused writes isn't dropped with them.
    @Test func aFrozenPairKeepsAQueuedHide() async {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        server.set { $0.offline = true }
        engine.addEvent(to: own, allDay("One", 2026, 11, 20))
        engine.setHidden(engine.calendar(own)!, true)
        await engine.refresh()
        server.set { $0.offline = false; $0.calendars[0].frozen = true }
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(engine.pendingCount == 0)
        #expect(server.get(\.writes).last == "pref")
        #expect(server.get { $0.calendars[0].visible } == false)
        #expect(engine.calendar(own)?.visible == false)
    }

    @Test func aFocusedPairShowsEvenHiddenAndColorsByWhoAddedIt() async {
        let (engine, server, own) = makeEngine()
        _ = server.externalCreate(own, allDay("Theirs", 2026, 11, 10)) // the server's events are by the other person
        await engine.refresh()
        engine.addEvent(to: own, allDay("Mine", 2026, 11, 11))
        engine.setHidden(engine.calendar(own)!, true)
        await engine.refresh()
        #expect(engine.occurrences(from: nov.0, through: nov.1).isEmpty) // hidden from Everyone
        let focused = engine.occurrences(from: nov.0, through: nov.1, only: [own], byAuthor: true)
        #expect(Set(focused.map(\.title)) == ["Theirs", "Mine"])
        #expect(focused.first { $0.title == "Mine" }?.color == engine.accentColor)
        #expect(focused.first { $0.title == "Theirs" }?.color == engine.calendar(own)!.displayColor)
        #expect(engine.accentColor != engine.calendar(own)!.displayColor)
    }

    @Test func unlistedPairsSendNoCursor() throws {
        let store = try CalendarStore(userID: UUID(), appGroup: nil, inMemory: true)
        let listed = CalCalendar(id: UUID(), otherID: UUID())
        store.setCalendars([listed])
        store.putUnlistedPair(CalCalendar(id: UUID(), otherID: UUID()))
        #expect(Array(store.cursors().keys) == [listed.id])
        #expect(store.calendars().count == 2)
    }

    /// A phone updated from the per-person model: its stored calendars and a
    /// queued write of a removed kind can't be read. The store is wiped once
    /// on open (the server started fresh too), instead of wedging the queue.
    @Test func aStoreFromBeforePairsIsWipedOnOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ck-pairs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = UUID()
        do {
            let store = try CalendarStore(userID: me, appGroup: nil, directory: dir)
            let old = #"{"id":"\#(UUID().uuidString)","ownerID":"\#(me.uuidString)","name":"","color":"teal","role":"owner","rev":3,"visible":true,"prefColor":""}"#
            store.container.mainContext.insert(CalendarRecord(id: UUID(), payload: Data(old.utf8), cursor: 3, position: 0))
            store.container.mainContext.insert(PendingWriteRecord(id: UUID(), seq: 1, payload: Data(#"{"updateCalendar":{"name":"x"}}"#.utf8)))
            store.save()
            #expect(store.holdsAnOldModel())
        }
        let server = FakeServer(me: me)
        server.addPair()
        let engine = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me,
                                                           tokenProvider: { "t" }, storeDirectory: dir), transport: server)
        await engine.refresh()
        #expect(engine.pendingCount == 0)
        #expect(engine.calendars.count == 1 && engine.calendars[0].listed)
        #expect(engine.notices.isEmpty)
    }
}
