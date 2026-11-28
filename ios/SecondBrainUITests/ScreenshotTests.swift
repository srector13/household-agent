import XCTest

/// Walks the app against a running devhost (ios/ci/devhost.py on 127.0.0.1:8080) and attaches a
/// screenshot of each screen. CI exports them as the secondbrain-screenshots-N artifact.
final class ScreenshotTests: XCTestCase {
    private let server = "http://127.0.0.1:8080"

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testScreenshots() {
        let app = XCUIApplication()
        app.launchEnvironment["TZ"] = "America/Chicago"  // the devhost's day is in Chicago time

        // 1. First launch: connect.
        app.launchArguments = ["-SecondBrainReset", "-SecondBrainScreenshots"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect to your brain"].waitForExistence(timeout: 30))
        shot("01-connect")

        // 2. Connected: Today (the timeline).
        app.terminate()
        app.launchArguments = ["-SecondBrainReset", "-SecondBrainServer", server, "-SecondBrainScreenshots"]
        app.launch()
        dismissAlerts(app)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30), "Today didn't load")
        _ = app.scrollViews["timeline"].waitForExistence(timeout: 20)
        sleep(2)
        shot("02-today")
        app.swipeUp()
        sleep(1)
        shot("03-today-scrolled")
        app.swipeDown(); app.swipeDown()
        sleep(1)

        // 2b. The review banner opens a sheet over Today.
        if tap(app.buttons["review-banner"]) {
            sleep(2)
            shot("14-review-sheet")
            if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
            sleep(1)
        }

        // 2c. Which calendars and lists show on Today.
        if tap(app.buttons["sources-button"]) {
            sleep(2)
            shot("29-sources")
            if !tap(app.buttons["sources-done"]) { app.swipeDown() }
            sleep(1)
        }

        // 2d. The week strip: tomorrow.
        let days = app.scrollViews["timeline"].buttons.matching(NSPredicate(format: "label CONTAINS ','"))
        if days.count >= 7 {
            let todayIndex = (0..<days.count).first { days.element(boundBy: $0).isSelected } ?? 6
            if todayIndex < 6 {
                days.element(boundBy: todayIndex + 1).tap()
                sleep(2)
                shot("30-tomorrow")
                if app.navigationBars.buttons["Today"].exists { app.navigationBars.buttons["Today"].tap(); sleep(2) }
            }
        }

        // 3. Focus mode: tap a reminder's title → Focus on This.
        let ticks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tick-'"))
        if ticks.firstMatch.waitForExistence(timeout: 5) {
            let title = String(ticks.firstMatch.identifier.dropFirst(5))
            if tap(app.staticTexts[title].firstMatch) {
                sleep(1)
                shot("31-reminder-actions")
                if tap(app.buttons["Focus on This"]) {
                    XCTAssertTrue(app.staticTexts["focus-title"].waitForExistence(timeout: 15))
                    sleep(1)
                    shot("04-focus")
                    if tap(app.buttons["focus-start"]) { sleep(2); shot("05-focus-timer") }
                    if tap(app.buttons["focus-done"]) { sleep(1); shot("06-focus-done") }
                    if app.buttons["Take a break"].exists { app.buttons["Take a break"].tap() }
                    else if app.buttons["Back to my day"].exists { app.buttons["Back to my day"].tap() }
                    else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
                    sleep(1)
                } else if app.buttons["Cancel"].exists {
                    app.buttons["Cancel"].tap()
                }
            }
        }

        // 4. Capture.
        if tap(app.buttons["capture-bar"]) {
            sleep(1)
            let field = app.textViews["capture-text"].exists ? app.textViews["capture-text"] : app.textFields["capture-text"]
            if field.exists { field.typeText("Book the car service next week") }
            if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap(); sleep(1) }
            shot("07-capture")
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            sleep(1)
        }

        // 4b. The Control Center / Lock Screen route: open capture already listening.
        app.open(URL(string: "secondbrain://capture?dictate=1")!)
        sleep(3)
        shot("28-capture-listening")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        sleep(1)

        // 5. People: faces, a person, and adding someone from Contacts.
        tab(app, "People")
        sleep(2)
        shot("08-people")
        if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sarah'")).firstMatch) {
            sleep(2)
            shot("09-person")
            app.swipeUp()
            shot("10-person-scrolled")
            back(app)
            sleep(1)
        }
        if tap(app.buttons["add-person"]) {
            sleep(3)
            shot("32-contacts-picker")
            // The simulator ships sample contacts (Kate Bell, John Appleseed …).
            let kate = app.staticTexts["Kate Bell"].firstMatch
            if kate.waitForExistence(timeout: 5) {
                kate.tap()
                sleep(2)
                shot("33-add-person")
                if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            } else if app.buttons["Cancel"].exists {
                app.buttons["Cancel"].tap()
            }
            sleep(1)
        }

        // 6. Lists: tiles, a list (with swipe actions), a collection.
        tab(app, "Lists")
        sleep(2)
        shot("11-lists")
        if tap(app.buttons["tile-scheduled"]) {
            sleep(2)
            shot("12-list-scheduled")
            let cell = app.staticTexts["Do our taxes"].firstMatch
            if cell.waitForExistence(timeout: 3) {
                cell.swipeLeft()
                sleep(1)
                shot("12b-list-swipe")
                app.tap()
            }
            back(app)
            sleep(1)
        }
        if tap(app.collectionViews.cells.element(boundBy: 1)) {
            sleep(2)
            shot("13-collection")
            back(app)
            sleep(1)
        }

        // 8. More → everything else.
        tab(app, "More")
        sleep(1)
        shot("15-more")
        for (label, name) in [("Activity", "16-activity"), ("Plan my days", "18-today"), ("Weekly reset", "19-weekly"),
                              ("Today widget", "34-widget-setup"),
                              ("Status", "20-status"), ("Settings", "21-settings"), ("Server & notifications", "23-server")] {
            guard tap(app.staticTexts[label].firstMatch) else { continue }
            sleep(2)
            shot(name)
            if label == "Activity", tap(app.cells.element(boundBy: 1)) {
                sleep(2)
                shot("17-message")
                back(app)
            }
            if label == "Settings", tap(app.staticTexts["People & chats"].firstMatch) {
                sleep(1)
                shot("22-settings-people")
                back(app)
            }
            back(app)
            sleep(1)
        }

        // 9. Dark mode.
        app.terminate()
        app.launchArguments = ["-SecondBrainServer", server, "-SecondBrainScreenshots", "-SecondBrainDark"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        sleep(3)
        shot("24-today-dark")
        tab(app, "People")
        sleep(2)
        shot("24b-people-dark")
        tab(app, "Lists")
        sleep(2)
        shot("25-lists-dark")
        tab(app, "More")
        sleep(1)
        shot("26-more-dark")
        if tap(app.staticTexts["Weekly reset"].firstMatch) { sleep(2); shot("27-weekly-dark") }
    }

    // MARK: helpers

    @MainActor
    private func shot(_ name: String) {
        // The simulator sometimes times out taking a screenshot; that's not the app's fault.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("simulator screenshot timeouts are tolerated", options: options) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
    }

    @MainActor
    @discardableResult
    private func tap(_ e: XCUIElement) -> Bool {
        guard e.waitForExistence(timeout: 6) else { return false }
        e.tap()
        return true
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) {
        var b = app.tabBars.buttons[name]
        if !b.waitForExistence(timeout: 3) {
            // The tab bar collapses to one icon while scrolling: tap it to expand, or scroll back up.
            let visible = app.tabBars.buttons.firstMatch
            if visible.exists { visible.tap() } else { app.swipeDown(); app.swipeDown() }
            b = app.tabBars.buttons[name]
        }
        if b.waitForExistence(timeout: 5) { b.tap() } else if app.buttons[name].firstMatch.exists { app.buttons[name].firstMatch.tap() }
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() }
    }

    @MainActor
    private func dismissAlerts(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "OK"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); break }
        }
    }
}
