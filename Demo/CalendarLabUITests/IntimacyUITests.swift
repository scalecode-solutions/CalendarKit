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

    /// Who is one dropdown (Not set · Solo · the partners): choose one.
    func chooseWho(_ choice: String) {
        let who = app.buttons["who"].firstMatch
        XCTAssert(who.waitForExistence(timeout: 5), "no Who dropdown")
        who.tap()
        let option = app.buttons[choice].firstMatch
        XCTAssert(option.waitForExistence(timeout: 5), "no \(choice) in Who")
        option.tap()
    }

    func waitForOn(_ s: XCUIElement) {
        let p = NSPredicate(format: "value == '1'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: s)], timeout: 10), .completed,
                       "\(s) never turned on")
    }

    /// Solo is its own switch, above Who (MVCALE-51).
    func turnOnSolo() {
        let solo = app.switches["solo"].firstMatch
        XCTAssert(solo.waitForExistence(timeout: 5), "no Solo switch")
        if (solo.value as? String) != "1" { flip(solo) }
        waitForOn(solo)
    }

    func flip(_ s: XCUIElement) {
        s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap()
    }

    /// Our two consents on, through the privacy sheet, then back to the month.
    func consentToBoth(defaultPartner: String? = nil) {
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
        let intimate = app.switches["privacy.intimate"]
        XCTAssert(intimate.waitForExistence(timeout: 5))
        // An earlier test in the run may have turned them on already: flip only what's off.
        // The friend's are on already (CONSENT_FROM); a switch's value says ours.
        if (intimate.value as? String) != "1" { flip(intimate) }
        waitForOn(intimate)
        let cycle = reveal(app.switches["privacy.cycle"])
        if (cycle.value as? String) != "1" { flip(cycle) }
        waitForOn(cycle)
        if let partner = defaultPartner {
            // One of my own, and my default (MVCALE-51).
            let field = reveal(app.textFields["privacy.partner.name"])
            field.tap()
            field.typeText(partner)
            app.buttons["privacy.partner.add"].tap()
            XCTAssert(app.buttons["privacy.partner.\(partner)"].firstMatch.waitForExistence(timeout: 5), "the partner wasn't added")
            // At the largest text the keyboard covers the default's row.
            if app.keyboards.count > 0 { app.typeText("\n") }
            XCTAssert(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "the keyboard stayed up")
            reveal(app.buttons["privacy.partner.default"].firstMatch).tap()
            let choice = app.buttons[partner].firstMatch
            XCTAssert(choice.waitForExistence(timeout: 5), "the partner isn't offered as the default")
            choice.tap()
            waitFor(app.buttons["privacy.partner.default"].firstMatch, label: partner)
        }
        // Back to the conversation, then its calendar.
        for _ in 0..<3 where !app.buttons["conversation.calendar"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["conversation.calendar"].waitForExistence(timeout: 2)
        }
        app.buttons["conversation.calendar"].tap()
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
        XCTAssert(app.descendants(matching: .any)["dayViewHeader"].firstMatch.waitForExistence(timeout: 5), "no day view")
    }

    func backToMonth() {
        // The day view has a + too: the month is where today's cell is.
        for _ in 0..<3 where !today.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = today.waitForExistence(timeout: 2)
        }
        XCTAssert(today.exists, "not back on the month")
    }

    /// With a default partner (design review, MVCALE-51): + → Intimate starts
    /// with it, Who has no "Not set", and a quick log is a filled heart.
    /// Named to run last (XCTest goes alphabetically): it leaves a partner
    /// and a default behind, which the other tests don't expect.
    func testWithADefaultPartnerEveryNewEntryStartsWithIt() {
        app.terminate()
        app.launch()
        consentToBoth(defaultPartner: "UI Pat")
        XCTAssert(today.waitForExistence(timeout: 5))
        app.buttons["addMenu"].tap()
        let intimate = app.buttons["Intimate"].firstMatch
        XCTAssert(intimate.waitForExistence(timeout: 5), "no Intimate in +")
        intimate.tap()
        let who = app.buttons["who"].firstMatch
        XCTAssert(who.waitForExistence(timeout: 5), "no Who")
        XCTAssert(who.label.contains("UI Pat") || (who.value as? String)?.contains("UI Pat") == true, "Who didn't start with the default: \(who.label)")
        who.tap()
        XCTAssert(app.buttons["UI Pat"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Not set"].exists, "Not set offered beside a default")
        shot("i6-who-default")
        app.buttons["UI Pat"].firstMatch.tap()
        app.buttons["Cancel"].tap()
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
        XCTAssert(app.staticTexts["Turn on Solo or pick who. Until then it shows as a hollow heart."].waitForExistence(timeout: 5),
                  "a quick log doesn't ask who")
        turnOnSolo()
        app.buttons["Save"].tap()

        // Reopened: who is set, so the prompt is gone.
        XCTAssert(entry.waitForExistence(timeout: 5))
        entry.tap()
        let solo = app.switches["solo"].firstMatch
        XCTAssert(solo.waitForExistence(timeout: 5))
        XCTAssertEqual(solo.value as? String, "1", "Solo didn't stick")
        XCTAssertFalse(app.staticTexts["Turn on Solo or pick who. Until then it shows as a hollow heart."].exists)
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
        turnOnSolo()
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

    /// An empty day shows no Intimate or Cycle card (design review
    /// 2026-11-16); + → Log period → You → a flow writes the day and its card
    /// appears. Logging again from + changes that day, not a second row (the
    /// kit dedupes: the date is sealed, so the server can't). None clears it
    /// and the card goes.
    func testLogAndClearAPeriodDay() {
        openToday()
        XCTAssertFalse(app.staticTexts["Nothing logged."].exists, "an empty Intimate card on an empty day")
        XCTAssertFalse(app.buttons["Log a period day"].exists, "an empty Cycle card on an empty day")
        XCTAssertFalse(app.descendants(matching: .any)["cycleSection"].exists, "a Cycle card on a day with nothing")
        shot("i5a-empty-day")

        func logFromPlus(_ flow: String) {
            app.buttons["addMenu"].firstMatch.tap()
            let log = app.buttons["Log period"].firstMatch
            XCTAssert(log.waitForExistence(timeout: 5), "no Log period in the day view's +")
            log.tap()
            let you = app.buttons["You"].firstMatch
            XCTAssert(you.waitForExistence(timeout: 5), "no 'You' under Log period")
            you.tap()
            let f = app.buttons[flow].firstMatch
            XCTAssert(f.waitForExistence(timeout: 5), "no flows offered")
            f.tap()
        }
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Flow:'"))
        logFromPlus("Heavy")
        XCTAssert(rows.firstMatch.waitForExistence(timeout: 5), "no Cycle card after logging")
        waitFor(rows.firstMatch, label: "Heavy")
        shot("i5-period-logged")

        logFromPlus("Light")
        waitFor(rows.firstMatch, label: "Light")
        XCTAssertEqual(rows.count, 1, "logging the same day again made a second row")

        reveal(rows.firstMatch).tap()
        app.buttons["No flow"].firstMatch.tap()
        XCTAssert(rows.firstMatch.waitForNonExistence(timeout: 5), "the day is still logged")
        XCTAssertFalse(app.descendants(matching: .any)["cycleSection"].exists, "the Cycle card stayed on a cleared day")
        backToMonth()
        waitFor(today, label: "period", present: false)
    }

    /// Two taps a period (MVCALE-52): + → Log period → You → Period started
    /// makes it a period day with no flow, offering Ended today; ending it
    /// takes that away; taking both marks back clears the day.
    func testMarkAPeriodStartedAndEnded() {
        openToday()
        func fromPlus(_ item: String) {
            app.buttons["addMenu"].firstMatch.tap()
            let log = app.buttons["Log period"].firstMatch
            XCTAssert(log.waitForExistence(timeout: 5), "no Log period in the day view's +")
            log.tap()
            let you = app.buttons["You"].firstMatch
            XCTAssert(you.waitForExistence(timeout: 5), "no 'You' under Log period")
            you.tap()
            let i = app.buttons[item].firstMatch
            XCTAssert(i.waitForExistence(timeout: 5), "no \(item) under You")
            i.tap()
        }
        fromPlus("Period started")
        let started = app.staticTexts["Period · started"].firstMatch
        XCTAssert(started.waitForExistence(timeout: 5), "the day doesn't say the period started")
        let ended = app.buttons["endedToday"].firstMatch
        XCTAssert(reveal(ended).exists, "no Ended today on an open period's day")
        shot("i7-period-started")
        ended.tap()
        XCTAssert(ended.waitForNonExistence(timeout: 5), "Ended today stayed after ending it")
        shot("i8-period-ended")
        // Take both marks back: the day has nothing left, so it goes.
        fromPlus("Period ended")
        fromPlus("Period started")
        XCTAssert(app.descendants(matching: .any)["cycleSection"].waitForNonExistence(timeout: 5), "a Cycle card on a cleared day")
        backToMonth()
        waitFor(today, label: "period", present: false)
    }
}
