import XCTest

/// Drives the Photos-style Years / Months / All timeline and the pinch resize.
final class LibraryTimelineTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var bootstrap: String {
        """
        {"servers":[{"name":"Local Test","provider":"custom","endpoint":"http://127.0.0.1:9000","region":"us-east-1","bucket":"backu-test","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":false,"faceRecognitionEnabled":false,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":true}}
        """
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 2) { springboardAllow.tap() }
        let ask = app.buttons["Allow Photo Access"]
        if ask.waitForExistence(timeout: 2) {
            ask.tap()
            if springboardAllow.waitForExistence(timeout: 4) { springboardAllow.tap() }
        }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
        return app
    }

    func testTimelineLevelsAndDrillDown() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photo tiles")
        attach(app, "timeline-01-all")

        app.swipeUp()
        sleep(1)
        attach(app, "timeline-01b-all-scrolled")

        // The switcher itself must open the Months timeline directly.
        app.buttons["library.level.months"].tap()
        let firstMonth = app.buttons.matching(identifier: "library.monthCard").firstMatch
        XCTAssertTrue(firstMonth.waitForExistence(timeout: 10), "Months level showed no month cards")
        attach(app, "timeline-01c-months-direct")
        app.buttons["library.level.all"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "All level did not return")

        // Years is the widest view. It must contain at least one year card.
        app.buttons["library.level.years"].tap()
        let yearCard = app.buttons.matching(identifier: "library.yearCard").firstMatch
        XCTAssertTrue(yearCard.waitForExistence(timeout: 10), "Years level showed no year cards")
        attach(app, "timeline-02-years")

        // A year drills into its Months level.
        yearCard.tap()
        let monthCard = app.buttons.matching(identifier: "library.monthCard").firstMatch
        XCTAssertTrue(monthCard.waitForExistence(timeout: 10), "Tapping a year did not show months")
        attach(app, "timeline-03-months")

        // Months is the date timeline: scrolling moves through history.
        let title = monthCard.label
        app.swipeUp()
        sleep(1)
        attach(app, "timeline-04-months-scrolled")
        XCTAssertTrue(monthCard.exists, "Months timeline disappeared while scrolling")

        // A month drills into the continuous All grid.
        monthCard.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Tapping a month did not show the grid")
        attach(app, "timeline-05-all-from-month")

        // Pinching out enlarges the grid to the full-width level.
        let before = tiles.firstMatch.frame.width
        app.windows.firstMatch.pinch(withScale: 3, velocity: 2)
        sleep(2)
        let after = app.buttons.matching(identifier: "library.tile").firstMatch.frame.width
        attach(app, "timeline-06-full-width")
        XCTAssertGreaterThan(after, before * 2, "Pinch did not enlarge the photos")
    }
}
