# CalendarKit

Swift client for **mvCalendar**: pair calendars, one for each pair of
friends, kept together. Connect
transport, the recurrence expander, a SwiftData cache with offline writes,
and the calendar UI. The host supplies identity and
a token provider, and never logs in through the kit. Swift 6, iOS 26.

Status: **0.7** (MVCALE-32, MVCALE-36): pair calendars and the day view, running in CalendarLab against the local stack. The design lives in
[`mvCalendar/docs/DESIGN.md`](../mvCalendar/docs/DESIGN.md).

## Using it (so far)

- **`CalendarConfig(baseURL:currentUserID:tokenProvider:appGroup:storeDirectory:refreshInterval:)`**
  is the injection seam. `storeDirectory` puts the local store in a folder the
  host chooses (for example one it keeps out of device backups); the kit creates
  it and keeps `Calendar-<user id>.store` there.
- **`CalendarTransport`** is a protocol, so tests and previews can fake the
  server; `ConnectCalendarTransport` is the real one. Errors come back as
  `CalTransportError`, sorted by what to do: `isRetryable` (unavailable, slow
  down, signed out) vs refused for good (not found, forbidden, invalid,
  exists, limit), and `.conflict(current:)` carries the server's copy of an
  event someone else changed first.
- **`CalendarEngine`** (`@MainActor @Observable`) is the coordinator. The host
  calls `start()` when the calendar is on screen, `stop()` when it goes away,
  and `wipeLocalStore()` on sign-out.
  - **A calendar belongs to two people** (`CalCalendar`: `otherID`, `frozen`,
    `visible`). There's no owner: either of them can change anything on it.
    Its id is computed from the two (`CalPairID.make`, the same UUIDv5 the
    server uses), so a friend's pair is in `calendars` from the contact list
    before anyone has opened it (`listed` false). Its first write (or a pref)
    opens it on the server first. `pair(with:)` finds one, and `person(of:)`
    names the other person (nil once they aren't a friend: "Someone").
  - A pair is **frozen** while the two aren't friends: readable, not
    writable. Writes already queued for it are dropped with one notice.
  - It keeps every pair in a per-user SwiftData store (in the host's App
    Group, or `storeDirectory`) and pulls changes per pair from a cursor. A
    store from before pair calendars is wiped once on open.
  - **Writes are local at once, then queued** and replayed in order before
    every sync (`addEvent`, `updateEvent`, `deleteEvent`, `updateOccurrence`,
    `deleteOccurrence`, `updateFollowing`, `setHidden`/`setVisible`,
    `setColor`, labels per pair). A write made offline waits; edits to something still
    waiting merge into it (create + edit = one create; create + delete =
    nothing sent).
  - **The server always wins.** A write it refuses for good, or one that lost
    a race with someone else's change, becomes a `CalNotice` ("Someone else
    changed “Dentist” first, so your change wasn't saved.") and its calendar
    is reloaded, so the cache never drifts. A sync never overwrites a local
    change still waiting.
  - `occurrences(from:through:zone:)` is what views draw: series expanded,
    exceptions applied, hidden pairs left out, colors resolved (event →
    label → the pair's, or inside one pair who added it).
  - `await refresh()` returns only once everything queued before the call
    has been tried; refreshes never overlap.
  - `contacts()` and a pair's `activity(of:)` are online only.
- **Look: "Together".** The family's living mesh backdrop (GarageKit's and
  LushKit's: neutral edges that follow light/dark, an opaque base, 12 fps,
  still under Reduce Motion), tinted by the calendars on screen, each color
  from its own side; Liquid Glass cards and buttons over it; the accent is the
  person's own color (`myColor`, kept on the device; unset = indigo).
- **Views.** The kit owns its content; **the host owns the navigation bar**
  (its title on the leading side, its own button on the trailing side
  pushing the kit's settings). Wording through
  `CalendarAppearance`.
  - **`CalendarView(engine:appearance:focus:)`**: a glass control row (Month
    / Agenda, and `+`; "Opens on" in the settings), then either the month
    (titles in each day, swipe or chevrons, Today) or the **agenda**:
    everything coming up from today grouped by day. Tapping a day, or an
    agenda day header, pushes that **day's view**, so **CalendarView needs a
    `NavigationStack` above it**. Tap an event → details (edit/delete, "this
    event / all future events" for a series); `+` → the editor. Notices as a
    banner; pull to refresh.
  - **Focus** (`CalFocus`: `.everyone` or `.person(id)`): with `focus` nil
    the kit shows its own picker (Everyone, each pair, the hidden ones) and
    remembers the pick per account. A binding hands it to the host and hides
    the picker: a conversation passes `.constant(.person(theirID))`. A
    focused pair shows even when hidden (with "Show it again"), and its
    events are colored by who added them.
  - **`CalendarSettingsView(engine:extra:)`**: pushed by the host. Your own
    color, "Opens on", each pair (show/hide, its color, and from its row its
    labels and activity), then the host's own sections (`extra`).
  - The host starts and stops the engine (CalendarLab: on appear/disappear
    and scene phase).
- **No reminders or notifications.** The calendar never announces itself
  outside the app: no local notifications, no badges, nothing on a lock
  screen (MVCALE-15). A test fails if the kit or the Lab touches
  UserNotifications.
- **`CalRecurrenceExpander`** turns a series into dates (`dates`) or instants
  (`instants`), offline, by the rules shared with the server.
- Types are prefixed `Cal` (`CalEvent`, `CalCalendar`, …) so nothing clashes
  with Foundation's `Calendar`.

## Development

- Tests: `xcodebuild test -scheme CalendarKit -destination 'platform=iOS Simulator,name=CalendarLab27'`.
  - **Golden recurrence cases**: `Tests/CalendarKitTests/Resources/recurrence-cases.json`
    is mvCalendar's `testdata/recurrence/cases.json` (answered by
    python-dateutil). Keep it byte-identical: mvCalendar's
    `scripts/recurrence_golden.py` copies it on regenerate and fails `--check`
    when it's stale.
  - **Engine** (`EngineTests`): against `FakeServer`, an in-memory mvCalendar
    (revs, tombstones, base-rev conflicts, latency, offline, refusals).
  - **Live** (`scripts/live-test.sh`): round trips through the real
    transport, and two real engines on one pair calendar (including a real
    lost race), against the local mvCalendar stack as two test accounts that
    are friends (never a real person's). It refuses if either already has a
    calendar locally and wipes both when done.
- **CalendarLab** (`Demo/`, xcodegen: `cd Demo && xcodegen generate`): real
  mvServer login via MvAuth (Local/Production), hosting the kit the way a
  production host does: a big leading title, and the account button pushing
  `CalendarSettingsView` with the Lab's account section as `extra`. Debug builds also accept a dev sign-in for the Local
  stack (launch environment `CAL_DEV_TOKEN` + `CAL_DEV_USER`, a token minted
  from the local key); it's compiled out of release builds.
  - **UI tests** (`scripts/ui-test.sh [account]`): drive the Lab like a
    person against the local stack as a test account (add, open, delete, a
    series' "all future" delete, the agenda and that it's remembered, the
    day view, "Opens on", the settings and their pairs) and export each screen's screenshot to
    `/tmp/calendarlab-shots`. Same refuse-if-data and wipe rules.
- Generated code in `Sources/CalendarKit/Generated` comes from mvCalendar:
  `buf generate --template buf.gen.swift.yaml` (run in `../mvCalendar`).
- Versions are tags; hosts pin "Up to Next Major".
