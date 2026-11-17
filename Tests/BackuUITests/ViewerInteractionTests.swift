import XCTest

/// Drives the full-screen viewer the way a person does: paging, zooming,
/// panning and the swipe-down dismissal. Also captures the feel of each step so
/// gesture regressions are visible in the result bundle.
final class ViewerInteractionTests: XCTestCase {
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
        XCTAssertTrue(app.buttons["Info"].exists, "A double tap also toggled chrome")
        XCTAssertTrue(zoomed.contains("scale=2.5"), "Double tap did not zoom to 2.5x: \(zoomed)")
        let centerX = value(zoomed, key: "cx")
        XCTAssertEqual(centerX, 0.78, accuracy: 0.09, "Zoom did not anchor toward the tapped point: \(zoomed)")

        // The same gesture at a different point, while zoomed, resets to fit.
        doubleTap(window, dx: 0.3, dy: 0.7)
        sleep(1)
        let reset = probe(app)
        attach(app, "double-tap-reset-zoomed")
        attach(app, text: "after reset: \(reset)")
        XCTAssertEqual(value(reset, key: "scale"), 1, accuracy: 0.02, "Double tap did not reset: \(reset)")
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

    private func value(_ state: String, key: String) -> Double {
        for part in state.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == Substring(key) else { continue }
            if key == "page" {
                return Double(pieces[1].split(separator: "/").first ?? "") ?? .nan
            }
            return Double(pieces[1]) ?? .nan
        }
        return .nan
    }
}
