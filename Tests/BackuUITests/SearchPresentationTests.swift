import XCTest

/// The bottom-right search button opens the library search as a full-screen
/// page, and closing it returns to the same tab.
final class SearchPresentationTests: XCTestCase {
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

    func testSearchButtonOpensAndClosesTheSearchPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 2) { springboardAllow.tap() }
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")

        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photo tiles")
        XCTAssertFalse(app.tabBars.buttons["Search"].exists, "Search is still a tab")
        XCTAssertTrue(app.buttons["search.open"].exists, "Bottom-right search button missing")

        app.buttons["search.open"].tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search page did not open")
        attach(app, "search-01-open")

        field.tap()
        field.typeText("2025")
        sleep(2)
        attach(app, "search-02-results")

        let close = app.buttons["search.close"]
        XCTAssertTrue(close.exists, "Search close button missing")
        close.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Closing search did not return to the library")
    }
}
