import XCTest

/// A look at the intimacy screens on whatever account it runs as (0.8.0 design
/// sprint, MVCALE-26). It only opens and closes things: nothing is saved, so it
/// can run against the seeded demo month. Skipped unless LOOK=1.
final class IntimacyLookUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOOK"] == "1", let token = env["CAL_DEV_TOKEN"], let user = env["CAL_DEV_USER"] else {
            throw XCTSkip("a look, run by hand with LOOK=1")
        }
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment = ["CAL_DEV_TOKEN": token, "CAL_DEV_USER": user, "LAB_START": "calendar"]
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testLook() {
        XCTAssert(app.buttons["addMenu"].waitForExistence(timeout: 10), "no + menu: no consented pair?")
        sleep(2)
        shot("1-month")
        app.buttons["kindFilter"].tap()
        app.buttons["Intimate"].firstMatch.tap()
        sleep(1)
        shot("2-month-intimate")
        app.buttons["kindFilter"].tap()
        app.buttons["All"].firstMatch.tap()
        app.buttons["addMenu"].tap()
        sleep(1)
        shot("3-add-menu")
        app.buttons["Intimate"].firstMatch.tap()
        sleep(1)
        shot("4-editor")
        app.swipeUp()
        shot("5-editor-more")
        app.swipeUp()
        shot("6-editor-end")
        app.buttons["Cancel"].tap()
        sleep(1)
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS 'private entr'")).firstMatch
        XCTAssert(day.waitForExistence(timeout: 5), "no day with a private entry")
        day.tap()
        sleep(1)
        shot("7-day")
        app.swipeUp()
        shot("8-day-more")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Private entry'")).firstMatch
        if row.exists {
            row.tap()
            sleep(1)
            shot("9-entry")
            app.buttons["Cancel"].tap()
        }
        let info = app.buttons["What the colors mean"].firstMatch
        if info.exists {
            info.tap()
            sleep(1)
            shot("10-legend")
            app.buttons["Done"].tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.segmentedControls.buttons["Agenda"].tap()
        sleep(1)
        shot("11-agenda")
        app.buttons["kindFilter"].tap()
        app.buttons["Intimate"].firstMatch.tap()
        sleep(1)
        shot("12-agenda-intimate")
        app.buttons["kindFilter"].tap()
        app.buttons["All"].firstMatch.tap()
        app.segmentedControls.buttons["Month"].tap()
    }
}
