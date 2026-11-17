import Foundation
import Testing
@testable import CalendarKit

/// MVCALE-28 (design sprint): the engine's cycle stream against a fake server
/// that keeps cycle days, settings, the cycle rev and the cycle reset the way
/// mvCalendar's store/cycle.go does.
@MainActor
@Suite("Cycle engine", .serialized)
struct CycleEngineTests {
    /// A pair with cycle on for both members, synced.
    private func consented() async -> (CalendarEngine, FakeServer, UUID) {
        let (engine, server, own) = makeEngine()
        server.externalCycleConsent(own, true)
        await engine.refresh()
        engine.setConsent(engine.calendar(own)!, .cycle, true)
        await engine.refresh()
        return (engine, server, own)
    }

    private func other(_ engine: CalendarEngine, _ cal: UUID) -> UUID { engine.calendar(cal)!.otherID }
    private func me(_ engine: CalendarEngine) -> UUID { engine.config.currentUserID }

    /// The other member writes a cycle day on the server.
    @discardableResult
    private func external(_ server: FakeServer, _ cal: UUID, person: UUID, _ date: CalDate, _ flow: CalFlow = .medium,
                          id: UUID = UUID(), deleted: Bool = false) -> CalCycleDay {
        var out: CalCycleDay!
        server.set { s in
            let r = (s.cycleRev[cal] ?? 0) + 1
            s.cycleRev[cal] = r
            out = CalCycleDay(id: id, calendarID: cal, personID: person, date: date, flow: flow, rev: r, deleted: deleted)
            s.cycleDays[id] = out
        }
        return out
    }

    private func externalSettings(_ server: FakeServer, _ st: CalCycleSettings) {
        server.set { s in
            let r = (s.cycleRev[st.calendarID] ?? 0) + 1
            s.cycleRev[st.calendarID] = r
            var q = st
            q.rev = r
            s.cycleSettings[CalPairID.make(st.calendarID, st.personID)] = q
        }
    }

    /// Cycle tracking is each person's own (MVCALE-51): mine shows as soon
    /// as I turn it on, whatever the other's switch says; theirs only once
    /// they turn theirs on, and a day for them before that isn't even sent.
    @Test func aPersonsCycleShowsOnceTheyTrackIt() async throws {
        let (engine, server, own) = makeEngine()
        await engine.refresh()
        engine.setConsent(try #require(engine.calendar(own)), .cycle, true)
        await engine.refresh()
        let cal = try #require(engine.calendar(own))
        let them = cal.otherID
        #expect(cal.cycleMine && !cal.cycleTheirs && cal.cycleOn)
        #expect(engine.cyclePeople(in: cal) == [me(engine)])
        #expect(engine.cycle(of: them, in: cal) == nil)
        engine.logCycleDay(in: cal, for: me(engine), on: CalDate(2026, 11, 1), flow: .heavy)
        engine.logCycleDay(in: cal, for: them, on: CalDate(2026, 11, 1), flow: .heavy)
        await engine.refresh()
        #expect(server.get { $0.cycleDays.values.map(\.personID) } == [me(engine)])
        #expect(engine.notices.isEmpty && engine.pendingCount == 0)
        #expect(engine.cycle(of: me(engine), in: cal)?.starts == [CalDate(2026, 11, 1)])
        // They turn theirs on: both of us now, and a day for them goes through.
        server.externalCycleConsent(own, true)
        await engine.refresh()
        let both = try #require(engine.calendar(own))
        #expect(engine.cyclePeople(in: both) == [me(engine), them])
        engine.logCycleDay(in: both, for: them, on: CalDate(2026, 11, 2), flow: .light)
        await engine.refresh()
        #expect(server.get(\.cycleDays).count == 2)
        #expect(engine.cycle(of: me(engine), in: both)?.starts == [CalDate(2026, 11, 1)]) // mine came back after the reload
    }

    @Test func theOtherMembersDaysAndSettingsArriveAndGo() async throws {
        let (engine, server, own) = await consented()
        let them = other(engine, own)
        let d1 = external(server, own, person: them, CalDate(2026, 10, 1), .heavy)
        external(server, own, person: them, CalDate(2026, 10, 29), .heavy)
        externalSettings(server, CalCycleSettings(calendarID: own, personID: them, cycleLength: 0, periodLength: 6))
        await engine.refresh()
        let cal = try #require(engine.calendar(own))
        #expect(engine.cyclePeople(in: cal) == [me(engine), them])
        let est = try #require(engine.cycle(of: them, in: cal))
        #expect(est.starts == [CalDate(2026, 10, 1), CalDate(2026, 10, 29)])
        #expect(est.cycleLength == 28)
        #expect(est.settings?.periodLength == 6)
        external(server, own, person: them, d1.date, id: d1.id, deleted: true)
        await engine.refresh()
        #expect(engine.cycle(of: them, in: cal)?.starts == [CalDate(2026, 10, 29)])
        #expect(engine.pendingCount == 0)
    }

    /// Either member logs for either (the server's rule); logging a day again
    /// changes its flow rather than adding a second row.
    @Test func eitherMemberLogsForEitherAndRelogsInPlace() async throws {
        let (engine, server, own) = await consented()
        let cal = try #require(engine.calendar(own))
        let them = cal.otherID
        engine.logCycleDay(in: cal, for: them, on: CalDate(2026, 11, 2), flow: .light)
        await engine.refresh()
        engine.logCycleDay(in: cal, for: them, on: CalDate(2026, 11, 2), flow: .heavy)
        await engine.refresh()
        #expect(server.get { $0.cycleDays.values.filter { !$0.deleted }.map(\.flow) } == [.heavy])
        #expect(engine.cycle(of: them, in: cal)?.info(on: CalDate(2026, 11, 2)).kind == .logged(.heavy))
        #expect(engine.cycle(of: me(engine), in: cal)?.days.isEmpty == true)
    }

    /// Someone outside the pair tracks nothing here: a day for them is never
    /// written or sent (the server would refuse it, InvalidArgument).
    @Test func aDayForAnOutsiderIsNeverSent() async throws {
        let (engine, server, own) = await consented()
        let cal = try #require(engine.calendar(own))
        let stranger = UUID()
        engine.logCycleDay(in: cal, for: stranger, on: CalDate(2026, 11, 3), flow: .medium)
        await engine.refresh()
        #expect(server.get(\.cycleDays).isEmpty)
        #expect(engine.notices.isEmpty)
        #expect(engine.cycle(of: stranger, in: cal) == nil)
        #expect(engine.pendingCount == 0)
    }

    @Test func aRemovalMadeOfflineLandsLater() async throws {
        let (engine, server, own) = await consented()
        let cal = try #require(engine.calendar(own))
        engine.logCycleDay(in: cal, for: me(engine), on: CalDate(2026, 11, 4), flow: .medium)
        await engine.refresh()
        let day = try #require(engine.cycle(of: me(engine), in: cal)?.days.first)
        server.set { $0.offline = true }
        engine.removeCycleDay(day)
        #expect(engine.cycle(of: me(engine), in: cal)?.days.isEmpty == true)
        await engine.refresh()
        #expect(engine.pendingCount == 1)
        server.set { $0.offline = false }
        await engine.refresh()
        #expect(engine.pendingCount == 0)
        #expect(server.get { $0.cycleDays[day.id]?.deleted } == true)
        #expect(engine.cycle(of: me(engine), in: cal)?.days.isEmpty == true)
    }

    @Test func settingsReachTheServerAndOneRowPerPerson() async throws {
        let (engine, server, own) = await consented()
        let cal = try #require(engine.calendar(own))
        engine.saveCycleSettings(CalCycleSettings(calendarID: own, personID: me(engine), cycleLength: 30, periodLength: 4))
        await engine.refresh()
        engine.saveCycleSettings(CalCycleSettings(calendarID: own, personID: me(engine), cycleLength: 31, periodLength: 4))
        await engine.refresh()
        #expect(server.get { $0.cycleSettings.values.map(\.cycleLength) } == [31])
        #expect(engine.cycle(of: me(engine), in: cal)?.cycleLength == 31)
        #expect(engine.cyclePeople(in: cal) == [me(engine), cal.otherID])
    }

    /// The cycle cursor moves with what was taken: a second sync asks only for
    /// what's newer, and the server's rows aren't taken twice.
    @Test func theCycleCursorMoves() async throws {
        let (engine, server, own) = await consented()
        external(server, own, person: other(engine, own), CalDate(2026, 10, 1), .heavy)
        await engine.refresh()
        let rev = server.get { $0.cycleRev[own] ?? 0 }
        #expect(rev > 0)
        #expect(engine.calendar(own)?.cycleCursor == rev)
        external(server, own, person: other(engine, own), CalDate(2026, 10, 29), .heavy)
        await engine.refresh()
        #expect(engine.calendar(own)?.cycleCursor == rev + 1)
        #expect(engine.cycle(of: other(engine, own), in: try #require(engine.calendar(own)))?.days.count == 2)
    }

    /// Cycle consent off clears the cycle rows only; intimate entries stay.
    /// And an intimate reset leaves the cycle rows.
    @Test func eachResetClearsOnlyItsOwnStream() async throws {
        let (engine, server, own) = await consented()
        server.externalConsent(own, true)
        engine.setConsent(try #require(engine.calendar(own)), .intimate, true)
        await engine.refresh()
        var c = CalPrivateContent(at: Date(timeIntervalSince1970: 1_794_841_200))
        c.solo = true
        engine.savePrivate(CalPrivateEntry(calendarID: own, content: c, createdBy: me(engine)))
        external(server, own, person: other(engine, own), CalDate(2026, 10, 1), .heavy)
        await engine.refresh()
        func entries() -> Int { engine.privateEntries(from: CalDate(2026, 11, 1), through: CalDate(2026, 11, 30)).count }
        func days() -> Int { engine.cycle(of: other(engine, own), in: engine.calendar(own)!)?.days.count ?? -1 }
        #expect(entries() == 1 && days() == 1)
        // Intimate off: entries go, the cycle stays.
        server.externalConsent(own, false)
        await engine.refresh()
        #expect(entries() == 0)
        #expect(days() == 1)
        // Cycle off: the cycle goes, and its cursor with it.
        server.externalConsent(own, true)
        server.externalCycleConsent(own, false)
        await engine.refresh()
        #expect(entries() == 1)
        #expect(engine.cycle(of: other(engine, own), in: engine.calendar(own)!) == nil)
        #expect(engine.calendar(own)?.cycleCursor == 0)
        // Back on: reloaded from scratch.
        server.externalCycleConsent(own, true)
        await engine.refresh()
        #expect(days() == 1)
    }

    /// A day for them queued offline, and they stop tracking before it
    /// lands: refused, removed here, one notice, nothing left queued.
    @Test func aQueuedDayAfterConsentWentOffIsDroppedWithANotice() async throws {
        let (engine, server, own) = await consented()
        let cal = try #require(engine.calendar(own))
        let them = cal.otherID
        server.set { $0.offline = true }
        engine.logCycleDay(in: cal, for: them, on: CalDate(2026, 11, 5), flow: .light)
        server.externalCycleConsent(own, false)
        server.set { $0.offline = false }
        await engine.refresh()
        await engine.refresh()
        #expect(server.get(\.cycleDays).isEmpty)
        #expect(engine.pendingCount == 0)
        #expect(engine.notices.count == 1)
        // Back on: nothing of the refused day comes back.
        server.externalCycleConsent(own, true)
        await engine.refresh()
        #expect(engine.cycle(of: them, in: try #require(engine.calendar(own)))?.days.isEmpty == true)
    }

    @Test func cycleRowsSurviveAReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = UUID()
        let server = FakeServer(me: me)
        let own = server.addCalendar(owner: me, role: .owner)
        func engine() -> CalendarEngine {
            CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: me,
                                                  tokenProvider: { "t" }, storeDirectory: dir), transport: server)
        }
        server.externalCycleConsent(own, true)
        let first = engine()
        await first.refresh()
        first.setConsent(try #require(first.calendar(own)), .cycle, true)
        await first.refresh()
        first.logCycleDay(in: try #require(first.calendar(own)), for: me, on: CalDate(2026, 11, 6), flow: .heavy)
        await first.refresh()
        first.stop()
        server.set { $0.offline = true }
        let second = engine()
        await second.refresh()
        #expect(second.cycle(of: me, in: try #require(second.calendar(own)))?.starts == [CalDate(2026, 11, 6)])
    }
}
