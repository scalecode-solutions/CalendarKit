import Foundation
import Testing

/// MVCALE-15: nothing on this calendar announces itself outside the app. The
/// kit and the Lab never touch UserNotifications, and none of the other ways
/// onto a lock screen or home screen: no local or remote notifications, no
/// badges, no Live Activities, no system-calendar alarms, no permission prompt. A host's stealth rules can't be bypassed by
/// a kit that has no way to make noise. Reads the sources from the checkout.
@Suite("No notifications")
struct NoNotificationsTests {
    /// The package root, from this file's path (Tests/CalendarKitTests/…).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `UserNotifications` or any of its types (UN + a capitalised word:
    /// UNUserNotificationCenter, UNCalendarNotificationTrigger, …; UNIQUE and
    /// the like don't match); remote notifications; badges; ActivityKit (Live
    /// Activities); EventKit (an EKAlarm on a system calendar rings too).
    static var forbidden: Regex<AnyRegexOutput> {
        try! Regex(#"UserNotifications|\bUN[A-Z][a-z]\w*|registerForRemoteNotifications|[Bb]adgeCount|applicationIconBadgeNumber|ActivityKit|\bActivity<|ActivityAttributes|\bEventKit\b|\bEK[A-Z][a-z]\w*"#)
    }

    static func swiftFiles(under dir: String) -> [URL] {
        let base = root.appending(path: dir)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" || $0.lastPathComponent == "project.yml" }
    }

    @Test func theKitAndTheLabNeverTouchUserNotifications() throws {
        let files = Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Demo") + [Self.root.appending(path: "Package.swift")]
        // It must be reading the real tree, or it proves nothing.
        #expect(files.count > 20, "found only \(files.count) files under \(Self.root.path)")
        let forbidden = Self.forbidden
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(forbidden) {
                hits.append("\(f.path.replacingOccurrences(of: Self.root.path + "/", with: "")):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "UserNotifications in the kit or the Lab:\n\(hits.joined(separator: "\n"))")
    }

    /// The pattern itself: it catches what it's for and nothing else.
    @Test func thePatternCatchesNotificationAPIsOnly() {
        for bad in ["import UserNotifications", "UNUserNotificationCenter.current()", "let r: UNNotificationRequest",
                    "UNCalendarNotificationTrigger(dateMatching: c, repeats: false)", "UNMutableNotificationContent()",
                    "UIApplication.shared.registerForRemoteNotifications()", "try await center.setBadgeCount(3)",
                    "app.applicationIconBadgeNumber = 1", "import ActivityKit", "try Activity<Ride>.request(attributes: a, content: c)",
                    "struct Ride: ActivityAttributes", "import EventKit", "EKEventStore()", "EKAlarm(relativeOffset: -900)"] {
            #expect(bad.contains(Self.forbidden), "\(bad)")
        }
        for fine in ["UNIQUE", "case unknown", "UInt", "// unavailable", "UNKNOWN_ERROR", "ActivityView(engine: engine)",
                     "struct CalActivity", "func listActivity(", "EKG", "the badge on the chip"] {
            #expect(!fine.contains(Self.forbidden), "\(fine)")
        }
    }
}
