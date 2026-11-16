import Foundation
import Testing
@testable import CalendarKit

/// A store the phone's file protection keeps closed (locked) must neither
/// swallow writes nor survive a sign-out. A host may protect the store's folder
/// so the files can't be read while the phone is locked; then opening fails.
@MainActor
@Suite("Store protection", .serialized)
struct StoreProtectionTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "CalendarStoreProtectionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// An engine over a directory whose store file can't be opened (garbage
    /// stands in for a protected file), plus SQLite's sidecars.
    private func lockedEngine(_ dir: URL, user: UUID = UUID()) throws -> (CalendarEngine, FakeServer, [URL]) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appending(path: "Calendar-\(user.uuidString).store")
        let files = [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm")]
        for f in files { try Data("not a database".utf8).write(to: f) }
        let server = FakeServer(me: user)
        _ = server.addCalendar(owner: user, role: .owner)
        let engine = CalendarEngine(config: CalendarConfig(baseURL: URL(string: "http://fake")!, currentUserID: user,
                                                           tokenProvider: { "t" }, storeDirectory: dir), transport: server)
        return (engine, server, files)
    }

    @Test func signOutDeletesAStoreThatWontOpen() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (engine, _, files) = try lockedEngine(dir)
        engine.protectedDataAvailable = { false }
        engine.wipeLocalStore()
        for f in files { #expect(!FileManager.default.fileExists(atPath: f.path), "\(f.lastPathComponent) survived the sign-out") }
    }

    @Test func signOutDeletesTheFilesEvenAfterAnInMemoryStandIn() throws {
        // Unlocked but damaged: the engine carries on in memory, and a
        // sign-out must still remove what's on disk, not just the stand-in.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (engine, _, files) = try lockedEngine(dir)
        engine.protectedDataAvailable = { true }
        engine.start()
        engine.wipeLocalStore()
        for f in files { #expect(!FileManager.default.fileExists(atPath: f.path), "\(f.lastPathComponent) survived the sign-out") }
    }

    @Test func aLockedStoreTakesNoWritesAndOpensOnceUnlocked() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (engine, server, files) = try lockedEngine(dir)
        engine.protectedDataAvailable = { false }
        await engine.refresh()
        // Locked: nothing opened, so nothing can be written and lost.
        #expect(engine.calendars.isEmpty)
        #expect(engine.notices.map(\.message) == ["Unlock your phone to use the calendar."])
        await engine.refresh()
        #expect(engine.notices.count == 1, "the notice is shown once, not on every retry")
        // Unlocked: the real files are readable again (here: the garbage goes).
        for f in files { try FileManager.default.removeItem(at: f) }
        engine.protectedDataAvailable = { true }
        await engine.refresh()
        let own = try #require(engine.ownCalendar)
        _ = engine.addEvent(to: own.id, allDay("Dentist", 2026, 11, 10))
        await engine.refresh()
        #expect(server.get { $0.events.values.map(\.fields.title) } == ["Dentist"])
        #expect(FileManager.default.fileExists(atPath: files[0].path), "the store is on disk, not in memory")
    }
}
