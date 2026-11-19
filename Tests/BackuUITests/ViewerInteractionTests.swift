import XCTest

/// Drives the full-screen viewer the way a person does: paging, zooming,
/// panning and the swipe-down dismissal. Also captures the feel of each step so
/// gesture regressions are visible in the result bundle.
final class ViewerInteractionTests: XCTestCase {
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

    private func launch(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launchEnvironment["BACKU_PROBE"] = "1"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 2) { springboardAllow.tap() }
        // Permission is never requested implicitly, so a clean simulator lands
        // on the library's access call to action instead of a system alert.
        let ask = app.buttons["Allow Photo Access"]
        if ask.waitForExistence(timeout: 2) {
            ask.tap()
            if springboardAllow.waitForExistence(timeout: 4) { springboardAllow.tap() }
        }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
        return app
    }

    @discardableResult
    private func openFirstPhoto(_ app: XCUIApplication) -> XCUIElement {
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No tiles")
        tiles.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["viewer.page"].waitForExistence(timeout: 10), "Viewer never appeared")
        sleep(2)
        return app.windows.firstMatch
    }

    private func probe(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(identifier: "viewer.probe").firstMatch
        guard element.waitForExistence(timeout: 2) else { return "probe unavailable" }
        return element.value as? String ?? "probe empty"
    }

    private func page(_ app: XCUIApplication) -> Int {
        let element = app.otherElements["viewer.page"]
        guard element.waitForExistence(timeout: 2) else { return -1 }
        let value = element.value as? String ?? ""
        // "3 of 27"
        return Int(value.split(separator: " ").first ?? "") ?? -1
    }

    private func doubleTap(_ window: XCUIElement, dx: CGFloat, dy: CGFloat) {
        window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).doubleTap()
    }

    private func drag(
        _ window: XCUIElement,
        from: CGVector,
        to: CGVector,
        velocity: XCUIGestureVelocity = .default
    ) {
        let start = window.coordinate(withNormalizedOffset: from)
        let end = window.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0.05)
    }

    /// "Photo, 2 April 2026" (optionally followed by ", 2 people") → the date
    /// the viewer's photo element reports for that same photo.
    private func dateLabel(fromTileLabel label: String) -> String {
        let parts = label.components(separatedBy: ", ")
        return parts.count > 1 ? parts[1] : label
    }

    /// Waits for the viewer to settle on a photo instead of reading the value
    /// in the frame the push begins, when the pager is still on its old page.
    private func waitForViewerValue(
        _ app: XCUIApplication,
        equals expected: String,
        timeout: TimeInterval = 10
    ) -> String {
        let photo = app.images["viewer.photo"].firstMatch
        guard photo.waitForExistence(timeout: timeout) else { return "viewer.photo missing" }
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: photo)
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return photo.value as? String ?? "no value"
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

    /// Tapping a tile must open *that* tile's photo, with the roll positioned on
    /// it. `ViewerScreen`'s presentation-scoped `@State` used to survive into
    /// the next push (SwiftUI reuses the `navigationDestination(item:)` view),
    /// so after the first photo every later tap reopened the first one — the
    /// presentation itself was right, which is why this checks the page within
    /// the window as well as the photo on screen.
    func testTappingTilesOpensTheTappedPhoto() throws {
        let app = launch()
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No tiles")
        XCTAssertGreaterThanOrEqual(
            tiles.count, 10,
            "The library only has \(tiles.count) tiles; this test needs ten to tap 0, 4 and 9"
        )

        var labels: [Int: String] = [:]
        for index in 0..<12 where index < tiles.count {
            labels[index] = tiles.element(boundBy: index).label
        }
        attach(
            app,
            text: "tiles: " + labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
        )

        for index in [0, 4, 9] {
            let tile = tiles.element(boundBy: index)
            // Read the date from the live tile on every tap. A label captured
            // before the first viewer could be stale by the time of the third
            // tap, and a stale expectation can pass while showing the wrong
            // photo.
            let expected = dateLabel(fromTileLabel: tile.label)
            tile.tap()
            XCTAssertTrue(
                app.otherElements["viewer.page"].waitForExistence(timeout: 10),
                "Tap \(index) never opened the viewer"
            )

            // The grid's first 60 tiles are the start of the viewer's window,
            // so the tapped tile is page k + 1 of the presentation.
            let shown = waitForViewerValue(app, equals: expected)
            let landed = waitForPage(app, equals: index + 1)
            attach(app, "tapped-tile-\(index)")
            attach(app, text: "tap \(index): expected \(expected) · shown \(shown) · page \(landed) · \(probe(app))")
            XCTAssertEqual(shown, expected, "Tap \(index) opened the wrong photo (page \(landed))")
            XCTAssertEqual(landed, index + 1, "Tap \(index) opened \(expected) at the wrong position in the roll")

            app.buttons["Close"].tap()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Close did not return to the grid")
            usleep(600_000)
        }

        // The tile menu's Details entry is a second way into the viewer, with
        // the info panel already open. The last photo opened above was tile 9
        // (page 10), so Details on tile 3 has to start from tile 3: the page
        // position and the photo's own VoiceOver label both catch a viewer that
        // reused the previous push.
        let detailsIndex = 3
        let detailsTile = tiles.element(boundBy: detailsIndex)
        let detailsExpected = dateLabel(fromTileLabel: detailsTile.label)
        detailsTile.press(forDuration: 1)
        let details = app.buttons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), "The tile menu did not offer Details")
        details.tap()
        XCTAssertTrue(
            app.navigationBars["Details"].waitForExistence(timeout: 5),
            "Details did not open the info panel"
        )
        // The sheet names the file; the tile itself does not expose it, so this
        // only proves the panel described a real photo, while the page and the
        // photo's label below prove *which* one.
        let fileName = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'IMG_'")).firstMatch
        let named = fileName.waitForExistence(timeout: 5) ? fileName.label : "missing"
        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.navigationBars["Details"].waitForNonExistence(timeout: 5),
            "The info sheet did not close"
        )
        XCTAssertTrue(
            app.otherElements["viewer.page"].waitForExistence(timeout: 10),
            "Details never opened the viewer"
        )
        let detailsShown = waitForViewerValue(app, equals: detailsExpected)
        let detailsPage = waitForPage(app, equals: detailsIndex + 1)
        let detailsPhoto = app.images["viewer.photo"].firstMatch
        attach(app, "tile-details")
        attach(
            app,
            text: "Details on tile \(detailsIndex): expected \(detailsExpected) · shown \(detailsShown) · page \(detailsPage) · label \(detailsPhoto.label) · file \(named)"
        )
        XCTAssertNotEqual(named, "missing", "The info panel did not name the photo's file")
        XCTAssertEqual(detailsShown, detailsExpected, "The Details menu opened a different photo")
        XCTAssertEqual(detailsPage, detailsIndex + 1, "The Details menu opened at the wrong position in the roll")
        XCTAssertTrue(
            detailsPhoto.label.hasPrefix("Photo \(detailsIndex + 1) of "),
            "The Details menu opened a different photo in the roll: \(detailsPhoto.label)"
        )
        app.buttons["Close"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Close did not return to the grid")
    }

    /// A slow pinch must read as one continuous ramp, with the photo held on
    /// the pinch point and no inset churn under the fingers. The zoom layout
    /// used to reassign `contentInset` on every tick, which rewrote the content
    /// offset mid-gesture and moved a zoom-out in visible steps; the probe
    /// records every tick a pinch reports.
    ///
    /// Landscape is deliberate: the fixture photos are square, so in portrait
    /// they fill the viewport exactly and insets are zero either way. In
    /// landscape the fit is letterboxed — the layout where the old per-tick
    /// inset rewrite shifted the photo, and where the new centring has to keep
    /// it in the middle as it grows past the viewport.
    ///
    /// The run is measured on a pinch-in because XCUITest cannot deliver a
    /// pinch-out once the photo is magnified — the probe records no
    /// `scrollViewWillBeginZooming` at all for that gesture. Zoom-out runs the
    /// same `scrollViewDidZoom` path in the other direction, and the probe's
    /// inset count is what pins down the churn that made zoom-out step.
    func testPinchZoomIsContinuous() throws {
        let app = launch()
        _ = openFirstPhoto(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)

        let photo = app.images["viewer.photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "The photo is missing after rotating")
        photo.pinch(withScale: 3, velocity: 2)
        sleep(1)
        let state = probe(app)
        attach(app, "landscape-pinch")
        attach(app, text: "slow pinch: \(state)")

        XCTAssertGreaterThan(value(state, key: "scale"), 2, "The pinch did not zoom: \(state)")
        XCTAssertGreaterThanOrEqual(
            value(state, key: "zoomN"), 8,
            "The pinch reported too few samples to judge continuity: \(state)"
        )
        XCTAssertGreaterThanOrEqual(
            value(state, key: "zoomSpan"), 1.2,
            "The pinch did not travel across the zoom range: \(state)"
        )
        // Samples are clamped to the scroll view's zoom range, so the intended
        // rubber band cannot read as a reversal. The run's top also has to be
        // the scale the gesture settled on — a stale summary would not be.
        XCTAssertEqual(
            value(state, key: "zoomMax"), value(state, key: "scale"), accuracy: 0.05,
            "The run did not end at its highest sample: \(state)"
        )
        XCTAssertLessThanOrEqual(value(state, key: "zoomBack"), 1, "The zoom reversed direction mid-pinch: \(state)")
        XCTAssertLessThanOrEqual(value(state, key: "zoomStep"), 0.25, "The zoom moved in visible steps: \(state)")
        XCTAssertEqual(value(state, key: "zoomInset"), 0, "The pinch rewrote contentInset under the fingers: \(state)")
        XCTAssertLessThanOrEqual(value(state, key: "zoomDrift"), 0.03, "The photo drifted off the pinch point: \(state)")
        XCTAssertLessThanOrEqual(value(state, key: "zoomCentreStep"), 0.03, "The photo jumped while zooming: \(state)")
        // The gesture must settle inside the photo's bounds, not rest over the
        // edge that the rubber band reached.
        XCTAssertLessThanOrEqual(value(state, key: "over"), 1, "The pinch settled out of bounds: \(state)")

        // Push past maximumZoomScale: the bounce above the limit is the
        // intended rubber band. Clamped samples must keep it out of the
        // summary, and the gesture must still settle in bounds.
        photo.pinch(withScale: 2, velocity: 2)
        sleep(1)
        let overshoot = probe(app)
        attach(app, "pinch-at-maximum")
        attach(app, text: "pinch past maximum zoom: \(overshoot)")
        // The second pinch has to be a new run: without this the assertions
        // below could re-read the first pinch's summary and pass.
        XCTAssertEqual(
            value(overshoot, key: "zoomRuns"), value(state, key: "zoomRuns") + 1,
            "The saturating pinch did not produce a new run: \(overshoot)"
        )
        // The live scale pins the gesture at the limit (the first pinch left it
        // near 2.9), and the run has to have covered that distance in small
        // steps. `zoomMax` is an equality because the probe clamps samples to
        // the scroll view's range: it can only be 4 if the pinch reached the
        // limit, and it would read the rubber-band peak if the clamp were lost.
        XCTAssertEqual(value(overshoot, key: "scale"), 4, accuracy: 0.05, "The pinch did not reach maximum zoom: \(overshoot)")
        XCTAssertEqual(value(overshoot, key: "zoomMax"), 4, accuracy: 0.02, "The run did not reach maximum zoom: \(overshoot)")
        XCTAssertGreaterThanOrEqual(value(overshoot, key: "zoomSpan"), 1, "The second pinch did not span the range: \(overshoot)")
        XCTAssertLessThanOrEqual(value(overshoot, key: "zoomStep"), 0.25, "The zoom moved in visible steps: \(overshoot)")
        XCTAssertLessThanOrEqual(value(overshoot, key: "zoomBack"), 1, "The rubber band read as a reversed pinch: \(overshoot)")
        XCTAssertEqual(value(overshoot, key: "zoomInset"), 0, "The pinch rewrote contentInset at maximum zoom: \(overshoot)")
        XCTAssertLessThanOrEqual(value(overshoot, key: "over"), 1, "The pinch settled out of bounds at maximum zoom: \(overshoot)")

        // Zoom back out. The offset the pinch left at the edge has to settle
        // inside the photo — and to zero once it is back at fit — instead of
        // leaving the viewer reporting a transient overpan.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        sleep(1)
        let reset = probe(app)
        attach(app, "reset-from-maximum")
        attach(app, text: "double-tap reset: \(reset)")
        XCTAssertEqual(value(reset, key: "scale"), 1, accuracy: 0.05, "The reset did not return to fit: \(reset)")
        XCTAssertLessThanOrEqual(value(reset, key: "over"), 1, "The zoom-out settled out of bounds: \(reset)")
        // The reset is a programmatic zoom: it must not be recorded as a pinch
        // run, so the summary read above is still the pinch's.
        XCTAssertEqual(
            value(reset, key: "zoomRuns"), value(overshoot, key: "zoomRuns"),
            "The programmatic reset was recorded as a pinch run: \(reset)"
        )
    }

    /// The floating date capsule must stay on screen and clear of the round
    /// buttons at an accessibility text size, where a long date used to be
    /// pushed past (or under) the edge.
    func testTopBarFitsAtAccessibilityTextSize() throws {
        let app = launch(environment: [
            "BACKU_VIEWER_TEXT_SIZE": "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        _ = openFirstPhoto(app)

        let date = app.staticTexts["viewer.date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5), "The viewer date label is missing")
        let window = app.windows.firstMatch.frame
        let close = app.buttons["Close"].frame
        let frame = date.frame
        attach(app, "top-bar-accessibility-text")
        attach(
            app,
            text: "date \"\(date.label)\" \(frame) · close \(close) · window \(window)"
        )

        XCTAssertGreaterThan(frame.width, 0, "The date label has no width")
        // The default date label is about 20pt tall; anything under 28 means
        // the oversized layout was not actually exercised.
        XCTAssertGreaterThan(frame.height, 28, "The accessibility text size did not apply")
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX, "The date runs off the leading edge")
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "The date runs off the trailing edge")
        XCTAssertTrue(frame.maxX <= close.minX || frame.minX >= close.maxX, "The date overlaps the close button")

        let favourite = app.buttons["Remove favorite"].exists
            ? app.buttons["Remove favorite"]
            : app.buttons["Favorite"]
        if favourite.exists {
            XCTAssertTrue(
                frame.maxX <= favourite.frame.minX || frame.minX >= favourite.frame.maxX,
                "The date overlaps the favourite button"
            )
        }

        // VoiceOver must meet Close before the date and time. The capsule is
        // hoisted above the buttons to be laid out on its own, so the stack
        // order (not the visual order) decides what a person hears first.
        let tree = app.descendants(matching: .any).allElementsBoundByIndex
        let closeIndex = tree.firstIndex { $0.elementType == .button && $0.label == "Close" }
        let dateIndex = tree.firstIndex { $0.identifier == "viewer.date" }
        attach(
            app,
            text: "accessibility order: close \(String(describing: closeIndex)) · date \(String(describing: dateIndex))"
        )
        XCTAssertNotNil(closeIndex, "The Close button is missing from the accessibility tree")
        XCTAssertNotNil(dateIndex, "The date is missing from the accessibility tree")
        if let closeIndex, let dateIndex {
            XCTAssertLessThan(closeIndex, dateIndex, "VoiceOver reads the date before the Close button")
        }
    }

    func testViewerGestures() throws {
        let app = launch()
        attach(app, "viewer-01-library")

        let window = openFirstPhoto(app)
        attach(app, "viewer-02-open")

        // A single slow page swipe.
        window.swipeLeft()
        sleep(1)
        attach(app, "viewer-03-page-left")

        // Rapid paging, like flicking through a roll.
        for _ in 0..<4 {
            window.swipeLeft()
        }
        sleep(1)
        attach(app, "viewer-04-paged-fast")
        attach(app, text: "after 4 immediate swipes: page \(page(app)) · \(probe(app))")

        for _ in 0..<3 {
            window.swipeRight()
        }
        sleep(1)
        attach(app, "viewer-05-paged-back")
        attach(app, text: "after 3 immediate back swipes: page \(page(app)) · \(probe(app))")

        // Pinch to zoom, then pan around, then reset with a double tap.
        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        attach(app, "viewer-06-zoomed")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)))
        sleep(1)
        attach(app, "viewer-07-panned")

        window.doubleTap()
        sleep(1)
        attach(app, "viewer-08-double-tap-reset")

        // A small pull must rubber-band back, not dismiss.
        let pullStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        pullStart.press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        sleep(1)
        attach(app, "viewer-09-pull-cancelled")
        XCTAssertTrue(app.otherElements["viewer.page"].exists, "A small pull dismissed the viewer")

        // And a full pull dismisses back into the grid.
        pullStart.press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
            withVelocity: .default,
            thenHoldForDuration: 0.05
        )
        sleep(1)
        attach(app, "viewer-10-dismissed")
        XCTAssertFalse(app.otherElements["viewer.page"].exists, "A full pull did not dismiss the viewer")
    }

    /// Opening the viewer must not build a controller (and its scroll view,
    /// image view and gesture recognisers) for every photo in the presentation
    /// window, and paging the whole roll must not grow memory without bound.
    func testViewerOnlyPreparesNearbyPages() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let opened = probe(app)
        attach(app, text: "open: \(opened)")
        XCTAssertTrue(opened.contains("live="), opened)

        XCTAssertLessThanOrEqual(
            value(opened, key: "live"), 5,
            "Opening built a page controller per photo: \(opened)"
        )
        XCTAssertLessThanOrEqual(
            value(opened, key: "setup"), 25,
            "Page setup blocked the open transition: \(opened)"
        )

        var peak = value(opened, key: "mem")
        func swipeRoundTrip() -> String {
            for _ in 0..<10 {
                window.swipeLeft()
                usleep(350_000)
                peak = max(peak, value(probe(app), key: "mem"))
            }
            var last = ""
            for _ in 0..<10 {
                window.swipeRight()
                usleep(350_000)
                last = probe(app)
                peak = max(peak, value(last, key: "mem"))
                XCTAssertLessThanOrEqual(
                    value(last, key: "live"), 5,
                    "Resident page controllers grew while paging: \(last)"
                )
            }
            sleep(1)
            return last
        }

        let firstPass = swipeRoundTrip()
        attach(app, text: "first round trip: \(firstPass)")
        let secondPass = swipeRoundTrip()
        attach(app, text: "second round trip: \(secondPass)")
        let thirdPass = swipeRoundTrip()
        attach(app, "after three full-page round trips")
        attach(
            app,
            text: "third round trip: \(thirdPass) · peak \(String(format: "%.1f", peak))MB"
        )
        // The first passes fill the caches; after that the footprint has to be
        // flat. A leak shows up as one more identical step per pass.
        XCTAssertFalse(
            value(thirdPass, key: "mem").isNaN,
            "The probe did not report memory: \(thirdPass)"
        )
        XCTAssertLessThanOrEqual(
            value(thirdPass, key: "mem") - value(secondPass, key: "mem"), 12,
            "Paging the roll leaks memory: second \(secondPass), third \(thirdPass)"
        )
        XCTAssertLessThanOrEqual(
            value(thirdPass, key: "mem") - value(opened, key: "mem"), 140,
            "Paging the roll grows memory past the cache budget: open \(opened), settled \(thirdPass)"
        )
    }

    /// Drives ten flicks with no accessibility traffic in between, so the
    /// display-link sample measures the viewer rather than the test harness.
    func testPagingFrameBudget() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        sleep(1)
        let opened = probe(app)

        for _ in 0..<10 {
            window.swipeLeft()
        }
        sleep(2)
        let state = probe(app)
        attach(app, "ten flicks")
        attach(app, text: "open \(opened) → after ten flicks \(state)")
        // The measurement starts at page creation, so the open's own frames are
        // already in the count; the flicks have to add almost nothing.
        XCTAssertLessThanOrEqual(
            value(state, key: "drops") - value(opened, key: "drops"), 4,
            "Flicking through ten photos dropped frames: open \(opened), after \(state)"
        )
        XCTAssertLessThanOrEqual(
            value(state, key: "live"), 5,
            "Flicking through ten photos grew the page window: \(state)"
        )
        XCTAssertEqual(
            value(state, key: "sharp"), 1,
            "The photo did not sharpen after the roll stopped: \(state)"
        )
    }

    /// Four deliberate flicks must land four pages. Previously three of the
    /// four were swallowed or coalesced by the page view controller.
    func testRapidPagingLandsEverySwipe() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let start = page(app)
        attach(app, text: "start page \(start) · \(probe(app))")

        for index in 0..<8 {
            window.swipeLeft()
            usleep(450_000)
            attach(app, text: "after swipe \(index + 1): page \(page(app)) · \(probe(app))")
        }
        sleep(1)
        let landed = page(app)
        attach(app, "rapid-paging")
        XCTAssertEqual(landed, start + 8, "Eight flicks should land eight photos (start \(start), landed \(landed))")

        // And back again, with slightly slower gestures.
        for index in 0..<8 {
            window.swipeRight()
            usleep(450_000)
            attach(app, text: "after back swipe \(index + 1): page \(page(app))")
        }
        sleep(1)
        XCTAssertEqual(page(app), start, "Eight flicks back should return to the starting photo")
    }

    /// The chrome toggle must not feel like it ignored the tap. Pinning the
    /// finger-down → toggle latency catches any regression that reintroduces a
    /// wait for the double tap to fail (which used to cost ~430 ms).
    func testSingleTapTogglesChromePromptly() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        window.tap()
        XCTAssertTrue(
            app.buttons["Info"].waitForNonExistence(timeout: 2),
            "A tap did not hide chrome"
        )
        let state = probe(app)
        attach(app, text: "tap latency: \(state)")
        XCTAssertLessThan(value(state, key: "tap"), 200, "A single tap took too long to toggle chrome: \(state)")
    }

    /// A single tap toggles chrome; a drag that ends still must not.
    func testTapAndPanDoNotConflict() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        XCTAssertTrue(app.buttons["Info"].exists, "Chrome should start visible")

        // A pan should never be read as a tap.
        drag(window, from: CGVector(dx: 0.85, dy: 0.55), to: CGVector(dx: 0.15, dy: 0.55), velocity: .slow)
        sleep(1)
        XCTAssertTrue(app.buttons["Info"].exists, "A horizontal pan toggled chrome")
        XCTAssertEqual(page(app), 2, "A slow horizontal drag should page exactly once")

        // A tap must toggle, twice.
        window.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Info"].exists, "A tap did not hide chrome")
        attach(app, "chrome-hidden")
        window.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["Info"].exists, "A second tap did not restore chrome")
    }

    /// Double-tapping off-centre must zoom toward that point, then reset.
    func testDoubleTapZoomsTowardTapPoint() throws {
        let app = launch()
        let window = openFirstPhoto(app)

        doubleTap(window, dx: 0.78, dy: 0.45)
        sleep(1)
        let zoomed = probe(app)
        attach(app, "double-tap-anchored")
        attach(app, text: "after double tap: \(zoomed)")
        XCTAssertTrue(zoomed.contains("scale=2.5"), "Double tap did not zoom to 2.5x: \(zoomed)")
        let centerX = value(zoomed, key: "cx")
        XCTAssertEqual(centerX, 0.78, accuracy: 0.09, "Zoom did not anchor toward the tapped point: \(zoomed)")
        // Matches Photos: the first tap of the double tap toggles chrome once,
        // so a double tap while the chrome is showing hides it.
        XCTAssertFalse(app.buttons["Info"].exists, "A double tap should toggle chrome exactly once")

        // The same gesture at a different point, while zoomed, resets to fit.
        doubleTap(window, dx: 0.3, dy: 0.7)
        sleep(1)
        let reset = probe(app)
        attach(app, "double-tap-reset-zoomed")
        attach(app, text: "after reset: \(reset)")
        XCTAssertEqual(value(reset, key: "scale"), 1, accuracy: 0.02, "Double tap did not reset: \(reset)")
        XCTAssertTrue(app.buttons["Info"].exists, "The second double tap should restore chrome")
    }

    /// Panning while zoomed must stop at the image edge instead of exposing an
    /// empty black gutter, and page changes must reset zoom.
    func testPanIsClampedAndPagingResetsZoom() throws {
        let app = launch()
        let window = openFirstPhoto(app)

        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        attach(app, "pinch-zoomed")

        // Fling the photo hard in both directions; the scroll view should clamp.
        drag(window, from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.98, dy: 0.15), velocity: .fast)
        drag(window, from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.02, dy: 0.9), velocity: .fast)
        sleep(1)
        let state = probe(app)
        attach(app, "panned-to-edge")
        attach(app, text: "after edge pans: \(state)")
        XCTAssertLessThanOrEqual(value(state, key: "over"), 1, "Panning left the image bounds: \(state)")
        XCTAssertEqual(page(app), 1, "Panning a zoomed photo should not page")

        // A page change from a zoomed photo must reset the new page to fit.
        window.doubleTap()
        sleep(1)
        XCTAssertEqual(value(probe(app), key: "scale"), 1, accuracy: 0.02, "Double tap reset failed")
        window.swipeLeft()
        sleep(1)
        let next = probe(app)
        attach(app, text: "after paging from zoom: \(next)")
        XCTAssertEqual(value(next, key: "scale"), 1, accuracy: 0.02, "New page kept a stale zoom: \(next)")
    }

    /// With the photo zoomed to its right edge, continuing to drag left hands
    /// the gesture to the pager and lands the next photo.
    func testZoomedEdgePanPagesToNextPhoto() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let start = page(app)

        // Zoom in, then pan to the right edge.
        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        attach(app, text: "after pinch: page \(page(app)) · \(probe(app))")
        drag(window, from: CGVector(dx: 0.9, dy: 0.5), to: CGVector(dx: 0.05, dy: 0.5), velocity: .slow)
        sleep(1)
        attach(app, "zoomed-at-right-edge")
        attach(app, text: "after edge pan: page \(page(app)) · \(probe(app))")
        XCTAssertEqual(page(app), start, "Panning to the edge should not change photo by itself")

        // The next left drag has nowhere to pan, so it hands off and pages.
        drag(window, from: CGVector(dx: 0.9, dy: 0.5), to: CGVector(dx: 0.1, dy: 0.5), velocity: .slow)
        sleep(1)
        let landed = page(app)
        attach(app, "zoomed-edge-handed-off")
        attach(app, text: "edge hand-off: \(start) → \(landed) · \(probe(app))")
        XCTAssertEqual(landed, start + 1, "Dragging past the zoomed edge did not page: \(start) → \(landed)")
        XCTAssertEqual(value(probe(app), key: "scale"), 1, accuracy: 0.02, "The new page should start at fit")
    }

    /// Reduce Motion removes the zoom transition, so the viewer grows its own
    /// pull-to-dismiss. A short pull must spring back; a full one must close.
    func testReduceMotionPullDismisses() throws {
        let app = launch(environment: ["BACKU_REDUCE_MOTION": "1"])
        let window = openFirstPhoto(app)
        attach(app, "reduce-motion-open")
        XCTAssertTrue(app.otherElements["viewer.page"].exists)

        drag(
            window,
            from: CGVector(dx: 0.5, dy: 0.32),
            to: CGVector(dx: 0.5, dy: 0.46),
            velocity: .slow
        )
        sleep(1)
        attach(app, "reduce-motion-pull-cancelled")
        XCTAssertTrue(
            app.otherElements["viewer.page"].exists,
            "A short pull dismissed the viewer with Reduce Motion on"
        )

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(
                forDuration: 0.05,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                withVelocity: .fast,
                thenHoldForDuration: 0.05
            )
        sleep(1)
        attach(app, "reduce-motion-dismissed")
        XCTAssertFalse(
            app.otherElements["viewer.page"].exists,
            "A full pull did not dismiss the viewer with Reduce Motion on"
        )
    }

    /// Rotation changes the page width; the pager must keep its photo and still
    /// page afterwards instead of resting between two pages.
    func testRotationKeepsTheCurrentPhoto() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        window.swipeLeft()
        sleep(1)
        let before = page(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        attach(app, "landscape")
        XCTAssertEqual(page(app), before, "Rotation changed the photo")

        window.swipeLeft()
        sleep(1)
        attach(app, "landscape-paged")
        XCTAssertEqual(page(app), before + 1, "Paging broke after rotation")

        // A rotated page is re-laid-out; zooming must still work, and a zoom
        // must not survive into the next photo.
        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        let zoomed = probe(app)
        attach(app, text: "landscape zoomed: \(zoomed)")
        XCTAssertGreaterThan(value(zoomed, key: "scale"), 2, "Pinching broke after rotation: \(zoomed)")
        window.doubleTap()
        sleep(1)
        XCTAssertEqual(value(probe(app), key: "scale"), 1, accuracy: 0.05, "Double tap did not reset after rotation")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        attach(app, "portrait-again")
        XCTAssertEqual(page(app), before + 1, "Returning to portrait changed the photo")
        XCTAssertEqual(value(probe(app), key: "over"), 0, accuracy: 1, "Returning to portrait left the photo out of bounds")
        window.swipeLeft()
        sleep(1)
        XCTAssertEqual(page(app), before + 2, "Paging broke after rotating back")
    }

    /// VoiceOver users need to hear which photo of the roll they are on.
    func testPhotoExposesVoiceOverDescription() throws {
        let app = launch()
        _ = openFirstPhoto(app)
        let photo = app.images["viewer.photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "The photo is not an accessibility element")
        XCTAssertTrue(
            photo.label.hasPrefix("Photo 1 of "),
            "Unexpected VoiceOver label: \(photo.label)"
        )
        attach(app, text: "voiceover: \(photo.label), \(photo.value ?? "")")
    }

    /// Dragging on the chrome must not page or toggle the chrome.
    func testDragOnChromeDoesNotPage() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let before = page(app)

        drag(window, from: CGVector(dx: 0.5, dy: 0.11), to: CGVector(dx: 0.1, dy: 0.11), velocity: .slow)
        sleep(1)
        XCTAssertEqual(page(app), before, "A drag on the top bar paged the roll")
        XCTAssertTrue(app.buttons["Info"].exists, "A drag on the chrome toggled it")
    }

    /// A back-swipe that starts at the very leading edge must page the roll.
    /// The zoom navigation transition installs its own interactive-pop pan on
    /// the SwiftUI hosting view, which the navigation controller's public pop
    /// gestures do not cover; it only accepted touches in the first few points
    /// of the screen, so those swipes closed the viewer instead of paging.
    func testBackSwipeFromTheLeadingEdgePages() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        var report: [String] = []

        for dx in [0.05, 0.01, 0.003, 0.0] as [CGFloat] {
            window.swipeLeft()
            usleep(500_000)
            window.swipeLeft()
            usleep(900_000)
            let before = page(app)
            drag(
                window,
                from: CGVector(dx: dx, dy: 0.5),
                to: CGVector(dx: 0.62, dy: 0.5),
                velocity: .default
            )
            sleep(1)
            let open = app.otherElements["viewer.page"].exists
            report.append("dx=\(dx): open=\(open) \(before) → \(open ? String(page(app)) : "-")")
            XCTAssertTrue(open, "A swipe starting \(dx) across closed the viewer instead of paging")
            XCTAssertEqual(page(app), before - 1, "A swipe starting \(dx) across did not page back")
        }
        attach(app, text: "leading-edge swipes: " + report.joined(separator: " · "))
        attach(app, "leading-edge-swipe-paged")

        // Swipe-down must still dismiss: the leading-edge fix must not take the
        // zoom transition's dismissal with it.
        drag(
            window,
            from: CGVector(dx: 0.5, dy: 0.3),
            to: CGVector(dx: 0.5, dy: 0.9),
            velocity: .fast
        )
        sleep(1)
        XCTAssertFalse(app.otherElements["viewer.page"].exists, "Swipe-down no longer dismisses the viewer")
        XCTAssertTrue(
            app.buttons.matching(identifier: "library.tile").firstMatch.waitForExistence(timeout: 5),
            "The viewer closed without returning to the library"
        )
    }

    /// Tapping the chrome (close, favourite, info) must act on the photo and
    /// leave the chrome alone: only a tap on the photo toggles it.
    func testChromeButtonsDoNotToggleTheChrome() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5), "Chrome should start visible")
        let start = page(app)

        // The heart flips its own state, not the chrome's.
        let wasFavorite = app.buttons["Remove favorite"].exists
        app.buttons[wasFavorite ? "Remove favorite" : "Favorite"].tap()
        XCTAssertTrue(
            app.buttons[wasFavorite ? "Favorite" : "Remove favorite"].waitForExistence(timeout: 3),
            "Tapping the heart did not change the favourite state"
        )
        XCTAssertTrue(app.buttons["Info"].exists, "Tapping the heart toggled the chrome")
        XCTAssertEqual(page(app), start, "Tapping the heart paged the roll")
        // Put it back so the photo's state does not leak into later runs.
        app.buttons[wasFavorite ? "Favorite" : "Remove favorite"].tap()

        // Info opens the sheet; dismissing it leaves the chrome showing.
        app.buttons["Info"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), "Info did not open")
        attach(app, "info-sheet-over-viewer")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForNonExistence(timeout: 5), "The sheet did not close")
        XCTAssertTrue(app.buttons["Info"].exists, "Dismissing the sheet hid the chrome")
        XCTAssertEqual(page(app), start, "Opening and closing the sheet changed the photo")

        // After paging, the chrome still points at the photo on screen.
        window.swipeLeft()
        sleep(1)
        XCTAssertEqual(page(app), start + 1, "Paging failed")
        XCTAssertTrue(app.buttons["Info"].exists, "Paging hid the chrome")
        let favouriteAfterPaging = app.buttons["Remove favorite"].exists
        app.buttons[favouriteAfterPaging ? "Remove favorite" : "Favorite"].tap()
        XCTAssertTrue(
            app.buttons[favouriteAfterPaging ? "Favorite" : "Remove favorite"].waitForExistence(timeout: 3),
            "The heart did not act on the photo after paging"
        )
        XCTAssertEqual(page(app), start + 1, "Tapping the heart after paging paged the roll")
        app.buttons[favouriteAfterPaging ? "Favorite" : "Remove favorite"].tap()
        attach(app, "chrome-after-paging")

        app.buttons["Tag"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), "Tag did not open")
        app.buttons["Done"].tap()
        app.buttons["People"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), "People did not open")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 3))

        // And Close still closes from a paged viewer.
        app.buttons["Close"].tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "library.tile").firstMatch.waitForExistence(timeout: 8),
            "Close did not return to the library after paging"
        )
    }

    /// Chrome that the user hid must stay hidden while they page, and a tap on
    /// the photo must bring it back.
    func testChromeVisibilitySurvivesPaging() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))

        window.tap()
        XCTAssertTrue(app.buttons["Info"].waitForNonExistence(timeout: 3), "A tap did not hide the chrome")
        let before = page(app)
        window.swipeLeft()
        sleep(1)
        XCTAssertEqual(page(app), before + 1, "Paging failed with the chrome hidden")
        XCTAssertFalse(app.buttons["Info"].exists, "Paging brought the chrome back")
        window.tap()
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 3), "A tap on the photo did not restore the chrome")
        attach(app, "chrome-restored-after-paging")
    }

    /// Paging out of a zoomed photo must hand the gesture over at the edge in
    /// both directions, land exactly one photo, and leave the new photo at fit.
    func testPagingWhileZoomedHandsOffBothWays() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let start = page(app)

        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        XCTAssertGreaterThan(value(probe(app), key: "scale"), 2, "Pinch did not zoom")
        // Reach the right edge, then keep going: the pager takes over.
        drag(window, from: CGVector(dx: 0.9, dy: 0.5), to: CGVector(dx: 0.05, dy: 0.5), velocity: .slow)
        sleep(1)
        drag(window, from: CGVector(dx: 0.9, dy: 0.5), to: CGVector(dx: 0.1, dy: 0.5), velocity: .slow)
        sleep(1)
        XCTAssertEqual(page(app), start + 1, "Dragging past the right edge did not page forward")
        XCTAssertEqual(value(probe(app), key: "scale"), 1, accuracy: 0.02, "The photo arrived zoomed")

        // Back the other way: zoom, reach the left edge, continue.
        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        drag(window, from: CGVector(dx: 0.1, dy: 0.5), to: CGVector(dx: 0.95, dy: 0.5), velocity: .slow)
        sleep(1)
        XCTAssertEqual(page(app), start + 1, "Panning to the left edge paged by itself")
        drag(window, from: CGVector(dx: 0.12, dy: 0.5), to: CGVector(dx: 0.95, dy: 0.5), velocity: .slow)
        sleep(1)
        let landed = probe(app)
        attach(app, "zoomed-handoff-both-ways")
        attach(app, text: "after left hand-off: page \(page(app)) · \(landed)")
        XCTAssertEqual(page(app), start, "Dragging past the left edge did not page back")
        XCTAssertEqual(value(landed, key: "scale"), 1, accuracy: 0.02, "The photo arrived zoomed")
        XCTAssertEqual(value(landed, key: "over"), 0, accuracy: 1, "The photo arrived out of bounds")
    }

    /// A photo that has been on screen sharpens; a photo that is zoomed
    /// straight after arriving must sharpen too, instead of waiting out the
    /// deferral that protects flicking through the roll.
    func testZoomingSharpensThePhoto() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        sleep(2)
        XCTAssertEqual(value(probe(app), key: "sharp"), 1, "The photo never sharpened after a pause")

        window.swipeLeft()
        window.pinch(withScale: 3, velocity: 2)
        sleep(2)
        let state = probe(app)
        attach(app, "zoomed-after-arriving")
        attach(app, text: "zoomed immediately after paging: \(state)")
        XCTAssertGreaterThan(value(state, key: "scale"), 2, "The pinch did not zoom")
        XCTAssertEqual(value(state, key: "sharp"), 1, "A zoomed photo stayed soft: \(state)")
    }

    /// Opening and closing repeatedly must reuse the warm caches: the same
    /// photo, the same small page window, and no growth per cycle.
    func testReopeningKeepsPhotoAndMemory() throws {
        let app = launch()
        var memories: [Double] = []
        var setups: [Double] = []
        for round in 0..<4 {
            let tiles = app.buttons.matching(identifier: "library.tile")
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20))
            tiles.element(boundBy: 0).tap()
            XCTAssertTrue(app.otherElements["viewer.page"].waitForExistence(timeout: 10), "Round \(round) never opened")
            sleep(1)
            let state = probe(app)
            XCTAssertEqual(page(app), 1, "Round \(round) opened on a different photo")
            XCTAssertLessThanOrEqual(value(state, key: "live"), 5, "Round \(round) kept too many pages: \(state)")
            memories.append(value(state, key: "mem"))
            setups.append(value(state, key: "setup"))
            app.buttons["Close"].tap()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 8), "Round \(round) did not close")
            sleep(1)
        }
        attach(app, text: "open/close cycles: mem \(memories.map { String(format: "%.1f", $0) }) · setup \(setups)")
        XCTAssertLessThanOrEqual(
            memories[3] - memories[1], 25,
            "Reopening the viewer grew memory every time: \(memories)"
        )
        XCTAssertTrue(setups.allSatisfy { $0 <= 25 }, "Reopening built pages slowly: \(setups)")
    }

    /// Backgrounding and returning must leave the viewer usable, including the
    /// leading edge, which is owned by a recogniser that UIKit re-installs.
    func testBackgroundingKeepsTheViewerUsable() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        let before = page(app)

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.otherElements["viewer.page"].waitForExistence(timeout: 15), "The viewer closed in the background")
        attach(app, "after-foregrounding")
        XCTAssertEqual(page(app), before, "Foregrounding changed the photo")

        window.swipeLeft()
        sleep(1)
        XCTAssertEqual(page(app), before + 1, "Paging broke after foregrounding")

        drag(window, from: CGVector(dx: 0.002, dy: 0.5), to: CGVector(dx: 0.62, dy: 0.5), velocity: .default)
        sleep(1)
        XCTAssertTrue(app.otherElements["viewer.page"].exists, "A leading-edge swipe closed the viewer after foregrounding")
        XCTAssertEqual(page(app), before, "A leading-edge swipe did not page after foregrounding")
    }

    /// Photos also dismisses on a downward pull while a photo is magnified (the
    /// system zoom transition owns the vertical axis), so the requirement here
    /// is only that the gesture ends cleanly: either the photo pans, or the
    /// viewer closes back to the grid. It must never strand the roll.
    func testPullWhileZoomedEndsCleanly() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        window.pinch(withScale: 3, velocity: 2)
        sleep(1)
        attach(app, text: "before zoomed pull: \(probe(app))")

        drag(window, from: CGVector(dx: 0.5, dy: 0.35), to: CGVector(dx: 0.5, dy: 0.8), velocity: .slow)
        sleep(1)
        attach(app, "after zoomed pull")

        if app.otherElements["viewer.page"].exists {
            let state = probe(app)
            attach(app, text: "zoomed pull stayed open: \(state)")
            XCTAssertEqual(page(app), 1, "A zoomed pull changed the photo")
            XCTAssertGreaterThan(value(state, key: "scale"), 1.01, "A zoomed pull reset the zoom")
            XCTAssertLessThanOrEqual(value(state, key: "over"), 1, "A zoomed pull left the image bounds: \(state)")
        } else {
            XCTAssertTrue(
                app.buttons.matching(identifier: "library.tile").firstMatch.waitForExistence(timeout: 5),
                "The viewer closed without returning to the library"
            )
        }
    }

    private func value(_ state: String, key: String) -> Double {
        for part in state.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == Substring(key) else { continue }
            if key == "page" {
                return Double(pieces[1].split(separator: "/").first ?? "") ?? .nan
            }
            let number = pieces[1].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(number) ?? .nan
        }
        return .nan
    }
}
