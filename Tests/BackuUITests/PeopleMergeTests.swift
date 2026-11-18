import XCTest

/// The People grid can select several duplicate groups and merge them in one go.
final class PeopleMergeTests: XCTestCase {
    private var bootstrap: String {
        """
        {"servers":[{"name":"Preview","provider":"custom","endpoint":"http://127.0.0.1:9010","region":"us-east-1","bucket":"backu-preview","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":false,"faceRecognitionEnabled":true,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":false}}
        """
    }

    func testSelectAndMergePeople() throws {
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
        if app.buttons["tabs.show"].waitForExistence(timeout: 3) {
            app.buttons["tabs.show"].tap()
        }
        app.buttons["tab.people"].tap()
        XCTAssertTrue(app.staticTexts["People & Pets"].waitForExistence(timeout: 10), "People screen missing")

        let cells = app.buttons.matching(identifier: "people.name")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 90), "Face analysis never produced people")
        XCTAssertGreaterThan(cells.count, 1, "Need at least two people to merge")

        app.buttons["people.select"].tap()
        cells.element(boundBy: 0).tap()
        cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["people.mergeSelected"].isEnabled)
        app.buttons["people.mergeSelected"].tap()

        let merge = app.buttons["Merge"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 10), "Merge sheet did not appear")
        merge.tap()

        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Merged'")).firstMatch
                .waitForExistence(timeout: 10),
            "People were not merged"
        )
        XCTAssertTrue(app.buttons["people.select"].exists, "Selection mode did not end")
    }
}
