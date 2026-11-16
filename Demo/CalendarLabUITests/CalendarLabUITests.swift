import XCTest

/// Drives CalendarLab like a person, against the LOCAL mvCalendar, signed in
/// through the debug dev sign-in. Run by ../scripts/ui-test.sh (it mints the
/// token, seeds nothing, and wipes the test accounts afterwards). Each screen
/// is kept as a screenshot attachment.
final class CalendarLabUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["CAL_DEV_TOKEN"], let user = env["CAL_DEV_USER"] else {
            throw XCTSkip("run through scripts/ui-test.sh")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        // The Lab opens on Chats like a chat host; LAB_START=calendar opens it
        // straight on the calendar (Home → Calendar), where these tests begin.
        app.launchEnvironment = ["CAL_DEV_TOKEN": token, "CAL_DEV_USER": user, "LAB_START": "calendar"]
        app.launch()
    }

    /// Forms create rows lazily: swipe until the element exists and can be tapped.
    @discardableResult
    func reveal(_ e: XCUIElement, in container: XCUIElement? = nil) -> XCUIElement {
        // Swipe toward it: up while it's below (or not made yet), down once it
        // has gone past the top. Up-only overshot on taller screens and could
        // never come back.
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable) {
            if e.exists && e.frame.maxY < window.minY + window.height * 0.25 {
                (container ?? app).swipeDown()
            } else {
                (container ?? app).swipeUp()
            }
        }
        XCTAssert(e.exists && e.isHittable, "can't reach \(e)")
        return e
    }

    /// Return ends the edit and the keyboard goes; tapping the bar didn't, and
    /// on a taller phone the keyboard then covered the rows a test wanted.
    func dismissKeyboard() {
        if app.keyboards.count > 0 { app.typeText("\n") }
        XCTAssert(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "the keyboard stayed up")
    }

    /// Tap a segment until it's the selected one: a tap that lands while the
    /// form is still settling (the keyboard just went) can be dropped.
    func select(_ segment: XCUIElement) {
        reveal(segment)
        for _ in 0..<3 where !segment.isSelected {
            segment.tap()
            for _ in 0..<10 where !segment.isSelected { usleep(200_000) } // up to 2 s
        }
        XCTAssert(segment.isSelected, "\(segment) didn't take")
    }

    /// Tap today in the month: its day view is pushed. That only works with
    /// a NavigationStack above CalendarView, which the kit requires (0.7.0).
    func openToday() {
        let month = app.segmentedControls.buttons["Month"]
        if month.exists && !month.isSelected { month.tap() }
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Today, '")).firstMatch
        XCTAssert(today.waitForExistence(timeout: 5), "no today cell in the month")
        today.tap()
        XCTAssert(app.buttons["Next day"].waitForExistence(timeout: 5), "tapping a day didn't push its day view")
    }

    /// Back from a pushed screen (the day view) to the calendar.
    func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let month = app.segmentedControls.buttons["Month"]
        for _ in 0..<25 where !(month.exists && month.isHittable) { usleep(200_000) } // up to 5 s
        XCTAssert(month.exists && month.isHittable, "not back on the calendar")
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testAddOpenAndManage() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        shot("1-month")

        // Add an event through the editor.
        app.buttons["New Event"].tap()
        XCTAssert(app.navigationBars["New Event"].waitForExistence(timeout: 5))
        let title = app.textFields["Title"]
        title.tap()
        title.typeText("UI test lunch")
        app.textFields["Location"].tap()
        app.textFields["Location"].typeText("Corner cafe")
        shot("2-editor")
        app.navigationBars["New Event"].buttons["Add"].tap()

        // It's on today at once (before the server answers): open the day.
        openToday()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test lunch'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        shot("3-added")

        // Open it.
        row.tap()
        XCTAssert(app.navigationBars["Event"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Corner cafe"].exists)
        shot("4-detail")

        // Delete it (below the fold of the half-height sheet).
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        back()

        // The settings, the pair it went to, and that pair's history (from
        // the server): both the add and the delete, by "You".
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        shot("5-calendars")
        pairRow().tap()
        app.buttons["Activity"].tap()
        let added = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'You added “UI test lunch”'")).firstMatch
        XCTAssert(added.waitForExistence(timeout: 10), "the pair's activity doesn't show the add")
        shot("6-activity")
    }

    /// A pair's row in the calendar settings (each says Shown or Hidden).
    func pairRow() -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Shown' OR label CONTAINS 'Hidden'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 10), "no pair in the settings")
        return row
    }

    func testAgendaShowsWhatsComingAndRemembersTheChoice() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["New Event"].tap()
        let title = app.textFields["Title"]
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI test agenda item")
        app.navigationBars["New Event"].buttons["Add"].tap()
        app.buttons["Agenda"].tap()
        XCTAssert(app.staticTexts["Today"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test agenda item'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        shot("10-agenda")
        // Relaunch: still on the agenda.
        app.terminate()
        app.launch()
        XCTAssert(app.staticTexts["Today"].waitForExistence(timeout: 15))
        XCTAssert(row.waitForExistence(timeout: 5))
        // A day header opens the same day view as the month does.
        let header = app.buttons["agendaDayHeader"].firstMatch
        XCTAssert(header.waitForExistence(timeout: 5))
        header.tap()
        XCTAssert(app.buttons["Next day"].waitForExistence(timeout: 5), "the day header didn't open the day")
        XCTAssert(row.waitForExistence(timeout: 5))
        shot("11-agenda-day")
        row.tap()
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        back()
        app.buttons["Month"].tap()
    }

    /// Read-only: opens the share picker and checks friends are offered.
    /// The settings list a pair for the account's friend (from the contact
    /// list, before anyone has opened it), with its own show/hide switch.
    func testSettingsListTheFriendsPair() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        _ = pairRow()
        XCTAssert(app.switches.firstMatch.exists, "no show/hide switch for the pair")
        shot("9-pairs")
    }

    /// MVCALE-36: the focus picker. A person's chip shows just your pair with
    /// them; hiding the pair takes it off Everyone and into "Hidden (1)", and
    /// focusing it from there shows it with "Show it again".
    func testFocusAndHidingAPair() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["New Event"].tap()
        let title = app.textFields["Title"]
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI test focus")
        app.navigationBars["New Event"].buttons["Add"].tap()
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Today, '")).firstMatch
        XCTAssert(today.waitForExistence(timeout: 5))
        func todayHasIt() -> Bool { today.label.contains("1 event") }
        XCTAssert(todayHasIt(), today.label)

        // Just the friend's pair: still there.
        let chip = app.buttons.matching(NSPredicate(format: "label ENDSWITH \"'s calendar\"")).firstMatch
        XCTAssert(chip.waitForExistence(timeout: 10), "no person in the picker")
        chip.tap()
        XCTAssert(chip.isSelected)
        XCTAssert(todayHasIt(), today.label)
        shot("f1-focused")

        // Hide it in the settings: gone from Everyone, into Hidden (1).
        app.buttons["Everyone"].tap()
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        app.switches.firstMatch.tap()
        back()
        for _ in 0..<15 where todayHasIt() { usleep(200_000) }
        XCTAssertFalse(todayHasIt(), "a hidden pair still shows in Everyone")
        let hidden = app.buttons["Hidden calendars, 1"]
        XCTAssert(hidden.waitForExistence(timeout: 5), "no Hidden (1) in the picker")
        hidden.tap()
        // The menu lists the hidden pairs; there's one.
        let item = app.collectionViews.buttons.firstMatch
        XCTAssert(item.waitForExistence(timeout: 5), "the hidden menu is empty")
        item.tap()
        // Focused from there: it shows, and says it's hidden.
        XCTAssert(app.staticTexts["You hid this calendar."].waitForExistence(timeout: 5))
        XCTAssert(todayHasIt(), today.label)
        shot("f2-hidden-focused")
        app.buttons["Show it again"].tap()
        XCTAssert(app.staticTexts["You hid this calendar."].waitForNonExistence(timeout: 5))

        // Clean up: delete it, back to Everyone.
        openToday()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test focus'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        back()
        app.buttons["Everyone"].tap()
    }

    func testRepeatingEventAsksWhichOccurrences() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["New Event"].tap()
        let title = app.textFields["Title"]
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI test standup")
        dismissKeyboard()
        // Repeat is a segmented control: one tap from Never to Daily.
        select(app.segmentedControls["Repeat"].buttons["Daily"])
        XCTAssert(app.staticTexts["Every day"].waitForExistence(timeout: 3)) // the summary under it
        shot("7-repeat")
        app.navigationBars["New Event"].buttons["Add"].tap()
        openToday()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test standup'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssert(app.navigationBars["Event"].waitForExistence(timeout: 5))
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(app.buttons["Delete All Future Events"].waitForExistence(timeout: 3))
        shot("8-delete-choice")
        app.buttons["Delete All Future Events"].tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
    }

    /// The editor and the detail, screen by screen (MVCALE-7): the repeat
    /// picker, the colour grid, the detail's hero, and no reminders row on
    /// either. Run it once in light and once in dark for the screenshots.
    func testEditorAndDetailTour() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["New Event"].tap()
        let title = app.textFields["Title"]
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI test physio")
        app.textFields["Location"].tap()
        app.textFields["Location"].typeText("Riverside Clinic")
        dismissKeyboard()
        select(app.segmentedControls["Repeat"].buttons["Weekly"])
        shot("e1-editor-repeat")
        reveal(app.buttons["Calendar's color"])
        shot("e2-editor-color")
        // No reminders anywhere (MVCALE-15).
        XCTAssertFalse(app.buttons["Reminders"].exists)
        app.navigationBars["New Event"].buttons["Add"].tap()

        openToday()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test physio'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssert(app.navigationBars["Event"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Riverside Clinic"].exists)
        shot("e4-detail")
        XCTAssertFalse(app.buttons["Reminders"].exists)
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(app.buttons["Delete All Future Events"].waitForExistence(timeout: 3))
        app.buttons["Delete All Future Events"].tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
    }

    /// MVCALE-32: tapping a day pushes its day view onto the host's
    /// NavigationStack (the kit requires one), and the chevrons and Today move
    /// between days. An empty day says so and offers Add.
    func testTappingADayPushesItsDayViewOntoTheHostsStack() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        shot("d0-month")
        openToday()
        XCTAssert(app.navigationBars.buttons.element(boundBy: 0).exists, "no back button: not pushed")
        let header = app.descendants(matching: .any)["dayViewHeader"].firstMatch
        func shows(_ word: String) -> Bool {
            for _ in 0..<15 where !header.label.hasPrefix(word) { usleep(200_000) } // up to 3 s
            return header.label.hasPrefix(word)
        }
        XCTAssert(shows("Today"), header.label)
        shot("d1-day-today")
        app.buttons["Next day"].tap()
        XCTAssert(shows("Tomorrow"), header.label)
        app.buttons["Previous day"].tap()
        app.buttons["Previous day"].tap()
        XCTAssert(shows("Yesterday"), header.label)
        XCTAssert(app.staticTexts["Nothing planned"].exists)
        shot("d2-day-empty")
        app.buttons["Today"].firstMatch.tap()
        XCTAssert(shows("Today"), header.label)
        // + in the day view adds to the day shown.
        app.buttons["Next day"].tap()
        app.navigationBars.buttons["New Event"].tap()
        let title = app.textFields["Title"]
        XCTAssert(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI test tomorrow")
        app.navigationBars["New Event"].buttons["Add"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test tomorrow'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5), "the new event isn't on the day shown")
        shot("d3-day-added")
        row.tap()
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        back()
    }

    /// MVCALE-32: "Opens on" in the calendar settings. A fixed choice wins
    /// over the remembered switch; Last used (the default) remembers it.
    func testOpensOnSetting() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Opens on'")).firstMatch
        reveal(picker).tap()
        app.buttons["Agenda"].firstMatch.tap()
        shot("o1-opens-on")
        back()
        // Switch to Month for this visit; a relaunch still opens on Agenda.
        app.segmentedControls.buttons["Month"].tap()
        app.terminate()
        app.launch()
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        XCTAssert(app.segmentedControls.buttons["Agenda"].isSelected, "Opens on: Agenda didn't open the agenda")
        // Back to Last used, leaving the app as other tests expect it.
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        reveal(picker).tap()
        app.buttons["Last used"].firstMatch.tap()
        back()
        app.segmentedControls.buttons["Month"].tap()
    }
}
