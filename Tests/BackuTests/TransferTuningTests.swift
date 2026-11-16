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
        cap: Int? = nil,
        ceiling: Int = TransferPlanner.unmeasuredConcurrencyCeiling,
        penalty: Int = 0,
        memoryBudget: Int64 = TransferPlanner.memoryBudget()
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
                concurrencyCap: cap,
                concurrencyCeiling: ceiling,
                concurrencyPenalty: penalty,
                memoryBudget: memoryBudget
            )
        )
    }

    // MARK: - Part sizes and concurrency

    func testThirtyTwoMiBUploadUsesSevenPartsWithASmallTail() {
        // 32 MiB cannot be split into more useful lanes: S3 requires every part
        // except the last to be >= 5 MiB, so 6 x 5 MiB + 1 x 2 MiB is the
        // maximum. The old floor-based "feedable" count capped this at six.
        let plan = self.plan(size: 32 * mib)
        XCTAssertEqual(plan.concurrency, 7, plan.reason)
        XCTAssertEqual(plan.partCount, 7, plan.reason)
        XCTAssertEqual(plan.partSize, 5 * mib, plan.reason)
        XCTAssertTrue(plan.parallel)
        let tail = 32 * mib - 6 * 5 * mib
        XCTAssertEqual(tail, 2 * mib)
    }

    func testOnlyTheLastUploadPartMayBeBelowFiveMiB() {
        // Sweep awkward sizes, including ones just under a 5 MiB boundary, and
        // assert the invariant the server enforces.
        for mebibytes in [16, 17, 21, 26, 31, 32, 33, 37, 41, 64, 100] {
            let size = Int64(mebibytes) * mib
            let plan = self.plan(size: size)
            XCTAssertLessThanOrEqual(plan.partCount, 10_000)
            XCTAssertGreaterThanOrEqual(plan.concurrency, 1)
            for part in 1...max(1, plan.partCount) where part < plan.partCount {
                XCTAssertGreaterThanOrEqual(
                    plan.partSize,
                    TransferPlanner.minimumUploadPartSize,
                    "\(mebibytes) MiB: non-final part \(part) would be under 5 MiB"
                )
            }
            XCTAssertEqual(
                Int(TransferPlanner.ceilDiv(size, plan.partSize)),
                plan.partCount,
                "\(mebibytes) MiB: partCount does not match partSize"
            )
        }
    }

    func testFirstLargeTransferStaysAtEightConnections() {
        // No history: 128 MiB plans the pass-2 ceiling of 8, so the very first
        // transfer after install is never more aggressive than before.
        let plan = self.plan(size: 128 * mib)
        XCTAssertEqual(plan.concurrency, 8, plan.reason)
        // 16 x 8 MiB is two balanced waves at eight connections. Eight in-memory
        // bodies would peak near 128 MiB once URLSession copies them, so a
        // first transfer stages instead.
        XCTAssertEqual(plan.partCount, 16, plan.reason)
        XCTAssertTrue(plan.stagesParts)
    }

    func testProvenScalingUnlocksTenConnections() {
        // A transfer at eight connections that kept per-connection throughput at
        // the best ever seen is evidence the link still scales.
        let plan = self.plan(
            size: 128 * mib,
            throughput: 54_000_000,
            measuredConcurrency: 8,
            ceiling: TransferPlanner.connectionBudget
        )
        XCTAssertEqual(plan.concurrency, 10, plan.reason)
        XCTAssertEqual(plan.partCount, 10, plan.reason)
        XCTAssertEqual(plan.partSize, 13_421_773, plan.reason) // 128 MiB / 10
    }

    func testDownloadRangesFillEightAndThenTenConnections() {
        let thirtyTwo = self.plan(size: 32 * mib, direction: .download, latency: 0.03)
        XCTAssertEqual(thirtyTwo.concurrency, 8, thirtyTwo.reason)
        XCTAssertEqual(thirtyTwo.partCount, 8, thirtyTwo.reason)
        XCTAssertEqual(thirtyTwo.partSize, 4 * mib, thirtyTwo.reason)

        let large = self.plan(
            size: 128 * mib,
            direction: .download,
            throughput: 55_000_000,
            measuredConcurrency: 8,
            latency: 0.03,
            ceiling: TransferPlanner.connectionBudget
        )
        XCTAssertEqual(large.concurrency, 10, large.reason)
        XCTAssertEqual(large.partCount, 10, large.reason)
    }

    func testNonDivisibleRandomSizesStayExact() {
        for size in [8 * mib + 1, 8 * mib + 12345, 33 * mib + 7, 128 * mib - 3] {
            let download = self.plan(size: size, direction: .download, latency: 0.05)
            var covered: Int64 = 0
            let base = size / Int64(max(1, download.partCount))
            for index in 0..<download.partCount {
                let start = Int64(index) * base
                let end = index == download.partCount - 1 ? size - 1 : start + base - 1
                XCTAssertEqual(end - start + 1, index == download.partCount - 1 ? size - start : base)
                covered += end - start + 1
            }
            XCTAssertEqual(covered, size, "ranges must cover the object exactly")
        }
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
        // A metered radio never inherits the wired/Wi-Fi fan-out, even when the
        // object could feed more lanes or the history is wide.
        let cellular = self.plan(
            size: 32 * mib,
            network: .cellular,
            throughput: 54_000_000,
            measuredConcurrency: 8,
            ceiling: TransferPlanner.connectionBudget
        )
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

    // MARK: - Payload budget

    func testLargeInMemoryUploadStagesPartsInsteadOfCollapsingThePlan() {
        // 10 x 12.8 MiB would be 128 MiB of live part payload; the 96 MiB budget
        // moves it to disk and keeps every connection.
        let plan = self.plan(
            size: 128 * mib,
            throughput: 54_000_000,
            measuredConcurrency: 8,
            ceiling: TransferPlanner.connectionBudget
        )
        XCTAssertEqual(plan.concurrency, 10, plan.reason)
        XCTAssertTrue(plan.stagesParts, plan.reason)
        XCTAssertGreaterThan(
            Int64(plan.concurrency) * plan.partSize,
            TransferPlanner.memoryBudget()
        )
        XCTAssertTrue(plan.reason.contains("staged"))
    }

    func testPlannerHonoursAnExplicitMemoryBudget() {
        // A small budget must change behaviour, not just the reason string.
        let tight = self.plan(size: 128 * mib, memoryBudget: 32 * mib)
        XCTAssertTrue(tight.stagesParts)
        XCTAssertLessThanOrEqual(tight.partSize, 64 * mib)

        let roomy = self.plan(size: 128 * mib, memoryBudget: 512 * mib)
        XCTAssertFalse(roomy.stagesParts)
    }

    func testMemoryBudgetTracksPhysicalMemory() {
        XCTAssertEqual(
            TransferPlanner.memoryBudget(physicalMemory: 1_000_000_000_000 as UInt64),
            96 * mib,
            "the hard ceiling must win on a big machine"
        )
        XCTAssertEqual(
            TransferPlanner.memoryBudget(physicalMemory: UInt64(1024 * mib)),
            64 * mib,
            "RAM/16 when that is smaller than the hard ceiling"
        )
        XCTAssertEqual(TransferPlanner.memoryBudget(physicalMemory: 0), 8 * mib)
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
        XCTAssertEqual(eightMiB.partCount, 2)
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

    func testWideFastTransferGrowsThePlanAndASlowOneDoesNot() {
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

        // A first 128 MiB transfer plans eight connections.
        let first = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(first.concurrency, 8)
        XCTAssertTrue(first.stagesParts)

        // 54 MB/s at eight connections is 6.75 MB/s per connection: still
        // scaling, so the next plan uses ten.
        tuning.record(serverKey: key, direction: .upload, bytes: 128 * mib, seconds: 2.37, plan: first)
        let second = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(second.concurrency, 10, second.reason)
        XCTAssertTrue(second.stagesParts, second.reason)

        // Now ten connections deliver less aggregate throughput than eight did
        // (54 MB/s vs 60 MB/s). That is not scaling, so the next plan falls back.
        var wide = second
        wide.concurrency = 10
        tuning.record(serverKey: key, direction: .upload, bytes: 128 * mib, seconds: 2.9, plan: wide)
        let third = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(third.concurrency, 8, third.reason)
    }

    func testFailuresGiveBackConnectionsAndSuccessRestoresThem() {
        let store = TransferTuningStore(persistence: .memory)
        let tuning = TransferTuning(
            store: store,
            networkProvider: { NetworkSnapshot(kind: .wifi, hasPath: true) }
        )
        let key = "example.test/bucket"
        let plan = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        tuning.record(serverKey: key, direction: .upload, bytes: 128 * mib, seconds: 2.37, plan: plan)
        let grown = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(grown.concurrency, 10)

        tuning.penalise(serverKey: key, direction: .upload)
        let penalised = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(penalised.concurrency, 8, penalised.reason)

        tuning.penalise(serverKey: key, direction: .upload)
        let twice = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertEqual(twice.concurrency, 6, twice.reason)

        tuning.record(serverKey: key, direction: .upload, bytes: 128 * mib, seconds: 2.37, plan: penalised)
        let recovered = tuning.plan(serverKey: key, direction: .upload, size: 128 * mib)
        XCTAssertGreaterThan(recovered.concurrency, twice.concurrency)
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
            upload: TransferSample(
                throughput: 12_000_000,
                concurrency: 6,
                peakThroughput: 14_000_000,
                peakPerConnection: 2_000_000
            ),
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
