import Foundation
import SwiftData
import Testing
@testable import CalendarKit

/// MVCALE-15: a store written by 0.4.0 (schema V1, with reminders) opens as
/// V2. Events, calendars and queued writes survive; reminder rows and queued
/// reminder writes are gone, and the queue drains.
@MainActor
@Suite("Store: V1 → V2 migration", .serialized)
struct StoreMigrationTests {
    @Test func aV1StoreOpensWithoutItsReminders() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ck-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Calendar.store")
        let enc = JSONEncoder()

        let calID = UUID(), eventID = UUID()
        let cal = CalCalendar(id: calID, otherID: UUID(), rev: 3, prefColor: .teal)
        let event = CalEvent(id: eventID, calendarID: calID,
                             fields: CalEventFields(title: "kept", when: .allDay(start: CalDate(2026, 11, 20), end: CalDate(2026, 11, 21))),
                             masterID: nil, originalStart: nil, cancelled: false, createdBy: cal.otherID, updatedBy: cal.otherID,
                             createdAt: Date(), updatedAt: Date(), rev: 0, deleted: false)
        let lastSync = Date(timeIntervalSince1970: 1_800_000_000)
        // What 0.4.0 queued: a reminder write, its defaults, and a real write.
        // Their encoded shape, as the removed cases wrote it.
        let alertsWrite = #"{"alerts":{"eventID":"\#(eventID.uuidString)","minutes":[15]}}"#
        let defaultsWrite = #"{"alertDefaults":{"_0":{"timed":[10],"allDay":[900]}}}"#
        let realWrite = try enc.encode(PendingWrite.pref(calendarID: calID, visible: false, color: .pink))

        do { // write it as V1
            let schema = Schema(versionedSchema: CalendarSchemaV1.self)
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration("v1", schema: schema, url: url))
            let ctx = c.mainContext
            ctx.insert(CalendarRecord(id: calID, payload: try enc.encode(cal), cursor: 3, position: 0))
            ctx.insert(EventRecord(event, payload: try enc.encode(event), pending: false))
            ctx.insert(CalendarSchemaV1.AlertRecord(eventID: eventID, payload: Data(#"{"minutesBefore":[15]}"#.utf8)))
            let st = CalendarSchemaV1.SyncStateRecord(alertsCursor: 9, defaults: Data("{}".utf8))
            st.lastSync = lastSync
            ctx.insert(st)
            ctx.insert(PendingWriteRecord(id: UUID(), seq: 1, payload: Data(alertsWrite.utf8)))
            ctx.insert(PendingWriteRecord(id: UUID(), seq: 2, payload: Data(defaultsWrite.utf8)))
            ctx.insert(PendingWriteRecord(id: UUID(), seq: 3, payload: realWrite))
            try ctx.save()
        }

        let store = try CalendarStore(userID: UUID(), appGroup: nil, url: url)
        #expect(store.calendars().map(\.0.id) == [calID])
        #expect(store.calendars().first?.cursor == 3)
        #expect(store.event(eventID)?.fields.title == "kept")
        #expect(store.lastSync == lastSync)
        // Only the real write is left, and nothing undecodable sits behind it.
        #expect(store.pendingCount == 1)
        #expect(store.pending().map(\.1) == [.pref(calendarID: calID, visible: false, color: .pink)])
    }

    /// The migration's test for a removed case, by its encoded name only.
    @Test func reminderWritesAreRecognisedByTheirCaseName() throws {
        #expect(PendingWrite.isRemovedReminderWrite(Data(#"{"alerts":{"eventID":"x","minutes":[]}}"#.utf8)))
        #expect(PendingWrite.isRemovedReminderWrite(Data(#"{"alertDefaults":{"_0":{}}}"#.utf8)))
        let pref = try JSONEncoder().encode(PendingWrite.pref(calendarID: UUID(), visible: true, color: .none))
        #expect(!PendingWrite.isRemovedReminderWrite(pref))
        #expect(!PendingWrite.isRemovedReminderWrite(Data("not json".utf8)))
    }
}
