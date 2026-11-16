import XCTest

/// The pair's privacy sheet (0.8.0 design sprint, MVCALE-26; Leaf's sheet,
/// Frond's tests). Needs scripts/ui-test.sh with CONSENT_FROM=<a friend>: the
/// script opens that pair with the friend's consents already on, so turning
/// ours on reaches "on for both".
final class PrivacyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["CAL_DEV_TOKEN"], let user = env["CAL_DEV_USER"],
              let friend = env["CONSENT_FROM"], !friend.isEmpty else {
            throw XCTSkip("run through scripts/ui-test.sh with CONSENT_FROM set")
        }
        continueAfterFailure = false
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

    /// Swipe until the element can be tapped.
    @discardableResult
    func reveal(_ e: XCUIElement) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable) {
            if e.exists && e.frame.maxY < window.minY + window.height * 0.25 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssert(e.exists && e.isHittable, "can't reach \(e)")
        return e
    }

    func waitFor(_ e: XCUIElement, label: String, _ timeout: TimeInterval = 10) {
        let p = NSPredicate(format: "label CONTAINS %@", label)
        let ok = XCTNSPredicateExpectation(predicate: p, object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [ok], timeout: timeout), .completed, "\(e) never said \(label): \(e.label)")
    }

    /// The pair's privacy page, from the calendar.
    func openPrivacy() {
        XCTAssert(app.buttons["Account"].waitForExistence(timeout: 15))
        app.buttons["Account"].tap()
        XCTAssert(app.navigationBars["Calendars"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Shown' OR label CONTAINS 'Hidden'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 10), "no pair in the settings")
        row.tap()
        let link = app.buttons["pair.privacy"]
        XCTAssert(link.waitForExistence(timeout: 5), "no Privacy on the pair's page")
        link.tap()
        XCTAssert(app.switches["privacy.intimate"].waitForExistence(timeout: 5), "the privacy sheet didn't open")
    }

    func testConsentPartnersAndCycleSettings() {
        openPrivacy()
        let intimate = app.switches["privacy.intimate"]
        let intimateState = app.staticTexts["privacy.intimate.state"]
        // The friend's is on already; ours is off.
        waitFor(intimateState, label: "turned it on")
        shot("p1-waiting-for-me")

        // On: on for both, and the partner list appears.
        intimate.switches.firstMatch.exists ? intimate.switches.firstMatch.tap() : intimate.tap()
        waitFor(intimateState, label: "On for both")
        let name = app.textFields["privacy.partner.name"]
        XCTAssert(reveal(name).exists)
        name.tap()
        name.typeText("UI Alex")
        app.buttons["privacy.partner.add"].tap()
        let alex = app.buttons["privacy.partner.UI Alex"].firstMatch
        XCTAssert(alex.waitForExistence(timeout: 5), "the partner wasn't added")
        shot("p2-partner-added")

        // Rename it and give it a color.
        alex.tap()
        let edit = app.textFields["privacy.partner.edit.name"]
        XCTAssert(edit.waitForExistence(timeout: 5), "no partner editor")
        edit.tap()
        edit.typeText(" B")
        app.buttons["privacy.partner.edit.save"].tap()
        let renamed = app.buttons["privacy.partner.UI Alex B"].firstMatch
        XCTAssert(renamed.waitForExistence(timeout: 5), "the rename didn't land")

        // Archive, then unarchive, from the swipe.
        renamed.swipeLeft()
        app.buttons["Archive"].tap()
        XCTAssert(renamed.staticTexts["Archived"].waitForExistence(timeout: 5)
                  || app.staticTexts["Archived"].waitForExistence(timeout: 1), "not archived")
        shot("p3-archived")
        renamed.swipeLeft()
        app.buttons["Unarchive"].tap()
        XCTAssert(app.staticTexts["Archived"].waitForNonExistence(timeout: 5), "still archived")

        // Cycle: on for both, then my own settings behind "Track my cycle too".
        let cycle = reveal(app.switches["privacy.cycle"])
        let cycleState = app.staticTexts["privacy.cycle.state"]
        cycle.switches.firstMatch.exists ? cycle.switches.firstMatch.tap() : cycle.tap()
        waitFor(cycleState, label: "On for both")
        reveal(app.buttons["privacy.cycle.mine"]).tap()
        let length = reveal(app.buttons["privacy.cycleLength.me"].firstMatch)
        XCTAssert(length.label.contains("Automatic"), length.label)
        length.tap()
        let pick = app.buttons["30 days"].firstMatch
        XCTAssert(pick.waitForExistence(timeout: 5), "no 30 days in the picker")
        pick.tap()
        waitFor(app.buttons["privacy.cycleLength.me"].firstMatch, label: "30")
        shot("p4-cycle")

        // Off again: the partner list goes with it. The switch is at the top.
        for _ in 0..<4 { app.swipeDown() }
        let back = reveal(app.switches["privacy.intimate"])
        back.switches.firstMatch.exists ? back.switches.firstMatch.tap() : back.tap()
        waitFor(intimateState, label: "turned it on")
        XCTAssert(app.textFields["privacy.partner.name"].waitForNonExistence(timeout: 5), "partners still shown with consent off")
        shot("p5-off")
    }
}
