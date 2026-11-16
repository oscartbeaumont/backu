import XCTest

final class TransferTuningTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024

    private func plan(
        size: Int64,
        direction: TransferDirection = .upload,
        network: NetworkKind = .wifi,
        throughput: Double? = nil,
        measuredConcurrency: Int? = nil,
        latency: TimeInterval? = nil,
        cap: Int? = nil
    ) -> TransferPlan {
        TransferPlanner.plan(
            TransferPlanner.Input(
                size: size,
                direction: direction,
                network: NetworkSnapshot(kind: network, hasPath: true),
                throughput: throughput,
                measuredConcurrency: measuredConcurrency,
                latency: latency,
                minimumLatencyForParallel: 0.008,
                concurrencyCap: cap
            )
        )
    }

    // MARK: - Part sizes and concurrency

    func testThirtyTwoMiBBecomesSixPartsOnWiFi() {
        let plan = self.plan(size: 32 * mib)
        XCTAssertEqual(plan.concurrency, 6)
        XCTAssertEqual(plan.partCount, 6, plan.reason)
        XCTAssertGreaterThanOrEqual(plan.partSize, 5 * mib)
        XCTAssertLessThanOrEqual(plan.partSize, 6 * mib)
        XCTAssertTrue(plan.parallel)
    }

    func testLargeFileUsesEightConnectionsAndHistorySizedParts() {
        // 45 MB/s aggregate over 6 connections is 7.5 MB/s each, so an 8 s
        // target wants ~60 MB parts; the "at least eight parts" rule caps it at
        // 16 MiB for a 128 MiB object.
        let plan = self.plan(
            size: 128 * mib,
            throughput: 45_000_000,
            measuredConcurrency: 6
        )
        XCTAssertEqual(plan.concurrency, 8)
        XCTAssertEqual(plan.partCount, 8)
        XCTAssertEqual(plan.partSize, 16 * mib)
        XCTAssertNotNil(plan.estimatedBytesPerSecond)
    }

    func testPartSizeClampKeepsFiveToSixtyFourMiB() {
        let slow = self.plan(
            size: 1024 * mib,
            throughput: 200_000,
            measuredConcurrency: 1
        )
        XCTAssertGreaterThanOrEqual(slow.partSize, 5 * mib)

        let fast = self.plan(
            size: 4096 * mib,
            throughput: 2_000_000_000,
            measuredConcurrency: 8
        )
        XCTAssertLessThanOrEqual(fast.partSize, 64 * mib)
        XCTAssertGreaterThan(fast.partSize, 32 * mib)
    }

    func testCellularAndConstrainedStayConservative() {
        let cellular = self.plan(size: 128 * mib, network: .cellular)
        XCTAssertEqual(cellular.concurrency, 4)
        XCTAssertGreaterThanOrEqual(cellular.partCount, 4)

        let constrained = self.plan(size: 128 * mib, network: .constrained)
        XCTAssertEqual(constrained.concurrency, 2)

        let expensive = self.plan(size: 128 * mib, network: .expensive)
        XCTAssertEqual(expensive.concurrency, 3)
    }

    func testCallerConcurrencyCapIsHonoured() {
        let plan = self.plan(size: 128 * mib, cap: 2)
        XCTAssertEqual(plan.concurrency, 2)
        // Without history the 8 MiB default target wins over one huge part per
        // connection, so a slow link never gets a minute-long part.
        XCTAssertEqual(plan.partSize, 8 * mib)
        XCTAssertEqual(plan.partCount, 16)
    }

    func testPartCountNeverExceedsTenThousand() {
        let size: Int64 = 20 * 1024 * 1024 * mib // 20 TiB
        let plan = self.plan(size: size)
        XCTAssertLessThanOrEqual(plan.partCount, TransferPlanner.maximumParts)
        XCTAssertGreaterThan(plan.partSize, 64 * mib, "the cap has to win over the normal ceiling")
    }

    func testSmallObjectStaysSingleStream() {
        let upload = self.plan(size: 4 * mib)
        XCTAssertEqual(upload.concurrency, 1)
        XCTAssertFalse(upload.parallel)
        XCTAssertEqual(upload.partCount, 1)

        let download = self.plan(size: 4 * mib, direction: .download, latency: 0.03)
        XCTAssertEqual(download.concurrency, 1)
        XCTAssertFalse(download.parallel)
    }

    // MARK: - Download gating

    func testDownloadParallelisesOnlyOnRealLatency() {
        let highLatency = self.plan(size: 32 * mib, direction: .download, latency: 0.025)
        XCTAssertTrue(highLatency.parallel)
        XCTAssertGreaterThanOrEqual(highLatency.concurrency, 2)

        let loopback = self.plan(size: 128 * mib, direction: .download, latency: 0.001)
        XCTAssertFalse(loopback.parallel)
        XCTAssertEqual(loopback.concurrency, 1)

        let justUnderThreshold = self.plan(size: 4 * mib, direction: .download, latency: 0.05)
        XCTAssertFalse(justUnderThreshold.parallel)

        let eightMiB = self.plan(size: 8 * mib, direction: .download, latency: 0.05)
        XCTAssertTrue(eightMiB.parallel)
        XCTAssertEqual(eightMiB.partCount, 6)
    }

    func testDownloadWithoutProbeNeverGuessesParallelism() {
        let unknownLatency = self.plan(size: 128 * mib, direction: .download, latency: nil)
        XCTAssertFalse(unknownLatency.parallel)
    }

    // MARK: - History and persistence

    func testRecordedThroughputShapesTheNextPlan() throws {
        let store = TransferTuningStore(persistence: .memory)
        let tuning = TransferTuning(store: store, networkProvider: { NetworkSnapshot(kind: .wifi, hasPath: true) })
        let key = "example.test/bucket"

        let first = tuning.plan(serverKey: key, direction: .upload, size: 32 * mib)
        XCTAssertNil(first.estimatedBytesPerSecond)
        tuning.record(
            serverKey: key,
            direction: .upload,
            bytes: 32 * mib,
            seconds: 1,
            plan: first
        )

        let second = tuning.plan(serverKey: key, direction: .upload, size: 256 * mib)
        let estimate = try XCTUnwrap(second.estimatedBytesPerSecond)
        XCTAssertEqual(estimate, 32 * 1024 * 1024, accuracy: 1)
        XCTAssertGreaterThan(second.partSize, first.partSize)
    }

    func testNetworkTypeChangeResetsThroughputHistory() {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value: NetworkSnapshot
            init(_ value: NetworkSnapshot) { self.value = value }
            var snapshot: NetworkSnapshot {
                get { lock.lock(); defer { lock.unlock() }; return value }
                set { lock.lock(); value = newValue; lock.unlock() }
            }
        }

        let box = Box(NetworkSnapshot(kind: .wifi, hasPath: true))
        let tuning = TransferTuning(
            store: TransferTuningStore(persistence: .memory),
            networkProvider: { box.snapshot }
        )
        let key = "example.test/bucket"
        let plan = tuning.plan(serverKey: key, direction: .download, size: 32 * mib, latency: 0.03)
        tuning.record(serverKey: key, direction: .download, bytes: 32 * mib, seconds: 1, plan: plan)
        XCTAssertNotNil(
            tuning.plan(serverKey: key, direction: .download, size: 32 * mib, latency: 0.03)
                .estimatedBytesPerSecond
        )

        box.snapshot = NetworkSnapshot(kind: .cellular, isExpensive: true, hasPath: true)
        let after = tuning.plan(serverKey: key, direction: .download, size: 32 * mib, latency: 0.03)
        XCTAssertNil(after.estimatedBytesPerSecond)
        XCTAssertEqual(after.concurrency, 4)
    }

    func testUserDefaultsPersistenceRoundTrips() throws {
        let suiteName = "backu.tests.transfer.tuning.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "persisted.test/bucket"
        let state = TransferTuningState(
            network: .wifi,
            upload: TransferSample(throughput: 12_000_000, concurrency: 6),
            download: nil
        )

        let writer = TransferTuningStore(persistence: .userDefaults(defaults, key: "state"))
        writer.setState(state, for: key)
        writer.flushPersistence()

        let reader = TransferTuningStore(persistence: .userDefaults(defaults, key: "state"))
        XCTAssertEqual(reader.state(for: key), state)
    }

    func testTuningKeysAreStableAndServerScoped() {
        let first = S3Connection(
            endpoint: URL(string: "https://s3.example.test")!,
            region: "us-east-1",
            bucket: "photos",
            pathStyle: false
        )
        let same = S3Connection(
            endpoint: URL(string: "https://s3.example.test/")!,
            region: "eu-west-1",
            bucket: "photos",
            pathStyle: true
        )
        let other = S3Connection(
            endpoint: URL(string: "https://s3.example.test")!,
            region: "us-east-1",
            bucket: "archive",
            pathStyle: false
        )
        XCTAssertEqual(first.transferTuningKey, same.transferTuningKey)
        XCTAssertNotEqual(first.transferTuningKey, other.transferTuningKey)
    }

    func testCeilDiv() {
        XCTAssertEqual(TransferPlanner.ceilDiv(10, 3), 4)
        XCTAssertEqual(TransferPlanner.ceilDiv(9, 3), 3)
        XCTAssertEqual(TransferPlanner.ceilDiv(0, 3), 0)
        XCTAssertEqual(TransferPlanner.ceilDiv(1, 3), 1)
    }
}
