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

    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launchArguments += extraArguments
        app.launch()
        allowPhotoAccess(app)
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
        return app
    }

    /// Every visible month card must sit inside the screen. A card carries its
    /// date pill at its leading edge, so a card wider than the viewport (and
    /// therefore centred off the left edge) is what clips the pill.
    private func assertMonthCardsFit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let cards = app.buttons.matching(identifier: "library.monthCard")
        let examined = min(cards.count, 4)
        XCTAssertGreaterThan(examined, 0, "No month cards to measure", file: file, line: line)
        for index in 0..<examined {
            let card = cards.element(boundBy: index)
            guard card.exists, card.frame.width > 0 else { continue }
            XCTAssertGreaterThanOrEqual(
                card.frame.minX, window.minX - 0.5,
                "Month card \(index) starts left of the screen: \(card.frame) vs \(window)",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                card.frame.maxX, window.maxX + 0.5,
                "Month card \(index) runs past the screen: \(card.frame) vs \(window)",
                file: file, line: line
            )
        }
    }

    /// The bottom bar is conditional: timeline mode shows the level switcher,
    /// the Library circle reveals the tab bar, and tapping Library goes back.
    func testBottomBarSwitchesBetweenTimelineAndTabs() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 25), "No photo tiles")

        XCTAssertTrue(app.buttons["library.level.all"].exists, "Timeline switcher missing")
        XCTAssertTrue(app.buttons["tabs.show"].exists, "Library circle missing")
        XCTAssertFalse(app.buttons["tab.people"].exists, "Tab bar is showing in timeline mode")
        attach(app, "timeline-bar-01-levels")

        app.buttons["tabs.show"].tap()
        XCTAssertTrue(app.buttons["tab.people"].waitForExistence(timeout: 5), "Tab bar did not appear")
        attach(app, "timeline-bar-02-tabs")

        app.buttons["tab.library"].tap()
        XCTAssertTrue(app.buttons["library.level.all"].waitForExistence(timeout: 5), "Timeline did not return")
        attach(app, "timeline-bar-03-back-to-levels")
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
        sleep(1)
        assertMonthCardsFit(app)
        attach(app, "timeline-01c-months-direct")
        // Scroll a little: the pill floats over the first collage and is the
        // part that used to be clipped by the screen edge.
        app.swipeUp(velocity: .slow)
        sleep(1)
        assertMonthCardsFit(app)
        attach(app, "timeline-01d-months-pill")
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
        assertMonthCardsFit(app)
        app.swipeUp()
        sleep(1)
        assertMonthCardsFit(app)
        attach(app, "timeline-04-months-scrolled")
        XCTAssertTrue(monthCard.exists, "Months timeline disappeared while scrolling")

        // A month drills into the continuous All grid.
        monthCard.tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Tapping a month did not show the grid")
        attach(app, "timeline-05-all-from-month")

        // Pinching out enlarges the grid to the full-width level.
        let before = tiles.firstMatch.frame.width
        // Give the 3-column bitmaps time to finish so the probe has a baseline.
        sleep(2)
        let beforePixels = imageSizeProbe(app)
        app.windows.firstMatch.pinch(withScale: 3, velocity: 2)
        sleep(3)
        let after = app.buttons.matching(identifier: "library.tile").firstMatch.frame.width
        let afterPixels = imageSizeProbe(app)
        attach(app, "timeline-06-full-width")
        XCTAssertGreaterThan(after, before * 2, "Pinch did not enlarge the photos")
        print("PERF · pinch density before [\(beforePixels.raw)] after [\(afterPixels.raw)] frame \(before)->\(after)")
        // The frame got wider, but the bitmap must have been reloaded at the new
        // density instead of upscaling the old 3-column decode forever.
        XCTAssertGreaterThan(beforePixels.width, 0, "No final thumbnails were reported before the pinch (\(beforePixels.raw))")
        XCTAssertLessThan(beforePixels.age, 5, "Before-pinch density sample is stale (\(beforePixels.raw))")
        XCTAssertGreaterThan(
            afterPixels.width, beforePixels.width * 2,
            "Pinch widened the tiles but did not reload a higher-density bitmap (\(beforePixels.raw) -> \(afterPixels.raw))"
        )
        // A positive signal independent of the baseline: the final bitmap is
        // higher-density than the full-width tile's point size, i.e. it was
        // decoded for this slot and not merely upscaled from a grid thumbnail.
        XCTAssertGreaterThan(
            afterPixels.width, after * 1.5,
            "Full-width tile kept a low-density bitmap (\(afterPixels.raw), tile \(after)pt)"
        )
        XCTAssertLessThan(afterPixels.age, 5, "After-pinch density sample is stale (\(afterPixels.raw))")
    }

    /// At the very top of All, the first photo must occupy the first column.
    /// A header view living in the grid used to consume a cell, leaving column
    /// zero empty forever.
    func testAllGridStartsInFirstColumn() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photo tiles")
        // Let the first row settle so frames are final.
        sleep(1)

        let first = tiles.element(boundBy: 0)
        let second = tiles.element(boundBy: 1)
        let third = tiles.element(boundBy: 2)
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(first.frame.minX, window.minX, accuracy: 1, "First tile is not on the leading edge")
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1, "The first three tiles are not in one row")
        XCTAssertEqual(second.frame.minX, first.frame.maxX + 2, accuracy: 1, "Second tile does not follow the first")
        XCTAssertEqual(third.frame.minX, second.frame.maxX + 2, accuracy: 1, "Third tile does not follow the second")
        XCTAssertEqual(third.frame.maxX, window.maxX, accuracy: 1, "First row does not end on the trailing edge")

        attach(app, "timeline-09-all-top-left")
    }

    /// The same invariant in landscape, where the safe-area insets narrow the
    /// scroll content. Cards fill that content and must not become horizontally
    /// scrollable or hang under the notch side.
    func testMonthsCardsFitInLandscape() throws {
        let app = launch()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photo tiles")

        app.buttons["library.level.months"].tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "library.monthCard").firstMatch.waitForExistence(timeout: 15),
            "Months level showed no month cards"
        )
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        assertMonthCardsFit(app)
        attach(app, "timeline-10-months-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
    }

    /// A cancelled load must never overwrite a newer density. `ImageCache`
    /// resumes a cancelled caller when its shared decode finishes, so a rapid
    /// 3 → 1 → 3 → 1 pinch with scrolling in between races old and new loads.
    /// `width` (trailing maximum) would hide an old-density write, so this
    /// checks `last` — the most recent density recorded — is the full-width
    /// slot's.
    func testRapidPinchKeepsCurrentDensity() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photo tiles")
        sleep(1)

        // 3 columns -> full width.
        app.windows.firstMatch.pinch(withScale: 3, velocity: 2)
        app.swipeUp(velocity: .fast)
        // Full width -> 3 columns.
        app.windows.firstMatch.pinch(withScale: 0.34, velocity: -2)
        app.swipeUp(velocity: .fast)
        // 3 columns -> full width again, so old 3-column loads are in flight.
        app.windows.firstMatch.pinch(withScale: 3, velocity: 2)
        sleep(2)

        let frame = tiles.firstMatch.frame.width
        // Wait for the current density to settle (bounded); a "Ready" flag on
        // an outdated bitmap would never satisfy the last check and the
        // assertions below still fail.
        let deadline = Date().addingTimeInterval(8)
        var sample = imageSizeProbe(app)
        while Date() < deadline {
            let ready = (tiles.firstMatch.value as? String) == "Ready"
            sample = imageSizeProbe(app)
            if ready, sample.last > frame * 1.5, sample.age < 5 { break }
            usleep(300_000)
        }
        XCTAssertGreaterThan(sample.width, 0, "No final thumbnails were recorded (\(sample.raw))")
        print("PERF · rapid pinch density [\(sample.raw)] frame \(frame)pt")
        XCTAssertLessThan(sample.age, 5, "Density sample is stale (\(sample.raw))")
        XCTAssertEqual(
            sample.last, sample.width,
            "An outdated density was written last, after the full-width decode (\(sample.raw))"
        )
        XCTAssertGreaterThan(
            sample.last, frame * 1.5,
            "Tile kept an old-density bitmap in the full-width slot (\(sample.raw), tile \(frame)pt)"
        )
        XCTAssertEqual(
            tiles.firstMatch.value as? String, "Ready",
            "Tile did not report Ready at the current density"
        )
        attach(app, "timeline-12-rapid-pinch")
    }

    /// The date pill is part of the card, not a layout sibling, so the card
    /// cannot grow past the screen when the text grows. This is the case that
    /// used to push the first pill's leading cap off the left edge.
    func testMonthsDatePillStaysInsideCardAtLargeType() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        // The launch argument is not reliably applied by the runner; this
        // DEBUG seam sets the category on the library subtree itself.
        app.launchEnvironment["BACKU_UI_TEXT_SIZE"] = "accessibility5"
        // Full month names are the width case that actually overflowed the
        // card; the shipped abbreviation is too narrow to reproduce it.
        app.launchEnvironment["BACKU_MONTH_TITLE_STYLE"] = "long"
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        allowPhotoAccess(app)
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")

        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No photo tiles")

        app.buttons["library.level.months"].tap()
        let firstMonth = app.buttons.matching(identifier: "library.monthCard").firstMatch
        XCTAssertTrue(firstMonth.waitForExistence(timeout: 15), "Months level showed no month cards")
        sleep(1)
        // Positive large-type signal: the pill is visibly tall, so the test
        // cannot pass because the override silently did nothing.
        let pill = app.descendants(matching: .any).matching(identifier: "perf.monthPill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Month pill probe missing")
        let pillHeight = Double((pill.value as? String) ?? "") ?? 0
        XCTAssertGreaterThan(pillHeight, 55, "Large-type override did not apply (pill height \(pillHeight)pt)")
        assertMonthCardsFit(app)
        attach(app, "timeline-07-months-large-type")

        // A long month name is the case that actually overflowed the card at
        // large type (the short "Jun 2026" fits). Find one and hold it to the
        // same invariant; HEAD's card grows past the screen here.
        if let longMonth = longMonthCard(app) {
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThanOrEqual(longMonth.frame.minX, window.minX - 0.5, "Long month card starts left of the screen: \(longMonth.frame)")
            XCTAssertLessThanOrEqual(longMonth.frame.maxX, window.maxX + 0.5, "Long month card runs past the screen: \(longMonth.frame)")
            attach(app, "timeline-11-long-month-large-type")
        } else {
            XCTFail("No long-month card became visible to check the overflow case")
        }

        app.swipeUp(velocity: .slow)
        sleep(1)
        assertMonthCardsFit(app)
        attach(app, "timeline-08-months-large-type-scrolled")
    }

    /// Scrolls the Months timeline until a month whose name is long enough to
    /// overflow a card at large type is on screen.
    private func longMonthCard(_ app: XCUIApplication) -> XCUIElement? {
        let names = ["September", "November", "December", "February", "January"]
        let window = app.windows.firstMatch.frame
        for _ in 0..<12 {
            let cards = app.buttons.matching(identifier: "library.monthCard")
            for index in 0..<min(cards.count, 30) {
                let card = cards.element(boundBy: index)
                guard card.exists, card.frame.intersects(window) else { continue }
                if names.contains(where: { card.label.hasPrefix($0) }) { return card }
            }
            app.swipeUp()
            sleep(1)
        }
        return nil
    }

    /// `perf.imageSize` reports the widest requested density in its window,
    /// the most recent one, and its age, plus the raw string for diagnostics.
    private struct ImageDensitySample {
        var width = 0.0
        var last = 0.0
        var age = 0.0
        var raw = ""
    }

    private func imageSizeProbe(_ app: XCUIApplication) -> ImageDensitySample {
        let element = app.descendants(matching: .any).matching(identifier: "perf.imageSize").firstMatch
        guard element.exists, let raw = element.value as? String else { return ImageDensitySample() }
        var sample = ImageDensitySample()
        sample.raw = raw
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=")
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "width": sample.width = Double(pair[1]) ?? 0
            case "last": sample.last = Double(pair[1]) ?? 0
            case "age": sample.age = Double(pair[1]) ?? 0
            default: break
            }
        }
        return sample
    }

    private func allowPhotoAccess(_ app: XCUIApplication) {
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
    }
}
