import XCTest

/// Viewer regressions that the main `ViewerInteractionTests` suite does not
/// cover, added while reviewing the presentation-scoped viewer fix:
///
/// * a tile tapped after the grid has been flung far down, where the tile's
///   absolute index (and therefore the pager's window offset) is unknown;
/// * a tile tapped in Search results, whose presentation window is the result
///   set rather than the library.
final class ViewerInteractionRegressionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
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

    private func attach(_ app: XCUIApplication, text name: String) {
        let attachment = XCTAttachment(string: name)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launchEnvironment["BACKU_PROBE"] = "1"
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

    private func probe(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(identifier: "viewer.probe").firstMatch
        guard element.waitForExistence(timeout: 2) else { return "probe unavailable" }
        return element.value as? String ?? "probe empty"
    }

    private func page(_ app: XCUIApplication) -> Int {
        let element = app.otherElements.matching(identifier: "viewer.page").firstMatch
        guard element.waitForExistence(timeout: 2) else { return -1 }
        let value = element.value as? String ?? ""
        return Int(value.split(separator: " ").first ?? "") ?? -1
    }

    private func waitForPage(_ app: XCUIApplication, equals expected: Int, timeout: TimeInterval = 10) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = page(app)
        while latest != expected, Date() < deadline {
            usleep(100_000)
            latest = page(app)
        }
        return latest
    }

    private func waitForViewerValue(_ app: XCUIApplication, equals expected: String, timeout: TimeInterval = 10) -> String {
        let photo = app.images["viewer.photo"].firstMatch
        guard photo.waitForExistence(timeout: timeout) else { return "viewer.photo missing" }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: photo
        )
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return photo.value as? String ?? "no value"
    }

    private func dateLabel(fromTileLabel label: String) -> String {
        let parts = label.components(separatedBy: ", ")
        return parts.count > 1 ? parts[1] : label
    }

    /// "Photo, 2 April 2026" (optionally followed by ", 2 people") → "2 April 2026".
    func testFarScrolledTileOpensItsOwnPhoto() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No tiles")
        usleep(1_000_000)
        let firstDate = dateLabel(fromTileLabel: tiles.firstMatch.label)

        for _ in 0..<5 {
            app.swipeUp(velocity: .fast)
            usleep(400_000)
        }
        sleep(2)
        attach(app, "after-flings")

        let window = app.windows.firstMatch.frame
        var target: (index: Int, label: String, frame: CGRect)?
        for index in 0..<tiles.count {
            let element = tiles.element(boundBy: index)
            guard element.exists else { continue }
            let frame = element.frame
            if target == nil, element.isHittable,
               frame.midY > window.minY + 180, frame.midY < window.maxY - 220 {
                target = (index, element.label, frame)
            }
        }
        guard let (index, label, frame) = target else {
            XCTFail("No hittable tile after five flings")
            return
        }

        let expected = dateLabel(fromTileLabel: label)
        tiles.element(boundBy: index).tap()
        XCTAssertTrue(
            app.otherElements.matching(identifier: "viewer.page").firstMatch.waitForExistence(timeout: 10),
            "A tile scrolled far down never opened the viewer"
        )
        let shown = waitForViewerValue(app, equals: expected)
        let landed = page(app)
        attach(app, "flung-tap")
        attach(
            app,
            text: "tile \(index) \"\(label)\" at \(frame) → shown \(shown), page \(landed) · \(probe(app))"
        )
        XCTAssertEqual(shown, expected, "A tile scrolled far down opened a different photo")
        XCTAssertGreaterThan(landed, 1, "A tile scrolled far down opened the first photo")
        if expected != firstDate {
            XCTAssertNotEqual(shown, firstDate, "A tile scrolled far down reopened the first photo")
        }
    }

    /// Opening from Search uses the result set as the pager's window, not the
    /// whole library. `photoIDs` therefore differ from the library's, and the
    /// page position is relative to the results.
    func testSearchResultOpensWithinTheSearchWindow() throws {
        let app = launch()
        XCTAssertTrue(
            app.buttons.matching(identifier: "library.tile").firstMatch.waitForExistence(timeout: 30),
            "No tiles"
        )
        app.buttons["search.open"].tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field missing")
        field.tap()
        // Matches the IMG_5104, IMG_5105 and IMG_5120 fixtures. A simulator
        // that has accumulated duplicate assets can match more, so the count is
        // read from the screen rather than assumed.
        field.typeText("IMG_51")

        let countLabel = app.staticTexts["search.resultCount"]
        XCTAssertTrue(
            countLabel.waitForExistence(timeout: 15),
            "Search did not report how many photos matched"
        )
        let resultCount = Int(countLabel.label.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(
            resultCount, 3,
            "\"IMG_51\" should match at least the three IMG_51xx fixtures, search reported \(resultCount)"
        )

        // The library behind the search cover keeps its own tiles in the
        // accessibility tree; only the cover's results are hittable.
        let visible = app.buttons.matching(identifier: "library.tile").allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertGreaterThanOrEqual(visible.count, 2, "Search showed fewer than two hittable results")
        let second = visible[1]
        let label = second.label
        let expected = dateLabel(fromTileLabel: label)
        second.tap()
        XCTAssertTrue(
            app.otherElements.matching(identifier: "viewer.page").firstMatch.waitForExistence(timeout: 10),
            "A search result never opened the viewer"
        )
        let shown = waitForViewerValue(app, equals: expected)
        let landed = waitForPage(app, equals: 2)
        let state = probe(app)
        attach(app, "search-result")
        attach(
            app,
            text: "search result 2 \"\(label)\" of \(resultCount) → shown \(shown), page \(landed) · \(state)"
        )
        XCTAssertEqual(shown, expected, "A search result opened a different photo")
        XCTAssertEqual(landed, 2, "A search result opened at the wrong position in its window")
        XCTAssertTrue(
            state.contains("page=2/\(resultCount);"),
            "The viewer's window is not the \(resultCount) search results: \(state)"
        )
    }
}
