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
            value(opened, key: "live"), 7,
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
                    value(last, key: "live"), 7,
                    "Resident page controllers grew while paging: \(last)"
                )
            }
            sleep(1)
            return last
        }

        let firstPass = swipeRoundTrip()
        attach(app, text: "first round trip: \(firstPass)")
        let secondPass = swipeRoundTrip()
        attach(app, "after two full-page round trips")
        attach(
            app,
            text: "second round trip: \(secondPass) · peak \(String(format: "%.1f", peak))MB"
        )
        // Two identical passes must not keep growing: the caches fill on the
        // first pass, and a leak would show up as a second identical step.
        XCTAssertFalse(
            value(secondPass, key: "mem").isNaN,
            "The probe did not report memory: \(secondPass)"
        )
        XCTAssertLessThanOrEqual(
            value(secondPass, key: "mem") - value(firstPass, key: "mem"), 20,
            "Paging the roll leaks memory: first \(firstPass), second \(secondPass)"
        )
        XCTAssertLessThanOrEqual(
            value(secondPass, key: "mem") - value(opened, key: "mem"), 140,
            "Paging the roll grows memory past the cache budget: open \(opened), settled \(secondPass)"
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
        XCTAssertLessThanOrEqual(
            value(state, key: "drops"), 10,
            "Flicking through ten photos dropped frames: \(state)"
        )
        XCTAssertLessThanOrEqual(
            value(state, key: "live"), 7,
            "Flicking through ten photos grew the page window: \(state)"
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

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        attach(app, "portrait-again")
        XCTAssertEqual(page(app), before + 1, "Returning to portrait changed the photo")
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

    /// A back-swipe that starts near the leading edge must page the roll. (The
    /// system reserves the first few points of the screen for its own back
    /// gesture; this starts just inside that strip.)
    func testBackSwipeNearScreenEdgePages() throws {
        let app = launch()
        let window = openFirstPhoto(app)
        window.swipeLeft()
        window.swipeLeft()
        sleep(1)
        let before = page(app)

        let beforeState = probe(app)
        drag(window, from: CGVector(dx: 0.05, dy: 0.5), to: CGVector(dx: 0.65, dy: 0.5), velocity: .default)
        sleep(1)
        attach(app, "edge-swipe-back")
        attach(app, text: "before edge swipe: \(beforeState) · after: page \(page(app))")
        XCTAssertTrue(app.otherElements["viewer.page"].exists, "An edge swipe dismissed the viewer")
        XCTAssertEqual(page(app), before - 1, "An edge swipe did not page back")
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
