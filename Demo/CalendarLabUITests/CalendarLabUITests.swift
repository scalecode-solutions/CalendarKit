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
        app.launchEnvironment = ["CAL_DEV_TOKEN": token, "CAL_DEV_USER": user]
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

        // It's in today's list at once (before the server answers).
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

        // Calendars sheet, then sharing (loads from the server).
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        shot("5-calendars")
        app.buttons["Sharing"].tap()
        XCTAssert(app.navigationBars["Sharing"].waitForExistence(timeout: 5))
        sleep(2)
        shot("6-sharing")
        app.buttons["Share…"].tap()
        XCTAssert(app.navigationBars["Share"].waitForExistence(timeout: 5))
        sleep(1)
        shot("6b-share-with")
        // The account's friends in the local graph must be offered.
        sleep(2)
        XCTAssertFalse(app.staticTexts["No one else to share with."].exists, "friends not offered")
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
        row.tap()
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
        app.buttons["Month"].tap()
    }

    /// Read-only: opens the share picker and checks friends are offered.
    func testSharePickerOffersFriends() throws {
        XCTAssert(app.buttons["New Event"].waitForExistence(timeout: 15))
        app.buttons["Account"].tap()
        app.buttons["Sharing"].tap()
        XCTAssert(app.navigationBars["Sharing"].waitForExistence(timeout: 5))
        sleep(3)
        shot("9-sharing")
        app.buttons["Share…"].tap()
        XCTAssert(app.navigationBars["Share"].waitForExistence(timeout: 5))
        sleep(2)
        shot("9b-share-with")
        XCTAssertFalse(app.staticTexts["No one else to share with."].exists, "friends not offered")
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
    /// picker, the colour grid, the reminders row and its list, the detail's
    /// hero. Run it once in light and once in dark for the screenshots.
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
        reveal(app.buttons["Reminders"])
        shot("e2-editor-color-reminders")
        app.buttons["Reminders"].tap()
        XCTAssert(app.navigationBars["Reminders"].waitForExistence(timeout: 3))
        shot("e3-reminders-list")
        app.navigationBars["Reminders"].buttons.firstMatch.tap() // back
        app.navigationBars["New Event"].buttons["Add"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI test physio'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssert(app.navigationBars["Event"].waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts["Riverside Clinic"].exists)
        shot("e4-detail")
        reveal(app.buttons["Delete Event"]).tap()
        XCTAssert(app.buttons["Delete All Future Events"].waitForExistence(timeout: 3))
        app.buttons["Delete All Future Events"].tap()
        XCTAssert(row.waitForNonExistence(timeout: 5))
    }
}
