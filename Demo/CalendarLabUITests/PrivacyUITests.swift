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

    /// The pair's privacy page, from the conversation's settings.
    func openPrivacy() {
        // A pair's settings live with the conversation (design review, 2026-11-16):
        // Chats → the friend → tap the name → Calendar → Privacy.
        let friend = ProcessInfo.processInfo.environment["CONSENT_FROM"]!.lowercased()
        app.tabBars.buttons["Chats"].tap()
        let chat = app.buttons["chat.\(friend)"]
        XCTAssert(chat.waitForExistence(timeout: 15), "the friend isn't in Chats")
        chat.tap()
        let name = app.buttons["conversation.settings"]
        XCTAssert(name.waitForExistence(timeout: 5), "the name isn't a button")
        name.tap()
        let calendar = app.buttons["conversation.settings.calendar"]
        XCTAssert(calendar.waitForExistence(timeout: 5), "no Calendar in the conversation's settings")
        calendar.tap()
        let link = app.buttons["pair.privacy"]
        XCTAssert(link.waitForExistence(timeout: 10), "no Privacy on the pair's page")
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

        // On: on for both (the line goes; the switch says it), and my
        // partner list appears.
        intimate.switches.firstMatch.exists ? intimate.switches.firstMatch.tap() : intimate.tap()
        XCTAssert(intimateState.waitForNonExistence(timeout: 10), "a line under the switch when both are on")
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

        // My default partner: picked from the list, mine alone.
        let def = reveal(app.buttons["privacy.partner.default"].firstMatch)
        XCTAssert(def.label.contains("None"), def.label)
        def.tap()
        let choice = app.buttons["UI Alex B"].firstMatch
        XCTAssert(choice.waitForExistence(timeout: 5), "the partner isn't offered as the default")
        choice.tap()
        waitFor(app.buttons["privacy.partner.default"].firstMatch, label: "UI Alex B")

        // Remove from the swipe: it asks first (there's no way back), then the
        // name leaves the list (design review, 2026-11-16: remove, not archive).
        renamed.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssert(app.staticTexts["Remove UI Alex B?"].waitForExistence(timeout: 5), "removing didn't ask first")
        shot("p3-remove-asks")
        let sheet = app.sheets.buttons["Remove"]
        (sheet.exists ? sheet : app.buttons["Remove"].firstMatch).tap()
        XCTAssert(renamed.waitForNonExistence(timeout: 5), "the partner is still listed")
        // With no partners left there's no default to pick.
        XCTAssert(app.buttons["privacy.partner.default"].waitForNonExistence(timeout: 5), "a default with no partners")

        // Cycle is each person's own (MVCALE-51): the friend tracks theirs
        // already, so their settings show; Track my cycle adds mine.
        let cycle = reveal(app.switches["privacy.cycle"])
        let cycleState = app.staticTexts["privacy.cycle.state"]
        waitFor(cycleState, label: "tracks theirs here")
        XCTAssert(app.buttons["privacy.cycleLength.them"].firstMatch.exists, "the friend's cycle settings don't show")
        XCTAssertFalse(app.buttons["privacy.cycleLength.me"].firstMatch.exists, "my settings show before I track")
        cycle.switches.firstMatch.exists ? cycle.switches.firstMatch.tap() : cycle.tap()
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
