import XCTest

final class BackuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var bootstrap: String {
        """
        {"servers":[{"name":"Local Test","provider":"custom","endpoint":"http://127.0.0.1:9000","region":"us-east-1","bucket":"backu-test","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":true,"faceRecognitionEnabled":true,"gridColumns":3,"hasCompletedOnboarding":true}}
        """
    }

    private func select(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        if tab.exists {
            tab.tap()
            return
        }
        let sidebar = app.buttons[name].firstMatch
        if sidebar.waitForExistence(timeout: 5) {
            sidebar.tap()
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLibraryViewerBackupPeopleAndSearch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launch()

        // Photo library permission is presented by the app on first launch.
        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 10) {
            allow.tap()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 3) {
            springboardAllow.tap()
        }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photo tiles rendered")
        attach(app, "01-library")

        // Viewer + details sheet.
        tiles.firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "Viewer did not open")
        attach(app, "02-viewer")
        app.buttons["Info"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Details"].firstMatch.waitForExistence(timeout: 8), "Info sheet did not open")
        attach(app, "03-details")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Close"].firstMatch.tap()

        // Back up the whole library to the mock bucket.
        let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back up'")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "Backup button missing")
        backup.tap()
        let upToDate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'backed up'")).firstMatch
        XCTAssertTrue(upToDate.waitForExistence(timeout: 30), "Backup never started")
        attach(app, "04-backup-running")
        sleep(45)
        attach(app, "04-after-backup")

        // People: every detected face is a card. Name the first one.
        select("People", in: app)
        XCTAssertTrue(app.staticTexts["People & Pets"].waitForExistence(timeout: 10), "People screen did not appear")
        attach(app, "05-people")

        let unnamed = app.buttons.matching(identifier: "people.name").firstMatch
        XCTAssertTrue(unnamed.waitForExistence(timeout: 8), "No unnamed faces to name")
        unnamed.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Naming alert missing")
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("Oscar")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Oscar"].waitForExistence(timeout: 8), "Name was not saved")
        attach(app, "05b-people-named")

        // Renaming dirties sidecars; the header must offer a sync, not hide it.
        select("Library", in: app)
        let sync = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back up'")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 8), "No way to push the rename to the bucket")
        sync.tap()
        sleep(12)
        attach(app, "05c-after-metadata-sync")

        // Search finds the named person and a geocoded place.
        select("Search", in: app)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Search field missing")
        field.tap()
        field.typeText("oscar")
        sleep(2)
        let results = app.buttons.matching(identifier: "library.tile")
        XCTAssertGreaterThan(results.count, 0, "Search for a named person returned nothing")
        attach(app, "06-search-oscar")

        for _ in 0..<5 { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        field.typeText("london")
        sleep(2)
        XCTAssertGreaterThan(results.count, 0, "Search for a place returned nothing")
        attach(app, "06b-search-london")

        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        }
        sleep(1)
        select("Servers", in: app)
        XCTAssertTrue(app.staticTexts["Local Test"].waitForExistence(timeout: 8), "Server card missing")
        attach(app, "07-servers")

        select("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 8), "Settings screen missing")
        attach(app, "08-settings")
    }

    func testOnboardingAndCustomServerConnection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Your photos.\nYour bucket."].waitForExistence(timeout: 15), "Welcome screen missing")
        attach(app, "10-welcome")

        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Storage'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let custom = app.buttons.containing(.staticText, identifier: "Custom S3").firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 8), "Provider picker missing")
        attach(app, "11-providers")
        custom.tap()

        let bucket = app.textFields["my-photos"]
        XCTAssertTrue(bucket.waitForExistence(timeout: 8), "Server form missing")
        bucket.tap()
        bucket.typeText("backu-test")

        let endpoint = app.textFields["s3.example.com"]
        if endpoint.exists {
            endpoint.tap()
            endpoint.typeText("http://127.0.0.1:9000")
        }

        let key = app.textFields["Access key ID"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("testkey")

        let secret = app.secureTextFields["Secret access key"]
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        secret.tap()
        secret.typeText("testsecret")
        attach(app, "12-server-form")

        let test = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Test Connection'")).firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        XCTAssertTrue(app.staticTexts["Ready to back up"].waitForExistence(timeout: 20), "Connection test failed")
        attach(app, "13-connection-verified")

        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 15), "Did not land in the library")
        attach(app, "14-library-connected")
    }
}
