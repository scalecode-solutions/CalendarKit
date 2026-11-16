import Foundation
import Testing

/// MVCALE-27 step 1: the calendar never shows up anywhere outside the app.
/// Besides notifications (NoNotificationsTests), that means no Spotlight
/// results, no App Intents, Siri or Shortcuts, no widgets, and no Handoff or
/// other user activities that would put an event on another device or in the
/// system's suggestions. Intimate entries come later; this is in place before
/// anyone is tempted. Reads the sources from the checkout.
@Suite("No system surfaces")
struct NoSystemSurfacesTests {
    /// Core Spotlight and its CS types; App Intents, app shortcuts and app
    /// entities; SiriKit (the Intents framework and its IN types, and the
    /// Info.plist key); WidgetKit; user activities (Handoff, search and
    /// prediction eligibility, SwiftUI's modifiers, the Info.plist key).
    static var forbidden: Regex<AnyRegexOutput> {
        try! Regex(#"CoreSpotlight|\bCS[A-Z][a-z]\w*|\bAppIntents?\b|AppShortcut|AppEntity|\bimport Intents\b|\bIN[A-Z][a-z]\w*|WidgetKit|WidgetCenter|NSUserActivity|\.userActivity\(|onContinueUserActivity|isEligibleFor(Handoff|Search|Prediction|PublicIndexing)|becomeCurrent\(\)"#)
    }

    @Test func theKitAndTheLabNeverReachASystemSurface() throws {
        let files = NoNotificationsTests.swiftFiles(under: "Sources") + NoNotificationsTests.swiftFiles(under: "Demo")
            + [NoNotificationsTests.root.appending(path: "Package.swift")]
        // It must be reading the real tree, or it proves nothing.
        #expect(files.count > 20, "found only \(files.count) files under \(NoNotificationsTests.root.path)")
        let forbidden = Self.forbidden
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(forbidden) {
                hits.append("\(f.path.replacingOccurrences(of: NoNotificationsTests.root.path + "/", with: "")):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "A way out of the app in the kit or the Lab:\n\(hits.joined(separator: "\n"))")
    }

    /// The pattern itself: it catches what it's for and nothing else.
    @Test func thePatternCatchesSystemSurfacesOnly() {
        for bad in ["import CoreSpotlight", "CSSearchableIndex.default().indexSearchableItems(items)",
                    "let a = CSSearchableItemAttributeSet(contentType: .text)", "import AppIntents",
                    "struct OpenDay: AppIntent {", "struct Shortcuts: AppShortcutsProvider {", "struct DayEntity: AppEntity {",
                    "import Intents", "INInteraction(intent: i, response: nil).donate()", "INIntentsSupported:",
                    "import WidgetKit", "WidgetCenter.shared.reloadAllTimelines()", "let a = NSUserActivity(activityType: t)",
                    "NSUserActivityTypes:", ".userActivity(\"day\") { a in }", ".onContinueUserActivity(t) { _ in }",
                    "a.isEligibleForHandoff = true", "a.isEligibleForSearch = true", "a.isEligibleForPrediction = true",
                    "activity.becomeCurrent()"] {
            #expect(bad.contains(Self.forbidden), "\(bad)")
        }
        for fine in ["INSERT INTO events", "CSV", "let cs = 3", "UIColor.separator", "ActivityView(engine: engine)",
                     "func listActivity(", "struct CalActivity", "intent: the user's", "IN", "widget", "INTENT"] {
            #expect(!fine.contains(Self.forbidden), "\(fine)")
        }
    }
}
