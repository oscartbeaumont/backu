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

    func testViewerGestures() throws {
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
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No tiles")
        attach(app, "viewer-01-library")

        tiles.element(boundBy: 0).tap()
        // The viewer paints immediately from the cached thumbnail.
        sleep(2)
        attach(app, "viewer-02-open")

        let window = app.windows.firstMatch
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

        for _ in 0..<3 {
            window.swipeRight()
        }
        sleep(1)
        attach(app, "viewer-05-paged-back")

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

        // Drag down most of the way without dismissing, then let go.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        attach(app, "viewer-09-pull-released")

        // And finally dismiss with a full pull.
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)), withVelocity: .default, thenHoldForDuration: 0.05)
        sleep(1)
        attach(app, "viewer-10-dismissed")
    }
}
