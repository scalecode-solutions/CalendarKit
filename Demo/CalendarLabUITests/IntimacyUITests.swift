import XCTest

/// The intimacy screens, writing through to the local server (0.8.0 design
/// sprint, MVCALE-26 step 2; Frond's screens, Leaf's tests). Needs
/// scripts/ui-test.sh with CONSENT_FROM=<a friend>: the script opens that pair
/// with the friend's consents on, setUp turns ours on through the privacy
/// sheet, and the script wipes the pair after.
final class IntimacyUITests: XCTestCase {
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
        consentToBoth()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @discardableResult
    func reveal(_ e: XCUIElement) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable) {
            if e.exists && e.frame.maxY < window.minY + window.height * 0.25 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssert(e.exists && e.isHittable, "can't reach \(e)")
        return e
    }

    func waitFor(_ e: XCUIElement, label: String, present: Bool = true, _ timeout: TimeInterval = 10) {
        let p = NSPredicate(format: present ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", label)
        let ok = XCTNSPredicateExpectation(predicate: p, object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [ok], timeout: timeout), .completed,
                       "\(e) \(present ? "never said" : "still says") \(label): \(e.label)")
    }

    func flip(_ s: XCUIElement) {
        s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap()
    }

    /// Our two consents on, through the privacy sheet, then back to the month.
    func consentToBoth() {
        XCTAssert(app.buttons["Account"].waitForExistence(timeout: 15))
        app.buttons["Account"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Shown' OR label CONTAINS 'Hidden'")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 10), "no pair in the settings")
        row.tap()
        let link = app.buttons["pair.privacy"]
        XCTAssert(link.waitForExistence(timeout: 5), "no Privacy on the pair's page")
        link.tap()
        let intimate = app.switches["privacy.intimate"]
        XCTAssert(intimate.waitForExistence(timeout: 5))
        flip(intimate)
        waitFor(app.staticTexts["privacy.intimate.state"], label: "On for both")
        flip(reveal(app.switches["privacy.cycle"]))
        waitFor(app.staticTexts["privacy.cycle.state"], label: "On for both")
        for _ in 0..<4 where !app.buttons["addMenu"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["addMenu"].waitForExistence(timeout: 2)
        }
        XCTAssert(app.buttons["addMenu"].waitForExistence(timeout: 10), "no + menu after both consents")
    }

    var today: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Today'")).firstMatch
    }

    func openToday() {
        XCTAssert(today.waitForExistence(timeout: 5))
        today.tap()
        XCTAssert(app.buttons["Log an intimate entry"].waitForExistence(timeout: 5), "no Intimate section in the day view")
    }

    func backToMonth() {
        for _ in 0..<3 where !app.buttons["addMenu"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["addMenu"].waitForExistence(timeout: 2)
        }
    }

    /// + → Quick log: today gets a private entry, hollow until who is set; the
    /// day view lists it, Solo fills it in, Delete removes it.
    func testQuickLogFillInAndDelete() {
        app.buttons["addMenu"].tap()
        let quick = app.buttons["Quick log"].firstMatch
        XCTAssert(quick.waitForExistence(timeout: 5), "no Quick log in +")
        quick.tap()
        waitFor(today, label: "1 private entry")
        shot("i1-quick-logged")

        openToday()
        // By label: the sections' identifiers cover their children's.
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Private entry'")).firstMatch
        XCTAssert(entry.waitForExistence(timeout: 5), "no private entry in the day view")
        XCTAssertFalse(entry.label.contains("Quick log") || entry.label.contains("Who"), "VoiceOver says more than 'Private entry': \(entry.label)")
        shot("i2-day")
        entry.tap()
        XCTAssert(app.staticTexts["Pick who, or Solo. Until then it shows as a hollow heart."].waitForExistence(timeout: 5),
                  "a quick log doesn't ask who")
        flip(app.switches["Solo"])
        app.buttons["Save"].tap()

        // Reopened: who is set, so the prompt is gone.
        XCTAssert(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssert(app.switches["Solo"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Solo"].value as? String, "1", "Solo didn't stick")
        XCTAssertFalse(app.staticTexts["Pick who, or Solo. Until then it shows as a hollow heart."].exists)
        reveal(app.buttons["Delete entry"]).tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssert(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        confirm.tap()
        XCTAssert(entry.waitForNonExistence(timeout: 5), "the entry is still in the day view")
        backToMonth()
        waitFor(today, label: "private entr", present: false)
    }

    /// + → Intimate with a new partner: saved, listed, and the filter hides
    /// it under Events and shows it under Intimate.
    func testEntryWithANewPartnerAndTheFilter() {
        app.buttons["addMenu"].tap()
        let intimate = app.buttons["Intimate"].firstMatch
        XCTAssert(intimate.waitForExistence(timeout: 5), "no Intimate in +")
        intimate.tap()
        let addPartner = app.buttons["Add a partner"]
        XCTAssert(reveal(addPartner).exists)
        addPartner.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5), "no new partner prompt")
        field.typeText("UI Sam")
        app.alerts.buttons["Add"].tap()
        let sam = app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI Sam'")).firstMatch
        XCTAssert(sam.waitForExistence(timeout: 5), "the new partner isn't offered")
        if !sam.isSelected { sam.tap() }
        shot("i3-editor-partner")
        app.buttons["Save"].tap()
        waitFor(today, label: "1 private entry")

        // Events only: no private entry on the day. Intimate: back.
        app.buttons["kindFilter"].tap()
        app.buttons["Events"].firstMatch.tap()
        waitFor(today, label: "private entr", present: false)
        shot("i4-filter-events")
        app.buttons["kindFilter"].tap()
        app.buttons["Intimate"].firstMatch.tap()
        waitFor(today, label: "1 private entry")
        app.buttons["kindFilter"].tap()
        app.buttons["All"].firstMatch.tap()
    }

    /// The day view's Cycle section: log a flow for yourself, change it, and
    /// clear it; the day says so as it goes.
    func testLogAndClearAPeriodDay() {
        openToday()
        let log = reveal(app.buttons["Log a period day"].firstMatch)
        log.tap()
        let you = app.buttons["You"].firstMatch
        XCTAssert(you.waitForExistence(timeout: 5), "no 'You' in Log a period day")
        you.tap()
        let heavy = app.buttons["Heavy"].firstMatch
        XCTAssert(heavy.waitForExistence(timeout: 5), "no flows offered")
        heavy.tap()
        let flow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Flow:'")).firstMatch
        XCTAssert(flow.waitForExistence(timeout: 5), "no flow row after logging")
        waitFor(flow, label: "Heavy")
        shot("i5-period-logged")

        reveal(flow).tap()
        app.buttons["Light"].firstMatch.tap()
        waitFor(flow, label: "Light")

        flow.tap()
        app.buttons["None"].firstMatch.tap()
        XCTAssert(flow.waitForNonExistence(timeout: 5), "the day is still logged")
        backToMonth()
        waitFor(today, label: "period", present: false)
    }
}
