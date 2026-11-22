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

        // 2. Connected: Home.
        app.terminate()
        app.launchArguments = ["-SecondBrainReset", "-SecondBrainServer", server, "-SecondBrainScreenshots"]
        app.launch()
        dismissAlerts(app)
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 30), "Home didn't load")
        sleep(2)
        shot("02-home")
        app.swipeUp()
        sleep(1)
        shot("03-home-scrolled")
        app.swipeDown(); app.swipeDown()

        // 3. Focus mode from today's first pick.
        if tap(app.buttons["focus-first"]) {
            XCTAssertTrue(app.staticTexts["focus-title"].waitForExistence(timeout: 15))
            sleep(1)
            shot("04-focus")
            if tap(app.buttons["focus-start"]) { sleep(2); shot("05-focus-timer") }
            if tap(app.buttons["focus-done"]) { sleep(1); shot("06-focus-done") }
            if app.buttons["Take a break"].exists { app.buttons["Take a break"].tap() }
            else if app.buttons["Back to my day"].exists { app.buttons["Back to my day"].tap() }
            else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
            sleep(1)
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

        // 5. People.
        tab(app, "People")
        sleep(2)
        shot("08-people")
        if tap(app.staticTexts["Sarah"].firstMatch) {
            sleep(2)
            shot("09-person")
            app.swipeUp()
            shot("10-person-scrolled")
        }

        // 6. Lists + swipe actions.
        tab(app, "Lists")
        sleep(2)
        shot("11-lists")
        let cell = app.staticTexts["Do our taxes"].firstMatch
        if cell.waitForExistence(timeout: 5) {
            cell.swipeLeft()
            sleep(1)
            shot("12-lists-swipe")
            app.tap()
        }
        if tap(app.segmentedControls.buttons["Collections"].firstMatch) || tap(app.buttons["Collections"].firstMatch) {
            sleep(2); shot("13-collections")
        }

        // 7. Review.
        tab(app, "Review")
        sleep(2)
        shot("14-review")

        // 8. More → everything else.
        tab(app, "More")
        sleep(1)
        shot("15-more")
        for (label, name) in [("Activity", "16-activity"), ("Plan my days", "18-today"), ("Weekly reset", "19-weekly"),
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
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 30))
        sleep(2)
        shot("24-home-dark")
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
