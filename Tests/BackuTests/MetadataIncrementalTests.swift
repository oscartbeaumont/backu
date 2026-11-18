import Foundation
import XCTest

// The sync path used to materialise and reconcile the whole library on every
// change. These tests pin the incremental behaviour: what a sync reports, how
// many requests it makes, how often the local cache is rewritten, and when
// compaction is worth a snapshot.

@MainActor
final class MetadataIncrementalTests: XCTestCase {
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

    private func service(
        _ writer: String,
        id: UUID = UUID(),
        compaction: MetadataCompactionPolicy = MetadataCompactionPolicy()
    ) -> MetadataService {
        cleanupIDs.append(id)
        return MetadataService(serverID: id, writerID: writer, compaction: compaction)
    }

    private func photo(
        _ id: String,
        serverID: UUID,
        favorite: Bool = false,
        tags: [String] = []
    ) -> PhotoItem {
        PhotoItem(
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
                    sha256: "sha-\(id)"
                )
            ],
            sha256: "sha-\(id)"
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

    /// A writer with a published snapshot and one reader that has consumed it.
    private func warmedPair(
        photos count: Int = 20
    ) async throws -> (store: InMemoryMetadataStore, a: MetadataService, catA: CatalogStore,
                       b: MetadataService, catB: CatalogStore, aID: UUID) {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned((0..<count).map { photo("asset:\($0)", serverID: aID) })
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let b = service("writer-b")
        let catB = CatalogStore(loadFromDisk: false)
        let first = try await b.sync(store: store)
        catB.applyMergedMetadata(
            photos: first.photos,
            people: first.people,
            deletedPeople: first.deletedPeople,
            deletedHashes: first.deletedHashes
        )
        return (store, a, catA, b, catB, aID)
    }

    // MARK: - Incremental materialisation

    func testOnePhotoEditReturnsOnlyThatPhoto() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        let warm = try await b.sync(store: store)
        XCTAssertFalse(warm.changed)

        catA.addTag("beach", to: "asset:7")
        try await publish(catA, a, store)

        let outcome = try await b.sync(store: store)
        XCTAssertTrue(outcome.changed)
        XCTAssertFalse(outcome.isFull, "A segment replay must not materialise the library")
        XCTAssertEqual(outcome.photos.count, 1)
        XCTAssertEqual(outcome.photos.first?.id, "remote:asset:7")
        XCTAssertEqual(outcome.photos.first?.tags, ["beach"])
        XCTAssertTrue(outcome.removedPhotoIDs.isEmpty)
    }

    func testDeletedPhotoIsReportedAsAnIncrementalRemoval() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        _ = try await b.sync(store: store)

        catA.removePhotos(["asset:3"])
        try await publish(catA, a, store)

        let outcome = try await b.sync(store: store)
        XCTAssertFalse(outcome.isFull)
        XCTAssertEqual(outcome.removedPhotoIDs, ["asset:3"])
        XCTAssertTrue(outcome.photos.isEmpty, "A delete has nothing to upsert")
    }

    func testColdStartStillMaterialisesEverything() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned((0..<12).map { photo("asset:\($0)", serverID: aID) })
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        await a.compactIfNeeded(store: store, force: true)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertTrue(outcome.isFull)
        XCTAssertEqual(outcome.photos.count, 12)
    }

    func testASegmentFullOfNoOpsDoesNotResurrectTheLibrary() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        _ = try await b.sync(store: store)

        // Two edits to different photos in one segment: both must surface, and
        // only them.
        catA.addTag("one", to: "asset:1")
        catA.addTag("two", to: "asset:2")
        try await publish(catA, a, store)

        let outcome = try await b.sync(store: store)
        XCTAssertEqual(Set(outcome.photos.map(\.id)), ["remote:asset:1", "remote:asset:2"])
    }

    // MARK: - Request accounting

    func testWarmSyncIsOneHeadGetTwoListsAndNoSegmentGets() async throws {
        let (store, _, _, b, _, _) = try await warmedPair()
        _ = try await b.sync(store: store)
        await store.resetLogs()

        let outcome = try await b.sync(store: store)
        XCTAssertFalse(outcome.changed)

        let gets = await store.getLog
        let lists = await store.listLog
        let puts = await store.putLog
        XCTAssertEqual(gets, [MetadataLayout.headKey], "Only the conditional head GET")
        XCTAssertEqual(
            lists,
            [MetadataLayout.logPrefix + "/", MetadataLayout.writerPrefix("writer-a") + "/"],
            "One delimiter list plus one per-writer list"
        )
        XCTAssertTrue(puts.isEmpty, "A reader never writes")
    }

    func testOneNewSegmentCostsExactlyOneGet() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        _ = try await b.sync(store: store)
        catA.addTag("beach", to: "asset:4")
        try await publish(catA, a, store)
        await store.resetLogs()

        let outcome = try await b.sync(store: store)
        XCTAssertTrue(outcome.changed)
        let gets = await store.getLog
        let puts = await store.putLog
        XCTAssertEqual(gets.filter { $0.hasPrefix(MetadataLayout.logPrefix) }.count, 1)
        XCTAssertEqual(gets.filter { $0 == MetadataLayout.headKey }.count, 1)
        XCTAssertTrue(puts.isEmpty)
    }

    func testStateLossRecoversTheSequenceWithoutAnExtraList() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let writer = service("writer-a", id: id)
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned([photo("asset:1", serverID: id)])
        try await publish(catalog, writer, store)
        XCTAssertEqual(writer.replication.sequence, 1)

        // Removing and re-adding the server loses the state file but not the
        // writer id. Reusing sequence 0 would hide new segments forever; the
        // listing the sync already performs answers the probe for free.
        try? FileManager.default.removeItem(at: AppPaths.metadataStateFile(id))
        let reincarnated = service("writer-a", id: id)
        await store.resetLogs()

        _ = try await reincarnated.sync(store: store)
        let lists = await store.listLog
        XCTAssertEqual(lists.count, 2, "One delimiter list plus one per-writer list")
        XCTAssertEqual(reincarnated.replication.sequence, 1)
    }

    // MARK: - Cache write throttling

    func testSmallIncrementalSyncDoesNotRewriteTheCache() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        let afterColdStart = b.cacheWriteCount
        XCTAssertEqual(afterColdStart, 1, "The snapshot load seeds the cache")

        _ = try await b.sync(store: store)
        catA.addTag("beach", to: "asset:2")
        try await publish(catA, a, store)
        _ = try await b.sync(store: store)
        XCTAssertEqual(b.cacheWriteCount, afterColdStart, "One record must not rewrite 13 MB")

        // Pending edits still force a write once they pile up.
        b.cacheRecordThreshold = 2
        catA.addTag("sunset", to: "asset:5")
        catA.addTag("dawn", to: "asset:6")
        try await publish(catA, a, store)
        _ = try await b.sync(store: store)
        XCTAssertEqual(b.cacheWriteCount, afterColdStart + 1)

        // Backgrounding asks for a write even below the threshold.
        catA.addTag("noon", to: "asset:9")
        try await publish(catA, a, store)
        _ = try await b.sync(store: store)
        b.flushCacheIfNeeded()
        XCTAssertEqual(b.cacheWriteCount, afterColdStart + 2)
    }

    func testStaleCacheReplaysTheSegmentsItMissed() async throws {
        let (store, a, catA, b, _, _) = try await warmedPair()
        #if DEBUG
        await b.flushCacheForTesting()
        #endif
        _ = try await b.sync(store: store)
        catA.addTag("beach", to: "asset:2")
        try await publish(catA, a, store)
        let outcome = try await b.sync(store: store)
        XCTAssertTrue(outcome.changed)

        // The throttled cache is one record behind. That is safe: the header
        // watermark inside it is authoritative, so a relaunch replays the
        // segment instead of trusting the newer state file.
        let cached = try Gzip.decompress(Data(contentsOf: AppPaths.metadataCacheFile(b.serverID)))
        XCTAssertFalse(String(decoding: cached, as: UTF8.self).contains("\"beach\""))

        let reincarnated = service("writer-b", id: b.serverID)
        let replay = try await reincarnated.sync(store: store)
        XCTAssertTrue(replay.changed, "The stale cache must force the segment to be replayed")
        XCTAssertEqual(reincarnated.state.photos["asset:2"]?.tags.keys.sorted(), ["beach"])
    }

    // MARK: - Seed

    func testSeedUploadsInParallelAndLandsEveryPhoto() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let seed = service("writer-a", id: id)
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned((0..<2_000).map { photo("asset:\($0)", serverID: id) })

        _ = try await seed.sync(store: store)
        XCTAssertTrue(seed.replication.isMigration)
        await seed.seedIfNeeded(catalog: catalog, store: store)
        XCTAssertTrue(seed.replication.seeded)

        let peak = await store.peakConcurrentPuts
        XCTAssertGreaterThan(peak, 1, "Seed batches should overlap their PUTs")

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 2_000)
        XCTAssertEqual(Set(outcome.photos.map(\.id)).count, 2_000)
    }

    func testFailedParallelBatchResumesWithoutLosingOrDuplicatingRecords() async throws {
        let store = InMemoryMetadataStore()
        let id = UUID()
        let seed = service("writer-a", id: id)
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned((0..<2_000).map { photo("asset:\($0)", serverID: id) })
        _ = try await seed.sync(store: store)

        await store.failPuts(matching: MetadataLayout.logPrefix, count: 1)
        await seed.seedIfNeeded(catalog: catalog, store: store)
        XCTAssertFalse(seed.replication.seeded)
        XCTAssertTrue(seed.hasOutbox)

        let resumed = service("writer-a", id: id)
        await resumed.seedIfNeeded(catalog: catalog, store: store)
        XCTAssertTrue(resumed.replication.seeded)

        let b = service("writer-b")
        let outcome = try await b.sync(store: store)
        XCTAssertEqual(outcome.photos.count, 2_000)
    }

    // MARK: - Compaction thresholds

    func testCompactionWaitsForTheConfiguredThresholds() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service(
            "writer-a",
            id: aID,
            compaction: MetadataCompactionPolicy(segmentThreshold: 3, editThreshold: 10_000)
        )
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned((0..<10).map { photo("asset:\($0)", serverID: aID) })
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        XCTAssertEqual(a.replication.segmentsSinceSnapshot, 1)
        let headBeforeThreshold = await store.data(for: MetadataLayout.headKey)
        XCTAssertNil(headBeforeThreshold)

        await a.compactIfNeeded(store: store)
        let headStillMissing = await store.data(for: MetadataLayout.headKey)
        XCTAssertNil(headStillMissing, "Below the segment threshold")

        catA.addTag("one", to: "asset:1")
        try await publish(catA, a, store)
        catA.addTag("two", to: "asset:2")
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        XCTAssertEqual(a.replication.segmentsSinceSnapshot, 3)

        await a.compactIfNeeded(store: store)
        let head = await store.data(for: MetadataLayout.headKey)
        XCTAssertNotNil(head)
        XCTAssertEqual(a.replication.segmentsSinceSnapshot, 0)
    }

    func testEditThresholdCompactsABusyLogBeforeTheSegmentLimit() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service(
            "writer-a",
            id: aID,
            compaction: MetadataCompactionPolicy(segmentThreshold: 100, editThreshold: 5)
        )
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned((0..<10).map { photo("asset:\($0)", serverID: aID) })
        try await publish(catA, a, store)
        _ = try await a.sync(store: store)
        XCTAssertGreaterThanOrEqual(a.replication.editsSinceSnapshot, 5)
        XCTAssertLessThan(a.replication.segmentsSinceSnapshot, 100)

        await a.compactIfNeeded(store: store)
        let head = await store.data(for: MetadataLayout.headKey)
        XCTAssertNotNil(head)
    }

    func testDefaultPolicyDoesNotSnapshotAfterEightTrivialSegments() async throws {
        let store = InMemoryMetadataStore()
        let aID = UUID()
        let a = service("writer-a", id: aID)
        let catA = CatalogStore(loadFromDisk: false)
        catA.mergeScanned((0..<10).map { photo("asset:\($0)", serverID: aID) })
        for index in 0..<8 {
            catA.addTag("tag-\(index)", to: "asset:\(index)")
            try await publish(catA, a, store)
        }
        _ = try await a.sync(store: store)
        XCTAssertEqual(a.replication.segmentsSinceSnapshot, 8)

        await a.compactIfNeeded(store: store)
        let head = await store.data(for: MetadataLayout.headKey)
        XCTAssertNil(
            head,
            "A 13 MB snapshot after eight small edits is exactly what the edit threshold avoids"
        )
    }
}

// MARK: - Snapshot streaming

final class SnapshotStreamingTests: XCTestCase {
    private func sampleState(serverID: UUID, photos: Int) -> MergedMetadata {
        var state = MergedMetadata()
        for index in 0..<photos {
            let item = PhotoItem(
                id: "asset:\(index)",
                filename: "IMG_\(index).jpg",
                takenAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                tags: index % 3 == 0 ? ["beach", "family"] : [],
                copies: [
                    PhotoCopy(
                        serverID: serverID,
                        objectKey: "Backu/Photos/\(index).jpg",
                        sidecarKey: "Backu/Photos/\(index).jpg.json",
                        thumbnailKey: nil,
                        uploadedAt: Date(),
                        byteCount: 1,
                        etag: nil,
                        sha256: "sha-\(index)"
                    )
                ],
                sha256: "sha-\(index)"
            )
            let person = SharedPerson(person: Person(name: "Person \(index)"))
            state.apply([
                MetaRecord(
                    op: .photoUpsert,
                    id: item.id,
                    hlc: Int64(index + 1),
                    by: "writer-a",
                    photo: SharedPhoto(photo: item, serverID: serverID),
                    tagsAdd: item.tags.isEmpty ? nil : item.tags,
                    facesSet: [
                        SharedFace(face: PhotoFace(personID: person.id, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
                    ]
                ),
                MetaRecord(
                    op: .personUpsert,
                    id: person.id.uuidString,
                    hlc: Int64(index + 1),
                    by: "writer-a",
                    person: person
                )
            ])
        }
        return state
    }

    func testStreamedDecodeMatchesTheBufferedDecode() throws {
        let state = sampleState(serverID: UUID(), photos: 2_000)
        let raw = state.encodeSnapshot(generation: 7, watermark: ["writer-a": 3])
        let compressed = try Gzip.compress(raw)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try compressed.write(to: url)

        let buffered = try MergedMetadata.decodeSnapshot(raw)
        let streamed = try MergedMetadata.decodeSnapshot(gzipFile: url)
        XCTAssertEqual(streamed.header.generation, buffered.header.generation)
        XCTAssertEqual(streamed.header.watermark, buffered.header.watermark)
        XCTAssertEqual(streamed.header.count, buffered.header.count)
        XCTAssertEqual(streamed.metadata.photos.count, buffered.metadata.photos.count)
        XCTAssertEqual(streamed.metadata.people.count, buffered.metadata.people.count)
        XCTAssertEqual(
            streamed.metadata.photos["asset:17"]?.photo.filename,
            buffered.metadata.photos["asset:17"]?.photo.filename
        )
    }

    func testStreamedDecodeHandlesSmallChunksAndMultiByteCharacters() throws {
        // A tiny chunk size forces line splits at awkward byte boundaries.
        let state = sampleState(serverID: UUID(), photos: 50)
        let person = SharedPerson(person: Person(name: "Zoë 🐈 日本語"))
        var withName = state
        withName.people[person.id.uuidString] = MergedPerson(person: person)
        let raw = withName.encodeSnapshot(generation: 1, watermark: ["writer-a": 0])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Gzip.compress(raw).write(to: url)

        var decodersSaw: [String] = []
        try Gzip.decompress(fileURL: url, chunkSize: 7) { _ in decodersSaw.append("x") }
        XCTAssertFalse(decodersSaw.isEmpty)

        let lenient = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: lenient) }
        try Gzip.compress(raw).write(to: lenient)
        // The streamed decoder verifies the ISIZE and CRC even when it never
        // holds the whole body.
        let decoded = try MergedMetadata.decodeSnapshot(gzipFile: lenient)
        XCTAssertEqual(decoded.metadata.photos.count, 50)
    }

    func testStreamedDecodeRejectsACorruptSnapshot() throws {
        let state = sampleState(serverID: UUID(), photos: 10)
        let raw = state.encodeSnapshot(generation: 1, watermark: ["a": 0])
        var compressed = try Gzip.compress(raw)
        // Flip a byte in the middle of the deflate stream.
        compressed[compressed.count / 2] ^= 0xFF
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try compressed.write(to: url)

        XCTAssertThrowsError(try MergedMetadata.decodeSnapshot(gzipFile: url))
    }
}

// MARK: - Catalog incremental apply

@MainActor
final class CatalogIncrementalTests: XCTestCase {
    private func photo(_ id: String, sha: String? = nil, local: Bool = false, serverID: UUID) -> PhotoItem {
        PhotoItem(
            id: id,
            localIdentifier: local ? id : nil,
            filename: "\(id).jpg",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/Photos/\(id).jpg",
                    sidecarKey: "Backu/Photos/\(id).jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: sha ?? "sha-\(id)"
                )
            ],
            sha256: sha ?? "sha-\(id)"
        )
    }

    func testIncrementalItemFoldsIntoAPhotoWithTheSameBytes() {
        let catalog = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        catalog.mergeScanned([photo("asset:local", sha: "same", local: true, serverID: serverID)])

        // Another device uploaded the same bytes under a different id.
        var twin = photo("remote:twin", sha: "same", serverID: serverID)
        twin.tags = ["beach"]
        let added = catalog.applyMergedMetadata(
            photos: [twin],
            people: [],
            deletedPeople: [],
            deletedHashes: []
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(catalog.photos.count, 1, "Duplicate bytes must not add a second row")
        XCTAssertEqual(catalog.photo(id: "asset:local")?.tags, ["beach"])
    }

    func testIncrementalRemovalOnlyTouchesTheNamedPhoto() {
        let catalog = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        catalog.applyMergedMetadata(
            photos: [
                photo("remote:1", serverID: serverID),
                photo("remote:2", serverID: serverID),
                photo("remote:3", serverID: serverID)
            ],
            people: [],
            deletedPeople: [],
            deletedHashes: []
        )
        XCTAssertEqual(catalog.photos.count, 3)

        catalog.removeRemotePhotos(serverID: serverID, removedIDs: ["2"], deletedHashes: [])

        XCTAssertNil(catalog.photo(id: "remote:2"))
        XCTAssertNotNil(catalog.photo(id: "remote:1"))
        XCTAssertNotNil(catalog.photo(id: "remote:3"))
    }

    func testIncrementalRemovalKeepsALocalAssetThatStillHasACopy() {
        let catalog = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        catalog.mergeScanned([photo("asset:1", local: true, serverID: serverID)])

        catalog.removeRemotePhotos(serverID: serverID, removedIDs: ["1"], deletedHashes: [])

        XCTAssertNotNil(catalog.photo(id: "asset:1"), "A local asset is never deleted by the log")
    }

    func testHashTombstoneRetiresTheMatchingRemoteOnlyPhoto() {
        let catalog = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        catalog.applyMergedMetadata(
            photos: [
                photo("remote:1", sha: "gone", serverID: serverID),
                photo("remote:2", sha: "kept", serverID: serverID)
            ],
            people: [],
            deletedPeople: [],
            deletedHashes: []
        )

        catalog.removeRemotePhotos(serverID: serverID, removedIDs: [], deletedHashes: ["gone"])

        XCTAssertNil(catalog.photo(id: "remote:1"))
        XCTAssertNotNil(catalog.photo(id: "remote:2"))
    }

    func testIncrementalApplyKeepsTheIdIndexInSync() {
        let catalog = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        catalog.applyMergedMetadata(
            photos: (0..<5).map { photo("remote:\($0)", serverID: serverID) },
            people: [],
            deletedPeople: [],
            deletedHashes: []
        )
        // A later edit to the last photo must find it by id, not by scanning.
        var edited = photo("remote:4", serverID: serverID)
        edited.tags = ["later"]
        catalog.applyMergedMetadata(
            photos: [edited],
            people: [],
            deletedPeople: [],
            deletedHashes: []
        )
        XCTAssertEqual(catalog.photo(id: "remote:4")?.tags, ["later"])
        XCTAssertEqual(catalog.photos.count, 5)
    }
}
