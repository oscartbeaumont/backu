import XCTest

/// Covers the Photos-style filter panel and bulk selection interactions.
final class LibraryFilterAndSelectionTests: XCTestCase {
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

    private func attach(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
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

    func testFilterPanelAndBulkSelection() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photo tiles")
        attach(app, "library-01-all")

        // The floating filter panel from Photos.
        app.buttons["library.filter"].tap()
        sleep(1)
        attach(app, "library-02-filter-panel")
        let panel = app.buttons["filter.option.all-items"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Filter panel did not open")
        XCTAssertTrue(app.buttons["filter.option.favourites"].exists)
        XCTAssertTrue(app.buttons["filter.mediaTypes"].exists)
        XCTAssertTrue(app.buttons["filter.viewOptions"].exists)
        app.buttons["filter.done"].tap()
        XCTAssertTrue(app.buttons["filter.done"].waitForNonExistence(timeout: 5), "Filter panel did not close")

        // Selection mode replaces the level switcher with share / select all / delete.
        app.buttons["library.select"].tap()
        XCTAssertTrue(app.buttons["library.done"].waitForExistence(timeout: 5), "Selection mode did not start")
        XCTAssertTrue(app.buttons["library.selection.share"].exists)
        XCTAssertTrue(app.buttons["library.selection.all"].exists)
        XCTAssertTrue(app.buttons["library.selection.delete"].exists)
        attach(app, "library-03-selection")

        tiles.element(boundBy: 0).tap()
        tiles.element(boundBy: 1).tap()
        sleep(1)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Selected'")).firstMatch.exists,
            "Selection count did not appear"
        )
        attach(app, "library-04-selected")

        // Dragging across the grid selects the contiguous run.
        let start = tiles.element(boundBy: 2)
        let end = tiles.element(boundBy: 7)
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(1)
        attach(app, "library-05-drag-selected")
        let selectedLabel = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Selected'")).firstMatch
        XCTAssertTrue(selectedLabel.exists, "Drag selection did not update the count")
        let count = Int(selectedLabel.label.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(count, 2, "Dragging did not select a range")

        // Select all, then leave without changing the library.
        app.buttons["library.selection.all"].tap()
        sleep(1)
        attach(app, "library-06-select-all")
        let delete = app.buttons["library.selection.delete"]
        XCTAssertTrue(delete.isHittable, "Delete button is not hittable")
        delete.tap()
        sleep(1)
        attach(app, "library-07-delete-confirm")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete confirmation did not appear")
        alert.buttons["Cancel"].tap()
        app.buttons["library.done"].tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 5), "Selection mode did not end")
    }

    func testShareSelectedPhoto() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photo tiles")
        app.buttons["library.select"].tap()
        tiles.element(boundBy: 0).tap()
        app.buttons["library.selection.share"].tap()

        // The system share sheet is a separate accessibility surface; wait for
        // one of its standard actions rather than an app-specific title.
        let copy = app.buttons["Copy"].firstMatch
        let save = app.buttons["Save to Files"].firstMatch
        let activity = app.otherElements["ActivityListView"].firstMatch
        let appeared = copy.waitForExistence(timeout: 30)
            || save.waitForExistence(timeout: 2)
            || activity.waitForExistence(timeout: 2)
        attach(app, "library-07-share")
        XCTAssertTrue(appeared, "Share sheet did not appear")
        if app.buttons["Close"].firstMatch.exists {
            app.buttons["Close"].firstMatch.tap()
        } else {
            app.swipeDown()
        }
    }
}
