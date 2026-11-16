import SwiftUI
import CalendarKit

/// Owns the Lab's one `CalendarEngine` and runs it only while a calendar is on
/// screen and the app is in the foreground — the shape a production host uses
/// (one engine per signed-in person, many entry points holding it).
///
/// Every calendar surface holds it for as long as it's visible (`holdsCalendar`);
/// holds are counted, so the Home tile and a conversation's calendar can't fight.
@MainActor
@Observable
final class LabSession {
    let engine: CalendarEngine
    /// True while the engine is refreshing (held and in the foreground).
    private(set) var isRunning = false

    private var holders = 0
    private var foreground = true

    init(engine: CalendarEngine) {
        self.engine = engine
    }

    /// A calendar surface appeared.
    func acquire() {
        holders += 1
        sync()
    }

    /// A calendar surface went away: stop when the last one goes.
    func release() {
        holders = max(0, holders - 1)
        sync()
    }

    /// Hold the engine for as long as the caller's task lives.
    func run() async {
        acquire()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        release()
    }

    /// The scene went to the background (false) or came back (true). Driven
    /// from the app's scene phase, not from a screen, so a screen torn down
    /// while backgrounded can't leave it stuck.
    func setForeground(_ on: Bool) {
        foreground = on
        sync()
    }

    /// Sign-out: stop and delete this person's cache and queued writes.
    func wipe() {
        engine.wipeLocalStore()
        isRunning = false
    }

    private func sync() {
        let shouldRun = holders > 0 && foreground
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun { engine.start() } else { engine.stop() }
    }
}

extension View {
    /// Keep the calendar running while this view is on screen. A pushed screen's
    /// task is cancelled when it's popped, which releases the hold.
    func holdsCalendar(_ session: LabSession) -> some View {
        task { await session.run() }
    }
}
