import Foundation
import XCTest

// The journal is the part of the sync stack where a bug becomes data loss, so
// these tests run it against an in-memory object store with injected failures.
// Nothing here touches S3, a mock server, or the network.

@MainActor
final class MetadataProtocolTests: XCTestCase {
    private var cleanupIDs: [UUID] = []

    override func tearDown() {
        for id in cleanupIDs {
            try? FileManager.default.removeItem(at: AppPaths.metadataStateFile(id))
            try? FileManager.default.removeItem(at: AppPaths.metadataCacheFile(id))
            try? FileManager.default.removeItem(at: AppPaths.metadataOutboxFile(id))
        }
        cleanupIDs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func service(_ writer: String, id: UUID = UUID()) -> MetadataService {
        cleanupIDs.append(id)
        return MetadataService(serverID: id, writerID: writer)
    }

    private func photo(
        _ id: String,
        serverID: UUID,
        sha: String? = nil,
        favorite: Bool = false,
        tags: [String] = []
    ) -> PhotoItem {
        let hash = sha ?? "sha-\(id)"
        return PhotoItem(
            id: id,
            localIdentifier: nil,
            filename: "\(id).jpg",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFavorite: favorite,
            pixelWidth: 100,
            pixelHeight: 100,
            tags: tags,
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/Photos/\(id).jpg",
                    sidecarKey: "Backu/Photos/\(id).jpg.json",
                    thumbnailKey: "Backu/.backu/thumbs/\(id).jpg",
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: hash
                )
            ],
            sha256: hash
        )
    }

    @discardableResult
    private func publish(
        _ catalog: CatalogStore,
        _ service: MetadataService,
        _ store: InMemoryMetadataStore
    ) async throws -> Bool {
        let delta = catalog.takeMetadataDelta()
        _ = service.recordLocalChanges(delta: delta, catalog: catalog)
        return try await service.flush(store: store)
    }

    private func segmentRecords(
        _ store: InMemoryMetadataStore,
        writer: String
    ) async throws -> [MetaRecord] {
        var records: [MetaRecord] = []
        for key in await store.keys(under: ".backu/meta/v2/log/\(writer)/") {
            guard let data = await store.data(for: key) else { continue }
            records.append(contentsOf: MetadataSegmentCodec.decode(try Gzip.decompress(data)))
        }
        return records
    }

    // MARK: - Success paths

    func testColdStartReadsHeadAndSnapshotWithoutSegments() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let photos = (0..<20).map { photo("asset:\($0)", serverID: aID) }
        catA.mergeScanned(photos)
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        await store.resetLogs()
        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.photos.count, 20)

        let gets = await store.getLog
        XCTAssertTrue(gets.contains(MetadataLayout.headKey))
        XCTAssertTrue(gets.contains { $0.hasPrefix(".backu/meta/v2/snap/") })
        XCTAssertFalse(gets.contains { $0.hasPrefix(".backu/meta/v2/log/") })
        let puts = await store.putLog
        XCTAssertTrue(puts.isEmpty, "A reader must not write")
    }

    func testNotModifiedHeadStillPullsSegmentsWrittenSinceTheLastCompaction() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])
        catA.setFavorite(item.id, isFavorite: true)
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let bID = UUID()
        let b = service("writer-b", id: bID)
        _ = try await b.sync(store: store)
        let unchanged = try await b.sync(store: store)
        XCTAssertFalse(unchanged.changed, "The second sync should be a 304 + no new segments")

        // A writes a segment but does not compact: head.json is unchanged, so
        // the next sync gets a 304. The journal must still list the log.
        catA.addTag("beach", to: item.id)
        try await publish(catA, a, store)

        let afterEdit = try await b.sync(store: store)
        XCTAssertTrue(afterEdit.changed, "A 304 must not stop segment listing")
        XCTAssertEqual(afterEdit.photos.first?.tags, ["beach"])
    }

    func testTwoWritersMergeDifferentFields() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])
        catA.setFavorite(item.id, isFavorite: true)
        try await publish(catA, a, store)

        let bID = UUID()
        let b = service("writer-b", id: bID)
        let catB = CatalogStore(loadFromDisk: false)
        let first = try await b.sync(store: store)
        catB.applyMergedMetadata(
            photos: first.photos,
            people: first.people,
            deletedPeople: first.deletedPeople,
            deletedHashes: first.deletedHashes
        )
        XCTAssertEqual(catB.photos.first?.isFavorite, true)
        catB.addTag("sunset", to: catB.photos[0].id)
        try await publish(catB, b, store)

        let second = try await a.sync(store: store)
        XCTAssertTrue(second.changed)
        XCTAssertEqual(second.photos.first?.isFavorite, true)
        XCTAssertEqual(second.photos.first?.tags, ["sunset"])
    }

    func testStoreWithoutDelimiterFallsBackToTheInlineLog() async throws {
        let store = InMemoryMetadataStore()
        await store.setSupportsDelimiter(false)
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned([photo("asset:1", serverID: aID)])
        try await publish(catA, a, store)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 1)
    }

    func testAtlasPointerIsPublished() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])
        catA.recordUpload(
            copy: PhotoCopy(
                serverID: aID,
                objectKey: "Backu/Photos/asset:1.jpg",
                sidecarKey: "Backu/Photos/asset:1.jpg.json",
                thumbnailKey: "Backu/.backu/thumbs/asset:1.jpg",
                uploadedAt: Date(),
                byteCount: 1,
                etag: nil,
                sha256: "sha-asset:1"
            ),
            for: item.id
        )
        _ = catA.takeMetadataDelta() // isolate the atlas write
        catA.recordAtlas(serverID: aID, group: "group-1", assignments: [item.id: 7])
        try await publish(catA, a, store)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        let copy = outcome.photos.first?.copies.first
        XCTAssertEqual(copy?.atlasGroup, "group-1")
        XCTAssertEqual(copy?.atlasCell, 7)
    }

    func testRescanDoesNotRevertARemoteTag() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])

        // Another device tags the photo.
        let b = service("writer-b")
        var remote = item
        remote.tags = ["beach"]
        let record = MetaRecord(
            op: .photoUpsert,
            id: item.id,
            hlc: HybridClock.now() << 16,
            by: "writer-b",
            photo: SharedPhoto(photo: remote, serverID: b.serverID),
            tagsAdd: ["beach"]
        )
        let raw = try MetadataSegmentCodec.encode([record])
        let compressed = try Gzip.compress(raw)
        await store.seed(
            MetadataLayout.segmentKey(
                writer: "writer-b",
                sequence: 0,
                hlc: record.hlc,
                digest: SigV4Signer.sha256Hex(compressed)
            ),
            compressed
        )

        let outcome = try await a.sync(store: store)
        catA.applyMergedMetadata(
            photos: outcome.photos,
            people: outcome.people,
            deletedPeople: outcome.deletedPeople,
            deletedHashes: outcome.deletedHashes
        )
        XCTAssertEqual(catA.photos.first?.tags, ["beach"])

        // A rescan marks every local photo dirty. The writer must see no
        // difference and must not publish a remove for the remote tag.
        catA.mergeScanned([item])
        try await publish(catA, a, store)
        let records = try await segmentRecords(store, writer: "writer-a")
        XCTAssertFalse(records.contains { !($0.tagsRemove ?? []).isEmpty })
        XCTAssertEqual(catA.photos.first?.tags, ["beach"])
    }

    // MARK: - Write failures

    func testFailedPutKeepsOutboxAndRetriesTheSameSegment() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        cat.setFavorite(item.id, isFavorite: true)
        _ = a.recordLocalChanges(delta: cat.takeMetadataDelta(), catalog: cat)

        await store.failPuts(matching: ".backu/meta/v2/log/", count: 1)
        do {
            _ = try await a.flush(store: store)
            XCTFail("The injected PUT failure should surface")
        } catch {}
        XCTAssertTrue(a.hasOutbox)
        XCTAssertEqual(a.replication.sequence, 0)
        let afterFailure = await store.objectCount(under: ".backu/meta/v2/log/")
        XCTAssertEqual(afterFailure, 0)

        let flushed = try await a.flush(store: store)
        XCTAssertTrue(flushed)
        XCTAssertFalse(a.hasOutbox)
        XCTAssertEqual(a.replication.sequence, 1)
        let afterSuccess = await store.objectCount(under: ".backu/meta/v2/log/")
        XCTAssertEqual(afterSuccess, 1)

        // Retrying an already-empty flush is a no-op, not a second segment.
        let second = try await a.flush(store: store)
        XCTAssertTrue(second)
        let afterRetry = await store.objectCount(under: ".backu/meta/v2/log/")
        XCTAssertEqual(afterRetry, 1)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 1)
        XCTAssertEqual(outcome.photos.first?.isFavorite, true)
    }

    func testLostPutResponseDoesNotDuplicateRecords() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        cat.addTag("beach", to: item.id)
        _ = a.recordLocalChanges(delta: cat.takeMetadataDelta(), catalog: cat)

        // The object lands but the response is lost.
        await store.failPutsAfterStoring(matching: ".backu/meta/v2/log/", count: 1)
        do {
            _ = try await a.flush(store: store)
            XCTFail("The lost response should surface as an error")
        } catch {}
        let keysAfterLoss = await store.keys(under: ".backu/meta/v2/log/writer-a/")
        XCTAssertEqual(keysAfterLoss.count, 1)
        XCTAssertTrue(a.hasOutbox, "The caller cannot know it landed")

        let retried = try await a.flush(store: store)
        XCTAssertTrue(retried)
        let keysAfterRetry = await store.keys(under: ".backu/meta/v2/log/writer-a/")
        XCTAssertEqual(keysAfterRetry, keysAfterLoss, "Retry must overwrite the same key")
        XCTAssertEqual(a.replication.sequence, 1)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 1)
        XCTAssertEqual(outcome.photos.first?.tags, ["beach"])
    }

    func testFlushWhileAnotherFlushIsRunningReportsBusy() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        cat.mergeScanned([photo("asset:1", serverID: id)])
        _ = a.recordLocalChanges(delta: cat.takeMetadataDelta(), catalog: cat)

        async let first = a.flush(store: store)
        async let second = a.flush(store: store)
        let results = try await [first, second]
        XCTAssertTrue(results.contains(false), "One caller must be told to retry")
        // Whatever happened, the outbox either drained exactly once or remains;
        // a later flush must converge without duplicating.
        while a.hasOutbox {
            _ = try await a.flush(store: store)
        }
        let records = try await segmentRecords(store, writer: "writer-a")
        XCTAssertEqual(records.count, 1)
    }

    // MARK: - Read failures

    func testSegmentGetFailureDoesNotAdvanceTheWatermark() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        cat.addTag("one", to: item.id)
        try await publish(cat, a, store)
        cat.setFavorite(item.id, isFavorite: true)
        try await publish(cat, a, store)
        let segmentCount = await store.objectCount(under: ".backu/meta/v2/log/writer-a/")
        XCTAssertEqual(segmentCount, 2)

        let b = service("writer-b")
        await store.failGets(matching: ".backu/meta/v2/log/", count: 1)
        do {
            _ = try await b.sync(store: store)
            XCTFail("A missing segment must fail the sync")
        } catch {}
        XCTAssertNil(b.replication.watermark["writer-a"])

        let retry = try await b.sync(store: store)
        XCTAssertTrue(retry.changed)
        XCTAssertEqual(retry.photos.first?.tags, ["one"])
        XCTAssertEqual(retry.photos.first?.isFavorite, true)
    }

    func testCorruptSegmentCanBeRetried() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        cat.mergeScanned([photo("asset:1", serverID: id)])
        try await publish(cat, a, store)

        let segmentKeys = await store.keys(under: ".backu/meta/v2/log/writer-a/")
        let key = try XCTUnwrap(segmentKeys.first)
        let originalData = await store.data(for: key)
        let original = try XCTUnwrap(originalData)
        await store.seed(key, Data([0x1f, 0x8b, 0x08, 0x00]))

        let b = service("writer-b")
        do {
            _ = try await b.sync(store: store)
            XCTFail("A truncated gzip segment must fail the sync")
        } catch {}
        XCTAssertNil(b.replication.watermark["writer-a"])

        await store.seed(key, original)
        let retry = try await b.sync(store: store)
        XCTAssertEqual(retry.photos.count, 1)
    }

    func testListFailureLeavesTheJournalUntouched() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        cat.mergeScanned([photo("asset:1", serverID: id)])
        try await publish(cat, a, store)

        let b = service("writer-b")
        await store.failLists(count: 1)
        do {
            _ = try await b.sync(store: store)
            XCTFail("A list failure must surface")
        } catch {}
        XCTAssertNil(b.replication.watermark["writer-a"])

        let retried = try await b.sync(store: store)
        XCTAssertEqual(retried.photos.count, 1)
    }

    func testMissingSnapshotIsRetriedEvenAfterA304() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned([photo("asset:1", serverID: aID)])
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let snapshotKeys = await store.keys(under: ".backu/meta/v2/snap/")
        let snapshotKey = try XCTUnwrap(snapshotKeys.first)
        let snapshotBody = await store.data(for: snapshotKey)
        let snapshotData = try XCTUnwrap(snapshotBody)

        let bID = UUID()
        let b = service("writer-b", id: bID)
        _ = try await b.sync(store: store)
        #if DEBUG
        await b.flushCacheForTesting()
        #endif

        // Simulate a reinstall of the local cache: the state file still knows
        // the head and snapshot, but the merged-state cache is gone.
        try? FileManager.default.removeItem(at: AppPaths.metadataCacheFile(bID))
        await store.delete(snapshotKey)

        let reincarnated = service("writer-b", id: bID)
        do {
            _ = try await reincarnated.sync(store: store)
            XCTFail("The missing snapshot must fail the sync")
        } catch {}
        let headGets = await store.getLog
        XCTAssertTrue(headGets.contains(snapshotKey), "304 must still re-read a missing snapshot")

        await store.seed(snapshotKey, snapshotData)
        let retry = try await reincarnated.sync(store: store)
        XCTAssertEqual(retry.photos.count, 1)
    }

    func testCorruptHeadNeverTriggersMigrationOrOverwrite() async throws {
        let store = InMemoryMetadataStore()
        await store.seed(MetadataLayout.headKey, Data("not a head".utf8))

        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        cat.mergeScanned([photo("asset:1", serverID: id)])

        let outcome = try await a.sync(store: store)
        XCTAssertTrue(outcome.hasHead)
        XCTAssertTrue(outcome.sawLog)
        XCTAssertFalse(outcome.changed)

        await a.seedIfNeeded(catalog: cat, store: store)
        let logCount = await store.objectCount(under: ".backu/meta/v2/log/")
        XCTAssertEqual(logCount, 0)
        await a.compactIfNeeded(store: store, force: true)
        let headAfter = await store.data(for: MetadataLayout.headKey)
        XCTAssertEqual(headAfter, Data("not a head".utf8), "An unreadable head must never be replaced")
    }

    // MARK: - Garbage collection

    func testGarbageCollectionRemovesOnlyCoveredOldSegments() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        for index in 0..<4 {
            cat.addTag("t\(index)", to: item.id)
            try await publish(cat, a, store)
        }
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        // Newer than the snapshot: not covered by its watermark.
        cat.setFavorite(item.id, isFavorite: true)
        try await publish(cat, a, store)
        _ = try await a.sync(store: store)

        let snapshotKeys = await store.keys(under: ".backu/meta/v2/snap/")
        let snapshotKey = try XCTUnwrap(snapshotKeys.first)
        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        for key in await store.keys(under: ".backu/meta/v2/log/writer-a/") {
            await store.setLastModified(key, old)
        }
        await store.setLastModified(snapshotKey, old)

        let deleted = await a.collectGarbage(
            store: store,
            retention: 7 * 86_400,
            now: now
        )
        XCTAssertEqual(deleted, 4, "Only segments covered by the head watermark")
        let remaining = await store.keys(under: ".backu/meta/v2/log/writer-a/")
        XCTAssertEqual(remaining.count, 1)
        let snapshotBody = await store.data(for: snapshotKey)
        XCTAssertNotNil(snapshotBody)

        // A reader still sees every tag (from the snapshot) and the favourite
        // (from the one uncovered segment).
        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(Set(outcome.photos.first?.tags ?? []), ["t0", "t1", "t2", "t3"])
        XCTAssertEqual(outcome.photos.first?.isFavorite, true)
    }

    func testGarbageCollectionKeepsTheHeadSnapshot() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        try await publish(cat, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        cat.addTag("beach", to: item.id)
        try await publish(cat, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let snapshots = await store.keys(under: ".backu/meta/v2/snap/")
        XCTAssertEqual(snapshots.count, 2)
        let headRaw = await store.data(for: MetadataLayout.headKey)
        let headData = try XCTUnwrap(headRaw)
        let head = try JSONFile.decoder.decode(MetadataHead.self, from: headData)
        let headSnapshot = try XCTUnwrap(head.snapshot)

        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        for key in snapshots {
            await store.setLastModified(key, old)
        }
        _ = await a.collectGarbage(store: store, retention: 7 * 86_400, now: now)

        let remaining = await store.keys(under: ".backu/meta/v2/snap/")
        XCTAssertEqual(remaining, [headSnapshot])
    }

    // MARK: - Compaction races

    func testStaleCompactionCannotMoveTheHeadBackwards() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        // B sees A's snapshot, makes an edit, and compacts to a newer head.
        let bID = UUID()
        let b = service("writer-b", id: bID)
        let catB = CatalogStore(loadFromDisk: false)
        let first = try await b.sync(store: store)
        catB.applyMergedMetadata(
            photos: first.photos,
            people: first.people,
            deletedPeople: first.deletedPeople,
            deletedHashes: first.deletedHashes
        )
        catB.setFavorite(catB.photos[0].id, isFavorite: true)
        try await publish(catB, b, store)
        _ = try await b.sync(store: store)
        await b.compactIfNeeded(store: store, force: true)
        let headBeforeData = await store.data(for: MetadataLayout.headKey)
        let headBefore = try XCTUnwrap(headBeforeData)

        // A is stale (it never saw B's edit) and compacts anyway.
        await a.compactIfNeeded(store: store, force: true)
        let headAfter = await store.data(for: MetadataLayout.headKey)
        XCTAssertEqual(headAfter, headBefore)

        let c = service("writer-c")
        let outcome = try await c.sync(store: store)
        XCTAssertEqual(outcome.photos.first?.isFavorite, true)
    }

    // MARK: - Crashes and migration

    func testSeedResumesAfterAFailedBatch() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let first = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let photos = (0..<1_100).map { photo("asset:\($0)", serverID: id) }
        cat.mergeScanned(photos)

        _ = try await first.sync(store: store)
        XCTAssertTrue(first.replication.isMigration)

        await store.failPuts(matching: ".backu/meta/v2/log/", count: 1)
        await first.seedIfNeeded(catalog: cat, store: store)
        XCTAssertFalse(first.replication.seeded)
        XCTAssertTrue(first.hasOutbox)
        XCTAssertNotNil(first.replication.seedPendingLastID)

        // Relaunch: a new service reloads the outbox and resumes by id.
        let resumed = service("writer-a", id: id)
        await resumed.seedIfNeeded(catalog: cat, store: store)
        XCTAssertTrue(resumed.replication.seeded)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 1_100)
        XCTAssertEqual(Set(outcome.photos.map(\.id)).count, 1_100)
    }

    func testSequenceProbeAfterStateLoss() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: id)
        cat.mergeScanned([item])
        try await publish(cat, a, store)
        XCTAssertEqual(a.replication.sequence, 1)

        // Remove and re-add the server: the state file is gone, the writer id
        // survives. Reusing sequence 0 would hide the new segment forever.
        try? FileManager.default.removeItem(at: AppPaths.metadataStateFile(id))
        let reincarnated = service("writer-a", id: id)
        _ = try await reincarnated.sync(store: store)
        XCTAssertEqual(reincarnated.replication.sequence, 1)

        cat.setFavorite(item.id, isFavorite: true)
        _ = reincarnated.recordLocalChanges(delta: cat.takeMetadataDelta(), catalog: cat)
        let flushed = try await reincarnated.flush(store: store)
        XCTAssertTrue(flushed)
        let keys = await store.keys(under: ".backu/meta/v2/log/writer-a/")
        XCTAssertTrue(keys.contains { $0.contains("/000000000001-") }, "The new segment must not reuse sequence 0")
    }

    // MARK: - Semantics that protect data

    func testNilShaCopyWithNoLocalHashIsAnUpsertNotADelete() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let a = service("writer-a", id: id)
        let cat = CatalogStore(loadFromDisk: false)
        var item = photo("asset:1", serverID: id)
        item.sha256 = nil
        item.copies[0].sha256 = nil
        cat.mergeScanned([item])
        try await publish(cat, a, store)

        let records = try await segmentRecords(store, writer: "writer-a")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].op, .photoUpsert)
    }

    func testPersonDeleteSurvivesSnapshotAndRemovesFromReaders() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        let item = photo("asset:1", serverID: aID)
        catA.mergeScanned([item])
        let person = catA.createPerson(name: "Ada")
        catA.assign(faceID: UUID(), in: item.id, to: person.id)
        // The face does not exist; create one so the person is referenced.
        catA.mutatePhoto(item.id) { photo in
            photo.faces = [PhotoFace(personID: person.id, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        }
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let b = service("writer-b")
        let beforeDelete = try await b.sync(store: store)
        XCTAssertEqual(beforeDelete.people.count, 1)

        catA.deletePerson(person.id)
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let c = service("writer-c")
        let outcome = try await c.sync(store: store)
        XCTAssertTrue(outcome.deletedPeople.contains(person.id))
        XCTAssertTrue(outcome.people.isEmpty)
    }

    func testHLCAdvancesPastReceivedRecords() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let b = service("writer-b", id: id)
        let future = (HybridClock.now() + 3_600_000) << 16
        let item = photo("asset:1", serverID: id)
        let record = MetaRecord(
            op: .photoUpsert,
            id: item.id,
            hlc: future,
            by: "writer-future",
            photo: SharedPhoto(photo: item, serverID: id)
        )
        let raw = try MetadataSegmentCodec.encode([record])
        let compressed = try Gzip.compress(raw)
        let key = MetadataLayout.segmentKey(
            writer: "writer-future",
            sequence: 0,
            hlc: future,
            digest: SigV4Signer.sha256Hex(compressed)
        )
        await store.seed(key, compressed)

        _ = try await b.sync(store: store)
        let catB = CatalogStore(loadFromDisk: false)
        catB.mergeScanned([item])
        catB.setFavorite(item.id, isFavorite: true)
        _ = b.recordLocalChanges(delta: catB.takeMetadataDelta(), catalog: catB)
        let flushed = try await b.flush(store: store)
        XCTAssertTrue(flushed)
        let records = try await segmentRecords(store, writer: "writer-b")
        let ours = try XCTUnwrap(records.first)
        XCTAssertGreaterThan(ours.hlc, future, "A slow local clock must overtake records it has seen")
    }
}
