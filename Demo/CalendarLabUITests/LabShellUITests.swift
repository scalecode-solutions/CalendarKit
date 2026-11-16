import XCTest

/// The Lab's host shell (MVCALE-34): the calendar is reached the way a chat app
/// reaches it, and backing out lands where you came from. Run against the LOCAL
/// stack through the debug dev sign-in, with LAB_FRIEND set to one of the
/// account's local friends (a test account's id):
///
///   TEST_RUNNER_CAL_DEV_TOKEN=… TEST_RUNNER_CAL_DEV_USER=… TEST_RUNNER_LAB_FRIEND=… \
///     xcodebuild test … -only-testing:CalendarLabUITests/LabShellUITests
final class LabShellUITests: XCTestCase {
    var app: XCUIApplication!
    var friend = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["CAL_DEV_TOKEN"], let user = env["CAL_DEV_USER"], let friend = env["LAB_FRIEND"] else {
            throw XCTSkip("needs CAL_DEV_TOKEN, CAL_DEV_USER and LAB_FRIEND")
        }
        self.friend = friend.lowercased()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["CAL_DEV_TOKEN": token, "CAL_DEV_USER": user]
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The calendar's own control row is on screen.
    func assertCalendarShowing(_ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssert(app.buttons["Month"].waitForExistence(timeout: 10), "the calendar didn't show", file: file, line: line)
    }

    /// Conversation → header button → the calendar is pushed in the
    /// conversation's stack → back returns to the conversation, still on Chats.
    func testConversationPushesTheCalendarAndBackReturnsToIt() {
        let row = app.buttons["chat.\(friend)"]
        XCTAssert(row.waitForExistence(timeout: 15), "the friend isn't in Chats")
        row.tap()

        let calendarButton = app.buttons["conversation.calendar"]
        XCTAssert(calendarButton.waitForExistence(timeout: 5), "no calendar button in the conversation's header")
        shot("conversation")
        calendarButton.tap()

        assertCalendarShowing()
        shot("conversation-calendar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(calendarButton.waitForExistence(timeout: 5), "back didn't land in the conversation")
        XCTAssert(app.tabBars.buttons["Chats"].isSelected, "the tab changed")
    }

    /// Home tile → the all-calendars view → back returns to Home.
    func testHomeTileOpensTheCalendar() {
        app.tabBars.buttons["Home"].tap()
        let tile = app.buttons["home.calendar"]
        XCTAssert(tile.waitForExistence(timeout: 5), "no calendar tile on Home")
        tile.tap()

        assertCalendarShowing()
        shot("home-calendar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(tile.waitForExistence(timeout: 5), "back didn't land on Home")
    }

    /// `LAB_START=calendar` (the kit's UI tests' entry) opens on the calendar,
    /// pushed under Home, so back still lands on Home.
    func testLabStartCalendarOpensOnTheCalendar() {
        app.terminate()
        app.launchEnvironment["LAB_START"] = "calendar"
        app.launch()

        assertCalendarShowing()
        XCTAssert(app.tabBars.buttons["Home"].isSelected, "LAB_START=calendar didn't open under Home")
        shot("lab-start-calendar")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(app.buttons["home.calendar"].waitForExistence(timeout: 5), "back didn't land on Home")
    }

    /// Settings carries the kit's settings with the Lab's account rows.
    func testSettingsHasTheAccountRows() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssert(app.buttons["Sign out"].waitForExistence(timeout: 5) || app.staticTexts["Account"].exists,
                  "no account rows in Settings")
        shot("settings")
    }
}
