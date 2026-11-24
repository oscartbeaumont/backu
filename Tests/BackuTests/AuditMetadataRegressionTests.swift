import Foundation
import XCTest

@MainActor
final class AuditMetadataRegressionTests: XCTestCase {
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

    private func newServerID() -> UUID {
        let id = UUID()
        cleanupIDs.append(id)
        return id
    }

    private func copy(
        serverID: UUID,
        objectKey: String,
        sha256: String?
    ) -> PhotoCopy {
        PhotoCopy(
            serverID: serverID,
            objectKey: objectKey,
            sidecarKey: objectKey + ".json",
            thumbnailKey: nil,
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            byteCount: 1,
            etag: nil,
            sha256: sha256
        )
    }

    private func photo(
        id: String,
        serverID: UUID,
        sha256: String? = "sha",
        local: Bool = false,
        tags: [String] = [],
        faces: [PhotoFace] = []
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            localIdentifier: local ? id : nil,
            filename: "\(id).jpg",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            tags: tags,
            faces: faces,
            copies: [copy(serverID: serverID, objectKey: "Backu/Photos/\(id).jpg", sha256: sha256)],
            sha256: sha256
        )
    }

    private func face(_ personID: UUID?, x: Double = 0.1) -> PhotoFace {
        PhotoFace(
            personID: personID,
            rect: NormRect(x: x, y: 0.1, width: 0.2, height: 0.2)
        )
    }

    func testDecodedSnapshotRebuildsFaceCountsForIncrementalUpdates() throws {
        let serverID = UUID()
        let person = Person(name: "Ada")
        let firstFace = face(person.id)
        let secondFace = face(person.id, x: 0.5)
        let first = photo(id: "asset:first", serverID: serverID, sha256: "sha-first", faces: [firstFace])
        let second = photo(id: "asset:second", serverID: serverID, sha256: "sha-second", faces: [secondFace])

        var state = MergedMetadata()
        state.apply([
            MetaRecord(
                op: .photoUpsert,
                id: first.id,
                hlc: 10,
                by: "writer-a",
                photo: SharedPhoto(photo: first, serverID: serverID),
                facesSet: [SharedFace(face: firstFace)]
            ),
            MetaRecord(
                op: .photoUpsert,
                id: second.id,
                hlc: 11,
                by: "writer-a",
                photo: SharedPhoto(photo: second, serverID: serverID),
                facesSet: [SharedFace(face: secondFace)]
            ),
            MetaRecord(
                op: .personUpsert,
                id: person.id.uuidString,
                hlc: 12,
                by: "writer-a",
                person: SharedPerson(person: person)
            )
        ])

        var decoded = try MergedMetadata.decodeSnapshot(
            state.encodeSnapshot(generation: 1, watermark: ["writer-a": 12])
        )
        XCTAssertEqual(decoded.metadata.faceCount(for: person.id), 2)

        let changes = decoded.metadata.apply(
            MetaRecord(
                op: .photoPatch,
                id: first.id,
                hlc: 20,
                by: "writer-b",
                photo: SharedPhoto(photo: first, serverID: serverID),
                facesDelete: [firstFace.id]
            )
        )
        let incremental = decoded.metadata.materialize(serverID: serverID, changes: changes)
        XCTAssertEqual(incremental.people.first { $0.id == person.id }?.faceCount, 1)
    }

    func testDecodedSnapshotRebuildsHashIndexForIncrementalDuplicateMerge() throws {
        let serverID = UUID()
        let first = photo(id: "asset:A", serverID: serverID, sha256: "same", tags: ["phone"])
        var second = photo(id: "asset:B", serverID: serverID, sha256: "same", tags: ["desktop"])
        second.filename = "other-name.jpg"

        var state = MergedMetadata()
        state.apply([
            MetaRecord(
                op: .photoUpsert,
                id: first.id,
                hlc: 10,
                by: "writer-a",
                photo: SharedPhoto(photo: first, serverID: serverID),
                tagsAdd: ["phone"]
            ),
            MetaRecord(
                op: .photoUpsert,
                id: second.id,
                hlc: 11,
                by: "writer-b",
                photo: SharedPhoto(photo: second, serverID: serverID),
                tagsAdd: ["desktop"]
            )
        ])
        let raw = state.encodeSnapshot(generation: 1, watermark: ["writer-a": 10, "writer-b": 11])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-metadata-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Gzip.compress(raw).write(to: url)

        for decoded in [
            try MergedMetadata.decodeSnapshot(raw),
            try MergedMetadata.decodeSnapshot(gzipFile: url)
        ] {
            var metadata = decoded.metadata
            let changes = metadata.apply(
                MetaRecord(
                    op: .photoPatch,
                    id: first.id,
                    hlc: 20,
                    by: "writer-a",
                    photo: SharedPhoto(photo: first, serverID: serverID),
                    tagsAdd: ["beach"]
                )
            )
            let incremental = metadata.materialize(serverID: serverID, changes: changes)
            XCTAssertEqual(incremental.photos.count, 1)
            XCTAssertEqual(Set(incremental.photos.first?.tags ?? []), ["phone", "desktop", "beach"])
        }
    }

    func testRemovingPhotoRecomputesPeopleFaceCounts() {
        let store = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        let item = photo(id: "asset:local", serverID: serverID, local: true)
        store.mergeScanned([item])
        let person = store.createPerson(name: "Ada")
        let detected = face(person.id)
        store.mutatePhoto(item.id) { $0.faces = [detected] }
        store.assign(faceID: detected.id, in: item.id, to: person.id)
        XCTAssertEqual(store.person(id: person.id)?.faceCount, 1)

        store.removePhotos([item.id])

        XCTAssertEqual(store.person(id: person.id)?.faceCount, 0)
    }

    func testReanalysisReplacesFacesInsteadOfRetainingStaleDetections() {
        let store = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        let item = photo(id: "asset:local", serverID: serverID, local: true)
        store.mergeScanned([item])
        let person = store.createPerson(name: "Ada")
        let stale = face(person.id)
        store.mutatePhoto(item.id) { $0.faces = [stale] }
        store.assign(faceID: stale.id, in: item.id, to: person.id)

        store.applyFaceAnalysis(photoID: item.id, faces: [])

        XCTAssertTrue(store.photo(id: item.id)?.faces.isEmpty ?? false)
        XCTAssertEqual(store.person(id: person.id)?.faceCount, 0)
    }

    func testLearningSHAAfterInitialUpsertPublishesTheHash() async throws {
        let serverID = newServerID()
        let service = MetadataService(serverID: serverID, writerID: "writer-a")
        let catalog = CatalogStore(loadFromDisk: false)
        var item = photo(id: "asset:1", serverID: serverID, sha256: nil)
        item.copies[0].sha256 = nil
        catalog.mergeScanned([item])
        _ = service.recordLocalChanges(delta: catalog.takeMetadataDelta(), catalog: catalog)
        let store = InMemoryMetadataStore()
        try await service.flush(store: store)
        _ = try await service.sync(store: store)
        XCTAssertNil(service.state.sharedPhoto(for: item.id)?.sha256)

        catalog.mutatePhoto(item.id) { $0.sha256 = "learned-hash" }
        let recordCount = service.recordLocalChanges(
            delta: catalog.takeMetadataDelta(),
            catalog: catalog
        )

        XCTAssertEqual(recordCount, 1)
        XCTAssertTrue(service.outbox.contains { $0.photo?.sha256 == "learned-hash" })
    }

    func testNilCatalogSHAFavoriteEditDoesNotEraseLearnedSharedSHA() async throws {
        let serverID = newServerID()
        let service = MetadataService(serverID: serverID, writerID: "writer-a")
        let catalog = CatalogStore(loadFromDisk: false)
        let item = photo(id: "asset:1", serverID: serverID, sha256: "learned-hash")
        catalog.mergeScanned([item])
        _ = service.recordLocalChanges(delta: catalog.takeMetadataDelta(), catalog: catalog)
        let store = InMemoryMetadataStore()
        try await service.flush(store: store)
        _ = try await service.sync(store: store)
        XCTAssertEqual(service.state.sharedPhoto(for: item.id)?.sha256, "learned-hash")

        catalog.mutatePhoto(item.id) {
            $0.sha256 = nil
            $0.isFavorite = true
        }
        let recordCount = service.recordLocalChanges(
            delta: catalog.takeMetadataDelta(),
            catalog: catalog
        )

        XCTAssertEqual(recordCount, 1)
        let patch = try XCTUnwrap(service.outbox.last)
        XCTAssertEqual(patch.changed ?? [], ["isFavorite"])
        XCTAssertNil(patch.photo?.sha256)

        var patchedState = service.state
        _ = patchedState.apply(
            MetaRecord(
                op: .photoPatch,
                id: item.id,
                hlc: service.replication.lastHLC + 1,
                by: "writer-b",
                photo: patch.photo,
                changed: ["sha256"]
            )
        )
        XCTAssertEqual(patchedState.sharedPhoto(for: item.id)?.sha256, "learned-hash")

        try await service.flush(store: store)
        _ = try await service.sync(store: store)
        XCTAssertEqual(service.state.sharedPhoto(for: item.id)?.sha256, "learned-hash")
        XCTAssertEqual(service.state.sharedPhoto(for: item.id)?.isFavorite, true)
    }

    func testMalformedJSONLineAbortsSegmentInsteadOfAdvancingWatermark() async throws {
        let serverID = newServerID()
        let reader = MetadataService(serverID: serverID, writerID: "reader")
        let item = photo(id: "asset:1", serverID: serverID)
        let record = MetaRecord(
            op: .photoUpsert,
            id: item.id,
            hlc: 10,
            by: "writer-a",
            photo: SharedPhoto(photo: item, serverID: serverID)
        )
        var raw = try MetadataSegmentCodec.encode([record])
        raw.append(Data("{not valid json}\n".utf8))
        let compressed = try Gzip.compress(raw)
        let key = MetadataLayout.segmentKey(
            writer: "writer-a",
            sequence: 0,
            hlc: record.hlc,
            digest: SigV4Signer.sha256Hex(compressed)
        )
        let store = InMemoryMetadataStore()
        await store.seed(key, compressed)

        do {
            _ = try await reader.sync(store: store)
            XCTFail("A malformed record must abort the sync so the segment can be retried")
        } catch MetadataError.invalidSegment {
            // Expected: no part of an unreadable segment is acknowledged.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(reader.replication.watermark["writer-a"])
        XCTAssertTrue(reader.state.isEmpty)
    }

    func testColdSnapshotRetryMaterializesFullStateAfterMalformedSegment() async throws {
        let serverID = newServerID()
        let reader = MetadataService(serverID: serverID, writerID: "reader")
        let snapshotPhoto = photo(id: "asset:snapshot", serverID: serverID, sha256: "snapshot-hash")
        let segmentPhoto = photo(id: "asset:segment", serverID: serverID, sha256: "segment-hash")

        var snapshotState = MergedMetadata()
        snapshotState.apply(
            MetaRecord(
                op: .photoUpsert,
                id: snapshotPhoto.id,
                hlc: 10,
                by: "writer-a",
                photo: SharedPhoto(photo: snapshotPhoto, serverID: serverID)
            )
        )
        let snapshotData = try Gzip.compress(
            snapshotState.encodeSnapshot(generation: 1, watermark: ["writer-a": 0])
        )
        let snapshotKey = MetadataLayout.snapshotKey(
            generation: 1,
            hlc: 10,
            digest: SigV4Signer.sha256Hex(snapshotData)
        )
        let head = MetadataHead(
            generation: 1,
            snapshot: snapshotKey,
            watermark: ["writer-a": 0],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            device: "test"
        )
        let segmentRecord = MetaRecord(
            op: .photoUpsert,
            id: segmentPhoto.id,
            hlc: 20,
            by: "writer-a",
            photo: SharedPhoto(photo: segmentPhoto, serverID: serverID)
        )
        let validRaw = try MetadataSegmentCodec.encode([segmentRecord])
        var malformedRaw = validRaw
        malformedRaw.append(Data("{not valid json}\n".utf8))
        let malformedData = try Gzip.compress(malformedRaw)
        let segmentKey = MetadataLayout.segmentKey(
            writer: "writer-a",
            sequence: 1,
            hlc: segmentRecord.hlc,
            digest: SigV4Signer.sha256Hex(malformedData)
        )
        let store = InMemoryMetadataStore()
        await store.seed(MetadataLayout.headKey, try JSONFile.encoder().encode(head))
        await store.seed(snapshotKey, snapshotData)
        await store.seed(segmentKey, malformedData)

        do {
            _ = try await reader.sync(store: store)
            XCTFail("A malformed pending segment must abort the cold sync")
        } catch MetadataError.invalidSegment {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(reader.state.isEmpty)
        XCTAssertNil(reader.replication.snapshotKey)
        XCTAssertNil(reader.replication.watermark["writer-a"])

        await store.seed(segmentKey, try Gzip.compress(validRaw))
        let retry = try await reader.sync(store: store)

        XCTAssertTrue(retry.isFull)
        XCTAssertEqual(
            Set(retry.photos.map(\.id)),
            ["remote:asset:snapshot", "remote:asset:segment"]
        )
        XCTAssertEqual(reader.state.photos.count, 2)
        XCTAssertEqual(reader.replication.watermark["writer-a"], 1)
    }

    func testMalformedOutboxLinePreservesValidPendingRecords() throws {
        let serverID = newServerID()
        let first = photo(id: "asset:first", serverID: serverID)
        let second = photo(id: "asset:second", serverID: serverID)
        let firstRecord = MetaRecord(
            op: .photoUpsert,
            id: first.id,
            hlc: 10,
            by: "writer-a",
            photo: SharedPhoto(photo: first, serverID: serverID)
        )
        let secondRecord = MetaRecord(
            op: .photoUpsert,
            id: second.id,
            hlc: 11,
            by: "writer-a",
            photo: SharedPhoto(photo: second, serverID: serverID)
        )
        var raw = try MetadataSegmentCodec.encode([firstRecord])
        raw.append(Data("{not valid json}\n".utf8))
        raw.append(try MetadataSegmentCodec.encode([secondRecord]))
        try raw.write(to: AppPaths.metadataOutboxFile(serverID), options: .atomic)

        let service = MetadataService(serverID: serverID, writerID: "writer-a")

        XCTAssertEqual(service.outbox.map(\.id), [first.id, second.id])
    }

    func testLegacyHashDeduplicationPreservesRemoteTags() {
        let store = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        let local = photo(
            id: "asset:local",
            serverID: serverID,
            sha256: "same",
            local: true,
            tags: ["local"]
        )
        store.mergeScanned([local])
        let remote = photo(
            id: "remote:twin",
            serverID: serverID,
            sha256: "same",
            tags: ["remote"]
        )

        XCTAssertEqual(store.importRemotePhotos([remote]), 0)

        XCTAssertEqual(Set(store.photo(id: local.id)?.tags ?? []), ["local", "remote"])
    }

    func testRemoteTwinTagsSurviveLocalUpload() {
        let store = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        var local = photo(
            id: "asset:local",
            serverID: serverID,
            sha256: "same",
            local: true
        )
        local.copies = []
        local.sha256 = nil
        store.mergeScanned([local])
        let remote = photo(
            id: "remote:twin",
            serverID: serverID,
            sha256: "same",
            tags: ["remote"]
        )
        XCTAssertEqual(store.importRemotePhotos([remote]), 1)

        store.recordUpload(
            copy: copy(serverID: serverID, objectKey: "Backu/Photos/local.jpg", sha256: "same"),
            for: local.id
        )

        XCTAssertEqual(store.photos.count, 1)
        XCTAssertEqual(store.photo(id: local.id)?.tags, ["remote"])
    }

    func testHashFoldedRemoteCopyInvalidatesSearchIndex() {
        let store = CatalogStore(loadFromDisk: false)
        let serverID = UUID()
        var local = photo(id: "asset:local", serverID: serverID, sha256: "same", local: true)
        local.copies = []
        store.mergeScanned([local])
        let versionBeforeImport = store.version
        XCTAssertTrue(store.search(SearchQuery(serverID: serverID)).isEmpty)
        let remote = photo(id: "remote:twin", serverID: serverID, sha256: "same")

        XCTAssertEqual(store.importRemotePhotos([remote]), 0)

        XCTAssertEqual(store.photo(id: local.id)?.copies.count, 1)
        XCTAssertEqual(store.version, versionBeforeImport + 1)
        XCTAssertEqual(Set(store.search(SearchQuery(serverID: serverID)).map(\.id)), [local.id])
    }

    func testZeroExposureIsOmittedInsteadOfCrashing() {
        var metadata = PhotoMetadata()
        metadata.exposureTime = 0

        XCTAssertNil(metadata.exposureDescription)
    }
}
