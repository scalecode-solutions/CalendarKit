import SwiftUI
import CalendarKit

/// Owns the Lab's one `CalendarEngine` and runs it only while a calendar is on
/// screen and the app is in the foreground — the shape a production host uses
/// (one engine per signed-in person, many entry points holding it).
///
/// Every calendar screen holds it for as long as the screen is in its navigation
/// stack (`LabCalendarHold`); holds are counted, so the Home tile and a
/// conversation's calendar can't fight.
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

/// Keeps the calendar running while a screen is anywhere in its navigation
/// stack, including while the day view or the settings are pushed over it.
///
/// A `.task` won't do: a NavigationStack treats a screen covered by a push as
/// disappeared, which cancelled the hold and stopped syncing whenever the day
/// view was open (Leaf's review). Held in the screen's `@State` instead: SwiftUI
/// keeps that storage while the screen is in the stack and frees it when the
/// screen is popped or the stack is torn down. `arm` runs from `onAppear`, so the
/// throwaway copies SwiftUI makes of a view's initial state never touch the
/// session. A production host's screen hold has the same shape.
@MainActor
final class LabCalendarHold {
    private var session: LabSession?

    /// The first call acquires; later ones (reappearing from under a push) do nothing.
    func arm(_ session: LabSession) {
        guard self.session == nil else { return }
        self.session = session
        session.acquire()
    }

    isolated deinit {
        session?.release()
    }
}
