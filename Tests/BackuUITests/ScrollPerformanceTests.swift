import XCTest

/// Scroll benchmark for the 300-photo synthetic library.
///
/// This test is not part of normal CI: it skips unless `BACKU_PERF=1` reaches the
/// test runner (`TEST_RUNNER_BACKU_PERF=1`), and it expects the dedicated "Backu Perf" simulator prepared by
/// `Tools/Performance/setup.sh` (300 photos, Photos already granted).
///
///   TEST_RUNNER_BACKU_PERF=1 xcodebuild -project Backu.xcodeproj -scheme Backu \
///     -destination 'platform=iOS Simulator,name=Backu Perf' \
///     -only-testing:BackuUITests/ScrollPerformanceTests/testScrollPerformance \
///     -resultBundlePath /private/tmp/backu-perf test
final class ScrollPerformanceTests: XCTestCase {
    private let firstScreenTiles = 9

    private var bootstrap: String {
        // A refused endpoint keeps the "has a server" bootstrap path (so the
        // onboarding screen stays out of the way) without any real traffic.
        // Face analysis and automatic backup are off so the measurement is
        // only about the grid and thumbnails.
        """
        {"servers":[{"name":"Perf","provider":"custom","endpoint":"http://127.0.0.1:9","region":"us-east-1","bucket":"perf","accessKeyID":"perf","secretAccessKey":"perf","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":false,"faceRecognitionEnabled":false,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":true}}
        """
    }

    /// Automatic backup on against the refused endpoint: the failure banner is
    /// guaranteed to appear, which is what the banner-layout regression needs.
    private var bannerBootstrap: String {
        """
        {"servers":[{"name":"Perf","provider":"custom","endpoint":"http://127.0.0.1:9","region":"us-east-1","bucket":"perf","accessKeyID":"perf","secretAccessKey":"perf","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":true,"backupOnCellular":false,"faceRecognitionEnabled":false,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":true}}
        """
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BACKU_PERF"] == "1",
            "Run Tools/Performance/setup.sh and pass TEST_RUNNER_BACKU_PERF=1 to measure scrolling."
        )
    }

    func testScrollPerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launchEnvironment["BACKU_PROBE"] = "1"

        let launchStarted = Date()
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 2) { springboardAllow.tap() }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 30), "Library never appeared")
        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "No photo tiles rendered")
        let firstTileDelay = Date().timeIntervalSince(launchStarted)

        // First screen: how long until the visible rows are actually decoded.
        let timeToFirstScreen = waitForReadyTiles(app, count: firstScreenTiles, timeout: 20)
        let timeToTwoScreens = waitForReadyTiles(app, count: firstScreenTiles * 3, timeout: 20)
        let coldLoading = loadingTiles(app).loading
        let launchText = String(format: "%.2f", firstTileDelay)
        let firstText = String(format: "%.2f", timeToFirstScreen)
        let twoText = String(format: "%.2f", timeToTwoScreens)
        let coldProbe = probe(app).map { "probe \($0)" } ?? "probe unavailable"
        record("cold launch: \(launchText)s to first tile, +\(firstText)s to \(firstScreenTiles) ready, +\(twoText)s to \(firstScreenTiles * 3) ready, \(coldLoading) still loading · \(coldProbe)")
        attach(app, "perf-01-cold")

        // Several fast flings. Sampling starts immediately after the last drag
        // is lifted, so the first sample catches the tiles still streaming in.
        settleToTop(app)
        sleep(1)
        let transient = fling(app, times: 3, captureSteps: true)
        let flingProbe = probe(app).map { "probe \($0)" } ?? "probe unavailable"
        sleep(2)
        let settled = loadingTiles(app)
        let settledProbe = probe(app).map { "probe \($0)" } ?? "probe unavailable"
        attach(app, "perf-02-settled")
        record("fast fling: peak \(transient.peak) loading, after settling \(settled.loading) of \(settled.visible) visible")
        record("fast fling probe: \(flingProbe) · settled \(settledProbe)")
        record("fling frames: \(transient.frames)")

        // Warm second screen: time-to-ready after the fling, when the prefetch
        // window has had a chance to help.
        settleToTop(app)
        sleep(1)
        _ = fling(app, times: 3)
        let warmStart = Date()
        let warmReady = waitForReadyTiles(app, count: firstScreenTiles, timeout: 12)
        let warmDuration = Date().timeIntervalSince(warmStart)
        record("warm screen: \(String(format: "%.2f", warmDuration))s to \(firstScreenTiles) ready (poll resolution \(String(format: "%.2f", warmReady))s)")

        // The scored part: scroll deceleration + wall clock + peak memory.
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollDecelerationMetric,
                XCTClockMetric(),
                XCTMemoryMetric()
            ],
            options: options
        ) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
        }

        record("scroll metric above; last settled placeholders \(loadingTiles(app).loading)")
        record("measure frames: \(frames(app))")
    }

    /// A banner is a full-width row above the grid. It used to be laid out as
    /// a grid cell that did not span, so its text was compressed into one
    /// column and overlapped the status bar. This also re-checks the prefetch
    /// probe with the banner's extra header height in the row math.
    func testFlingWithBackupBanner() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bannerBootstrap
        app.launchEnvironment["BACKU_PROBE"] = "1"
        app.launch()

        let allow = app.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons["Allow Full Access"]
        if springboardAllow.waitForExistence(timeout: 2) { springboardAllow.tap() }

        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 30), "Library never appeared")
        let banner = app.descendants(matching: .any)
            .matching(identifier: "library.backupBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "Backup failure banner never appeared")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(banner.frame.width, window.width * 0.8, "Banner is compressed: \(banner.frame)")
        XCTAssertGreaterThanOrEqual(banner.frame.minX, window.minX - 0.5, "Banner starts left of the screen")
        XCTAssertLessThanOrEqual(banner.frame.maxX, window.maxX + 0.5, "Banner runs past the screen")

        let tiles = app.buttons.matching(identifier: "library.tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "No photo tiles rendered")
        XCTAssertGreaterThanOrEqual(
            tiles.firstMatch.frame.minY, banner.frame.maxY - 0.5,
            "The first photo row overlaps the banner"
        )
        attach(app, "perf-banner-01-all")

        // Wait for the initial screen, then let the cold-start blanks age out
        // of the probe's trailing three-second window before flinging. This is
        // also the check that the peak genuinely decays with no tile changes
        // (small libraries realize no new tiles during a fling).
        _ = waitForReadyTiles(app, count: firstScreenTiles, timeout: 20)
        settleToTop(app)
        sleep(3)
        let idle = probe(app)
        record("banner idle probe: \(idle.map { "\($0)" } ?? "unavailable")")
        XCTAssertGreaterThan(idle?.visible ?? 0, 0, "The idle probe saw no realized tiles, so peak 0 is meaningless")
        XCTAssertEqual(idle?.now ?? -1, 0, "Tiles are still blank while idle")
        XCTAssertEqual(idle?.peak ?? -1, 0, "The 3 s blank peak did not decay while idle")
        let sample = fling(app, times: 3)
        let result = probe(app)
        attach(app, "perf-banner-02-after-fling")
        record("banner fling: peak \(sample.peak) loading, after \(sample.loading) of \(sample.visible) · probe \(result.map { "\($0)" } ?? "unavailable")")
        XCTAssertGreaterThan(result?.visible ?? 0, 0, "The post-fling probe saw no realized tiles")
        XCTAssertEqual(result?.now ?? -1, 0, "Tiles are blank after the fling")
        XCTAssertEqual(result?.peak ?? -1, 0, "Blank tiles during a fling with a banner")
    }

    // MARK: - Helpers

    private struct Probe: CustomStringConvertible {
        var now = 0
        var peak = 0
        var finalNow = 0
        var finalPeak = 0
        var visible = 0
        var coldPeak = 0
        var coldFinalPeak = 0

        var description: String {
            "blank \(now) (peak3s \(peak)), final \(finalNow) (peak3s \(finalPeak)), realised \(visible), coldPeak \(coldPeak)/\(coldFinalPeak)"
        }
    }

    private func probe(_ app: XCUIApplication) -> Probe? {
        let element = app.descendants(matching: .any).matching(identifier: "perf.probe").firstMatch
        guard element.exists, let raw = element.value as? String else { return nil }
        var result = Probe()
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=")
            guard pair.count == 2, let value = Int(pair[1]) else { continue }
            switch pair[0] {
            case "now": result.now = value
            case "peak": result.peak = value
            case "finalNow": result.finalNow = value
            case "finalPeak": result.finalPeak = value
            case "visible": result.visible = value
            case "coldPeak": result.coldPeak = value
            case "coldFinalPeak": result.coldFinalPeak = value
            default: break
            }
        }
        return result
    }

    private struct TileSample {
        var loading = 0
        var visible = 0
        var peak = 0
        var frames = FrameSample()
    }

    private struct FrameSample: CustomStringConvertible {
        var frames = 0
        var dropped = 0
        var worst = 0.0
        var average = 0.0

        var description: String {
            String(
                format: "frames=%d, dropped=%d, worst=%.1fms, avg=%.1fms",
                frames, dropped, worst, average
            )
        }
    }

    /// Reads the in-app `CADisplayLink` probe. The window is the trailing two
    /// seconds, so call it right after the fling.
    private func frames(_ app: XCUIApplication) -> FrameSample {
        let element = app.descendants(matching: .any).matching(identifier: "perf.frames").firstMatch
        guard element.exists, let raw = element.value as? String else { return FrameSample() }
        var sample = FrameSample()
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=")
            guard pair.count == 2, let value = Double(pair[1]) else { continue }
            switch pair[0] {
            case "frames": sample.frames = Int(value)
            case "dropped": sample.dropped = Int(value)
            case "worst": sample.worst = value
            case "avg": sample.average = value
            default: break
            }
        }
        return sample
    }

    private func loadingTiles(_ app: XCUIApplication) -> TileSample {
        let all = app.buttons.matching(identifier: "library.tile")
        let screen = app.windows.firstMatch.frame
        var sample = TileSample()
        let examined = min(all.count, 48)
        for index in 0..<examined {
            let element = all.element(boundBy: index)
            guard element.exists else { continue }
            let frame = element.frame
            guard frame.intersects(screen), frame.width > 0 else { continue }
            sample.visible += 1
            if (element.value as? String) == "Loading" { sample.loading += 1 }
        }
        return sample
    }

    /// Polls until the first `count` realized tiles report Ready.
    @discardableResult
    private func waitForReadyTiles(_ app: XCUIApplication, count: Int, timeout: TimeInterval) -> TimeInterval {
        let started = Date()
        let tiles = app.buttons.matching(identifier: "library.tile")
        while Date().timeIntervalSince(started) < timeout {
            var ready = 0
            for index in 0..<count {
                let element = tiles.element(boundBy: index)
                guard element.exists else { break }
                if (element.value as? String) == "Ready" { ready += 1 }
            }
            if ready >= count { return Date().timeIntervalSince(started) }
            usleep(80_000)
        }
        return Date().timeIntervalSince(started)
    }

    /// Fast flings with no idle wait between them. Returns the peak number of
    /// visible tiles that were still loading during/after the flings.
    @discardableResult
    private func fling(_ app: XCUIApplication, times: Int, captureSteps: Bool = false) -> TileSample {
        var peak = 0
        for step in 0..<times {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            // Sample before taking a screenshot: the screenshot is a UI query
            // and would widen the gap to the next sample, biasing the peak
            // downward. These attachments are post-lift, not mid-drag.
            peak = max(peak, loadingTiles(app).loading)
            if captureSteps { attach(app, "perf-02b-post-fling-step-\(step)") }
        }
        let deadline = Date().addingTimeInterval(1.2)
        let flingFrames = frames(app)
        while Date() < deadline {
            peak = max(peak, loadingTiles(app).loading)
            usleep(60_000)
        }
        var sample = loadingTiles(app)
        sample.peak = peak
        sample.frames = flingFrames
        return sample
    }

    private func settleToTop(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        for _ in 0..<8 {
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
    }

    private func record(_ text: String) {
        print("PERF · \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "perf-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
