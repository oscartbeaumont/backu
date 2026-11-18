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
        // Sidebar rows include counts ("Library, 14"), so match by prefix.
        let sidebar = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name)
        ).firstMatch
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
        // Force the 25 MB high-entropy fixture through multipart while small
        // photos keep the single-PUT fast path.
        app.launchEnvironment["BACKU_MULTIPART_THRESHOLD_BYTES"] = "1000"
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
        let running = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backing up'")).firstMatch
        let finished = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'All' AND label CONTAINS 'backed up'")
        ).firstMatch
        XCTAssertTrue(
            running.waitForExistence(timeout: 5) || finished.waitForExistence(timeout: 60),
            "Backup never started or finished"
        )
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

        // Servers are part of Settings: the row pushes the servers screen.
        select("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 8), "Settings screen missing")
        let serversRow = app.buttons.matching(identifier: "settings.servers").firstMatch
        XCTAssertTrue(serversRow.waitForExistence(timeout: 8), "Servers row missing from Settings")
        serversRow.tap()
        XCTAssertTrue(app.staticTexts["Local Test"].waitForExistence(timeout: 8), "Server card missing")
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8), "Servers screen did not push")
        attach(app, "07-servers")

        app.navigationBars["Servers"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 8), "Did not return to Settings")

        let activityRow = app.buttons.matching(identifier: "settings.backupActivity").firstMatch
        XCTAssertTrue(activityRow.waitForExistence(timeout: 8), "Backup activity row missing")
        activityRow.tap()
        XCTAssertTrue(app.otherElements["backup.activity"].waitForExistence(timeout: 8), "Upload activity sheet missing")
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 8), "Upload activity did not show the finished state")
        attach(app, "08-backup-activity")
        app.buttons["Done"].firstMatch.tap()

        let sponsor = app.buttons["Sponsor Backu on GitHub"]
        XCTAssertTrue(sponsor.waitForExistence(timeout: 8), "In-app sponsor action missing")
        for _ in 0..<5 {
            if sponsor.isHittable { break }
            app.swipeUp()
        }
        attach(app, "08-settings-support")
    }

    func testOnboardingAndCustomServerConnection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launch()

        // A fresh install starts with the photo-access explanation, then the
        // system prompt, then the welcome page. Later runs go straight to the
        // welcome because iOS remembers the answer.
        let askForPhotos = app.buttons["Allow Photo Access"]
        if askForPhotos.waitForExistence(timeout: 6) {
            attach(app, "09-photo-access-onboarding")
            XCTAssertTrue(
                app.staticTexts["A private view of\nyour photo library."].exists,
                "The permission page did not explain why access is needed"
            )
            askForPhotos.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons["Allow Full Access"]
            if allow.waitForExistence(timeout: 5) {
                allow.tap()
            }
        }

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

        // The bucket prefix is optional. Open the saved server, clear it, and
        // confirm the server reports the bucket root.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8), "Settings tab missing")
        sleep(2)
        settingsTab.tap()
        if !app.staticTexts["Settings"].waitForExistence(timeout: 5) {
            settingsTab.tap()
        }
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 8), "Settings did not open")
        let serversRow = app.buttons.matching(identifier: "settings.servers").firstMatch
        XCTAssertTrue(serversRow.waitForExistence(timeout: 8), "Servers row missing")
        serversRow.tap()
        let serverCard = app.buttons.matching(identifier: "server.card").firstMatch
        XCTAssertTrue(serverCard.waitForExistence(timeout: 8), "Server card missing")
        serverCard.tap()

        let prefixField = app.textFields["server.prefix.field"]
        XCTAssertTrue(prefixField.waitForExistence(timeout: 8), "Prefix field missing")
        for _ in 0..<3 where !prefixField.isHittable { app.swipeUp() }
        prefixField.tap()
        for _ in 0..<2 {
            let value = (prefixField.value as? String) ?? ""
            let text = value == "Optional — bucket root" ? "" : value
            guard !text.isEmpty else { break }
            prefixField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        let savePrefix = app.buttons.matching(identifier: "server.prefix.save").firstMatch
        XCTAssertTrue(savePrefix.waitForExistence(timeout: 5), "Prefix save button missing")
        for _ in 0..<4 where !savePrefix.isHittable { app.swipeUp() }
        XCTAssertTrue(savePrefix.isHittable, "Prefix save button is covered")
        savePrefix.tap()
        let confirmPrefix = app.buttons["Change Prefix"]
        if confirmPrefix.waitForExistence(timeout: 2) { confirmPrefix.tap() }
        XCTAssertTrue(app.staticTexts["Bucket root"].firstMatch.waitForExistence(timeout: 8), "Prefix did not clear")
        attach(app, "15-server-prefix")
    }

    /// Captures the five listing screenshots from a marketing-only library.
    /// Run with two mock buckets — :9001 (`photo-archive`) and :9002
    /// (`photo-archive-offsite`) — and a clean simulator photo library; see
    /// Tools/Screenshots/README.md. Two destinations exercise redundancy.
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = """
        {"servers":[{"name":"Home Backup","provider":"aws","endpoint":"http://127.0.0.1:9001","region":"eu-west-1","bucket":"photo-archive","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Photos"},
                    {"name":"Offsite Vault","provider":"custom","endpoint":"http://127.0.0.1:9002","region":"eu-west-1","bucket":"photo-archive-offsite","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Photos"}],
         "settings":{"autoBackupEnabled":true,"backupOnCellular":true,"faceRecognitionEnabled":true,"gridColumns":3,"hasCompletedOnboarding":true,"backupAllServers":true}}
        """
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 3) { springboardAllow.tap() }
        let ask = app.buttons["Allow Photo Access"]
        if ask.waitForExistence(timeout: 2) {
            ask.tap()
            if springboardAllow.waitForExistence(timeout: 4) { springboardAllow.tap() }
        }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 15))
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photos in the simulator library")

        // First backup: all originals, sidecars, thumbs and the index.
        let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back up'")).firstMatch
        if backup.waitForExistence(timeout: 5) { backup.tap() }
        let backedUp = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'backed up' AND NOT (label CONTAINS '0 backed up')")
        ).firstMatch
        XCTAssertTrue(backedUp.waitForExistence(timeout: 90), "Backup did not complete")
        sleep(2)

        // Name a pet so People and Search have real content.
        select("People", in: app)
        XCTAssertTrue(app.staticTexts["People & Pets"].waitForExistence(timeout: 10))
        let unnamed = app.buttons.matching(identifier: "people.name").firstMatch
        if unnamed.waitForExistence(timeout: 20) {
            unnamed.tap()
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 5) {
                alert.textFields.firstMatch.tap()
                alert.textFields.firstMatch.typeText("Maple")
                alert.buttons["Save"].tap()
                _ = app.staticTexts["Maple"].waitForExistence(timeout: 8)
            }
        }

        // Push the rename's sidecar so no tile shows a pending badge.
        select("Library", in: app)
        let sync = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back up'")).firstMatch
        if sync.waitForExistence(timeout: 8) {
            sync.tap()
            sleep(8)
        }

        // Redundancy means two buckets have to finish before the library is
        // really up to date. Wait in Upload Activity rather than guessing.
        select("Settings", in: app)
        let activityRow = app.buttons.matching(identifier: "settings.backupActivity").firstMatch
        if activityRow.waitForExistence(timeout: 8) {
            activityRow.tap()
            XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 120), "Both buckets did not finish")
            attach(app, "06-upload-activity")
            app.buttons["Done"].firstMatch.tap()
        }
        select("Library", in: app)
        sleep(1)
        attach(app, "01-library")

        tiles.firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "02-viewer")
        app.buttons["Close"].tap()

        select("People", in: app)
        XCTAssertTrue(app.staticTexts["People & Pets"].waitForExistence(timeout: 10))
        sleep(1)
        attach(app, "03-people")

        select("Search", in: app)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("maple")
        sleep(2)
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        }
        sleep(1)
        attach(app, "04-search")

        select("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Backup"].waitForExistence(timeout: 8))
        sleep(1)
        attach(app, "05-settings")
    }
}
