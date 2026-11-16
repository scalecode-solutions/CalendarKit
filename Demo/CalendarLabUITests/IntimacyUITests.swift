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
        XCTAssert(e.waitForExistence(timeout: timeout), "\(e) isn't there to read") // absent would pass a NOT
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
        // An earlier test in the run may have turned them on already: flip only what's off.
        let intimateState = app.staticTexts["privacy.intimate.state"]
        if !intimateState.label.contains("On for both") { flip(intimate) }
        waitFor(intimateState, label: "On for both")
        let cycle = reveal(app.switches["privacy.cycle"])
        let cycleState = app.staticTexts["privacy.cycle.state"]
        if !cycleState.label.contains("On for both") { flip(cycle) }
        waitFor(cycleState, label: "On for both")
        for _ in 0..<4 where !app.buttons["addMenu"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["addMenu"].waitForExistence(timeout: 2)
        }
        XCTAssert(app.buttons["addMenu"].waitForExistence(timeout: 10), "no + menu after both consents")
    }

    var today: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Today'")).firstMatch
    }

    /// How many private entries today's cell says it has (other tests in the
    /// run may have left some).
    func privateCount() -> Int {
        guard today.exists else { return -1 }
        let l = today.label
        guard let r = l.range(of: #"(\d+) private entr"#, options: .regularExpression) else { return 0 }
        return Int(l[r].split(separator: " ")[0]) ?? 0
    }

    func waitForCount(_ n: Int) {
        let p = NSPredicate { _, _ in self.privateCount() == n }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: 10), .completed,
                       "today never had \(n) private entries: \(today.label)")
    }

    func openToday() {
        XCTAssert(today.waitForExistence(timeout: 5))
        today.tap()
        XCTAssert(app.buttons["Log an intimate entry"].waitForExistence(timeout: 5), "no Intimate section in the day view")
    }

    func backToMonth() {
        // The day view has a + too: the month is where today's cell is.
        for _ in 0..<3 where !today.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = today.waitForExistence(timeout: 2)
        }
        XCTAssert(today.exists, "not back on the month")
    }

    /// + → Quick log: today gets a private entry, hollow until who is set; the
    /// day view lists it, Solo fills it in, Delete removes it.
    func testQuickLogFillInAndDelete() {
        XCTAssert(today.waitForExistence(timeout: 5))
        let before = privateCount()
        app.buttons["addMenu"].tap()
        let quick = app.buttons["Quick log"].firstMatch
        XCTAssert(quick.waitForExistence(timeout: 5), "no Quick log in +")
        quick.tap()
        waitForCount(before + 1)
        shot("i1-quick-logged")

        openToday()
        // By label: the sections' identifiers cover their children's.
        // The quick log is the one still asking who (the newest, last in the list).
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Private entry'"))
        XCTAssert(rows.firstMatch.waitForExistence(timeout: 5), "no private entry in the day view")
        let entry = rows.element(boundBy: rows.count - 1)
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
        let gone = NSPredicate { _, _ in rows.count == before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5), .completed,
                       "the entry is still in the day view")
        backToMonth()
        waitForCount(before)
    }

    /// + → Intimate: the editor only picks partners (they're added in the
    /// pair's settings, design review 2026-11-16), so with none yet it says where;
    /// Solo saves it, and the filter hides it under Events and shows it under
    /// Intimate.
    func testEntryAndTheFilter() {
        XCTAssert(today.waitForExistence(timeout: 5))
        let before = privateCount()
        app.buttons["addMenu"].tap()
        let intimate = app.buttons["Intimate"].firstMatch
        XCTAssert(intimate.waitForExistence(timeout: 5), "no Intimate in +")
        intimate.tap()
        XCTAssertFalse(app.buttons["Add a partner"].exists, "the editor still adds partners")
        XCTAssert(app.staticTexts["noPartners"].waitForExistence(timeout: 5), "no line saying where partners are added")
        flip(app.switches["Solo"])
        shot("i3-editor-no-partners")
        app.buttons["Save"].tap()
        waitForCount(before + 1)

        // Events only: no private entry on the day. Intimate: back.
        app.buttons["kindFilter"].tap()
        app.buttons["Events"].firstMatch.tap()
        waitFor(today, label: "private entr", present: false)
        shot("i4-filter-events")
        app.buttons["kindFilter"].tap()
        app.buttons["Intimate"].firstMatch.tap()
        waitForCount(before + 1)
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
