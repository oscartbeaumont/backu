import XCTest

final class AuditAppUIRegressionTests: XCTestCase {
    private var changedFavorite = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDetailsContextMenuKeepsActiveFilterViewerWindow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = """
        {
          "servers": [{
            "name": "Refused Local Fixture",
            "provider": "custom",
            "endpoint": "http://127.0.0.1:9",
            "region": "us-east-1",
            "bucket": "audit-filter",
            "accessKeyID": "audit",
            "secretAccessKey": "audit",
            "pathStyle": true,
            "prefix": "Backu"
          }],
          "settings": {
            "autoBackupEnabled": false,
            "backupOnCellular": false,
            "faceRecognitionEnabled": false,
            "gridColumns": 3,
            "hasCompletedOnboarding": true,
            "showRemoteOnlyPhotos": true
          }
        }
        """
        app.launch()

        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "No simulator fixture tiles")

        addTeardownBlock {
            if app.navigationBars["Details"].exists, app.buttons["Done"].exists {
                app.buttons["Done"].tap()
            }
            if self.changedFavorite, app.buttons["Remove favorite"].exists {
                app.buttons["Remove favorite"].tap()
                self.changedFavorite = false
            }
            if app.buttons["Close"].exists {
                app.buttons["Close"].tap()
            }
            if app.buttons["filter.done"].exists {
                app.buttons["filter.done"].tap()
            }
            if app.buttons["library.filter"].exists {
                app.buttons["library.filter"].tap()
                if app.buttons["filter.option.all-items"].exists {
                    app.buttons["filter.option.all-items"].tap()
                }
                if app.buttons["filter.done"].exists {
                    app.buttons["filter.done"].tap()
                }
            }
            if self.changedFavorite, tiles.firstMatch.waitForExistence(timeout: 5) {
                tiles.firstMatch.tap()
                if app.buttons["Close"].waitForExistence(timeout: 5) {
                    let remove = app.buttons["Remove favorite"]
                    if remove.exists { remove.tap() }
                    app.buttons["Close"].tap()
                }
            }
        }

        // Guarantee one matching item without depending on the simulator's
        // existing favourites. The teardown restores the original state.
        tiles.firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        if app.buttons["Favorite"].exists {
            app.buttons["Favorite"].tap()
            changedFavorite = true
        }
        app.buttons["Close"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))

        app.buttons["library.filter"].tap()
        XCTAssertTrue(app.buttons["filter.option.favourites"].waitForExistence(timeout: 5))
        app.buttons["filter.option.favourites"].tap()
        app.buttons["filter.done"].tap()
        XCTAssertTrue(app.buttons["filter.done"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))

        // The ordinary tile path defines the correct window: the active
        // Favourites filter. Capture it instead of assuming fixture counts.
        tiles.firstMatch.tap()
        XCTAssertTrue(app.otherElements["viewer.page"].waitForExistence(timeout: 10))
        let filteredPage = pageValue(app)
        app.buttons["Close"].tap()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))

        // Details is a second entry point to the same viewer and must retain
        // that filtered window rather than silently using the whole catalog.
        tiles.firstMatch.press(forDuration: 1)
        let details = app.buttons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), "Tile context menu missing Details")
        details.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 8), "Details sheet missing")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["viewer.page"].waitForExistence(timeout: 10))
        let contextMenuPage = pageValue(app)

        XCTAssertEqual(
            contextMenuPage,
            filteredPage,
            "Details opened the unfiltered catalog instead of preserving the active filter window"
        )
    }

    private func pageValue(_ app: XCUIApplication) -> String {
        let page = app.otherElements["viewer.page"]
        _ = page.waitForExistence(timeout: 5)
        return page.value as? String ?? "missing"
    }
}
