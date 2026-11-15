import Foundation
import Testing
@testable import CalendarKit

/// `CalendarConfig.storeDirectory`: the host can say where the local store lives
/// (e.g. a folder it keeps out of device backups), and the files land there.
@MainActor
@Suite("Store location", .serialized)
struct StoreLocationTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "CalendarStoreLocationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func storeLandsInTheGivenDirectoryAndCreatesIt() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "Nested/Calendar", directoryHint: .isDirectory)
        let user = UUID()

        let store = try CalendarStore(userID: user, appGroup: nil, directory: dir)
        store.lastSync = Date(timeIntervalSince1970: 1_000)
        store.save()

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Calendar-\(user.uuidString).store").path))
    }

    @Test func reopeningTheSameDirectoryKeepsTheCache() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = UUID()
        let when = Date(timeIntervalSince1970: 2_000)
        do {
            let store = try CalendarStore(userID: user, appGroup: nil, directory: dir)
            store.lastSync = when
            store.save()
        }
        #expect(try CalendarStore(userID: user, appGroup: nil, directory: dir).lastSync == when)
    }

    @Test func configCarriesTheDirectoryAndDefaultsToNil() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let url = URL(string: "https://example.com")!
        #expect(CalendarConfig(baseURL: url, currentUserID: UUID(), tokenProvider: { nil },
                               storeDirectory: dir).storeDirectory == dir)
        #expect(CalendarConfig(baseURL: url, currentUserID: UUID(), tokenProvider: { nil }).storeDirectory == nil)
    }
}
