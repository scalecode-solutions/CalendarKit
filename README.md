# CalendarKit

Swift client for **mvCalendar**: shared calendars between friends. Connect
transport, the recurrence expander, a SwiftData cache with offline writes,
and the calendar UI. The host supplies identity and
a token provider, and never logs in through the kit. Swift 6, iOS 26.

Status: **0.5** (MVCALE-15): engine, sync, offline writes, and the views, running in CalendarLab against the local stack. Not yet in a host. The design lives in
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
  - It keeps everything the person can see in a per-user SwiftData store (in
    the host's App Group) and pulls changes per calendar from a cursor.
  - **Writes are local at once, then queued** and replayed in order before
    every sync (`addEvent`, `updateEvent`, `deleteEvent`, `updateOccurrence`,
    `deleteOccurrence`, `updateFollowing`, `setVisible`,
    `setColor`, labels). A write made offline waits; edits to something still
    waiting merge into it (create + edit = one create; create + delete =
    nothing sent).
  - **The server always wins.** A write it refuses for good, or one that lost
    a race with someone else's change, becomes a `CalNotice` ("Someone else
    changed “Dentist” first, so your change wasn't saved.") and its calendar
    is reloaded, so the cache never drifts. A sync never overwrites a local
    change still waiting.
  - `occurrences(from:through:zone:)` is what views draw: series expanded,
    exceptions applied, hidden calendars left out, colors resolved (event →
    label → calendar).
  - `await refresh()` returns only once everything queued before the call
    has been tried; refreshes never overlap.
  - Sharing (`share`, `revoke`, `grants`, `contacts`, `activity`) is online
    only: it needs the server's answer.
- **Look: "Together".** The family's living mesh backdrop (GarageKit's and
  LushKit's: neutral edges that follow light/dark, an opaque base, 12 fps,
  still under Reduce Motion), tinted by the calendars on screen, each color
  from its own side; Liquid Glass cards and buttons over it; the accent is the
  person's own calendar color (no color set = indigo, everywhere).
- **Views.** The kit owns its content; **the host owns the navigation bar**
  (its title on the leading side, its own button on the trailing side
  pushing the kit's settings). Wording through
  `CalendarAppearance`.
  - **`CalendarView(engine:appearance:)`**: a glass control row (Month /
    Agenda, remembered on the device, and `+`), then either the month (a dot
    per calendar on each day, swipe or chevrons, Today) over the selected
    day's events, or the **agenda**: everything coming up from today grouped
    by day, empty days skipped, reaching further as you scroll. Each event in
    its color (event → label → calendar) with the avatar of whose calendar it
    is. Tap → details (edit/delete, "this event / all future events" for a
    series); `+` → the editor. Notices as a banner; pull to refresh.
  - **`CalendarSettingsView(engine:extra:)`**: pushed by the host. Show/hide
    and recolor each calendar; your calendar's name and color, labels,
    sharing (view by default, edit as a choice, optional end date), activity;
    then the host's own sections (`extra`).
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
    transport, and two real engines sharing one calendar (including a real
    lost race), against the local mvCalendar stack as two test accounts (owner +
    two test accounts, never a real person's). It refuses if either already has a
    calendar locally and wipes both when done.
- **CalendarLab** (`Demo/`, xcodegen: `cd Demo && xcodegen generate`): real
  mvServer login via MvAuth (Local/Production), hosting the kit the way a
  production host does: a big leading title, and the account button pushing
  `CalendarSettingsView` with the Lab's account section as `extra`. Debug builds also accept a dev sign-in for the Local
  stack (launch environment `CAL_DEV_TOKEN` + `CAL_DEV_USER`, a token minted
  from the local key); it's compiled out of release builds.
  - **UI tests** (`scripts/ui-test.sh [account]`): drive the Lab like a
    person against the local stack as a test account (add, open, delete, a
    series' "all future" delete, the agenda and that it's remembered,
    settings, sharing, the share picker offering friends) and export each screen's screenshot to
    `/tmp/calendarlab-shots`. Same refuse-if-data and wipe rules.
- Generated code in `Sources/CalendarKit/Generated` comes from mvCalendar:
  `buf generate --template buf.gen.swift.yaml` (run in `../mvCalendar`).
- Versions are tags; hosts pin "Up to Next Major".
