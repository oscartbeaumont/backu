import Foundation
import XCTest

// MARK: - Helpers

private func makePhoto(
    id: String,
    sha: String = "sha-1",
    serverID: UUID,
    favorite: Bool = false,
    tags: [String] = []
) -> PhotoItem {
    PhotoItem(
        id: id,
        localIdentifier: nil,
        filename: "IMG.jpg",
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
                sha256: sha,
                atlasGroup: "group-\(id)",
                atlasCell: 1
            )
        ],
        sha256: sha
    )
}

private func shared(_ photo: PhotoItem, serverID: UUID) -> SharedPhoto {
    SharedPhoto(photo: photo, serverID: serverID)
}

private func makeRecord(
    _ op: MetaOperation,
    id: String,
    hlc: Int64,
    by: String,
    photo: SharedPhoto? = nil,
    changed: [String]? = nil,
    tagsAdd: [String]? = nil,
    tagsRemove: [String]? = nil,
    facesSet: [SharedFace]? = nil,
    facesDelete: [UUID]? = nil,
    person: SharedPerson? = nil,
    sha256: String? = nil
) -> MetaRecord {
    MetaRecord(
        op: op,
        id: id,
        hlc: hlc,
        by: by,
        photo: photo,
        changed: changed,
        tagsAdd: tagsAdd,
        tagsRemove: tagsRemove,
        facesSet: facesSet,
        facesDelete: facesDelete,
        person: person,
        sha256: sha256
    )
}

final class MetadataFormatTests: XCTestCase {
    func testGzipRoundTrips() throws {
        for size in [0, 1, 4_096, 1_000_000] {
            var data = Data(count: size)
            for index in stride(from: 0, to: size, by: 7) {
                data[index] = UInt8(truncatingIfNeeded: index &* 31)
            }
            let compressed = try Gzip.compress(data)
            if size > 0 {
                XCTAssertEqual(compressed.prefix(3), Data([0x1f, 0x8b, 0x08]))
                XCTAssertLessThan(compressed.count, data.count + 64)
            }
            XCTAssertEqual(try Gzip.decompress(compressed), data)
        }
    }

    func testHybridClockPackAndOrder() {
        let first = HybridClock.pack(milliseconds: 1_000, counter: 3)
        let second = HybridClock.pack(milliseconds: 1_000, counter: 4)
        let later = HybridClock.pack(milliseconds: 1_001, counter: 0)
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, later)
        let unpacked = HybridClock.unpack(second)
        XCTAssertEqual(unpacked.milliseconds, 1_000)
        XCTAssertEqual(unpacked.counter, 4)
    }

    func testSegmentCodecRoundTrips() throws {
        let server = UUID()
        let photo = makePhoto(id: "p1", serverID: server)
        let records = [
            makeRecord(.photoUpsert, id: "p1", hlc: 1, by: "a", photo: shared(photo, serverID: server), tagsAdd: ["beach"]),
            makeRecord(.personDelete, id: UUID().uuidString, hlc: 2, by: "a")
        ]
        let encoded = try MetadataSegmentCodec.encode(records)
        let decoded = try MetadataSegmentCodec.decode(encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].photo?.id, "p1")
        XCTAssertEqual(decoded[1].op, .personDelete)
    }
}

final class MetadataMergeTests: XCTestCase {
    private let serverID = UUID()

    func testCanonicalFaceIDsAreSharedAcrossDevices() {
        let rect = NormRect(x: 0.12, y: 0.34, width: 0.21, height: 0.18)
        let local = FaceIdentity.canonical(photoID: "asset:ABC", kind: .person, rect: rect)
        let remote = FaceIdentity.canonical(photoID: "remote:asset:ABC", kind: .person, rect: rect)
        XCTAssertEqual(local, remote)
        XCTAssertNotEqual(
            local,
            FaceIdentity.canonical(
                photoID: "asset:ABC",
                kind: .person,
                rect: NormRect(x: 0.13, y: 0.34, width: 0.21, height: 0.18)
            )
        )
        XCTAssertNotEqual(
            local,
            FaceIdentity.canonical(photoID: "asset:XYZ", kind: .person, rect: rect)
        )
    }

    func testDuplicateSHAEntitiesMergeIntoOnePhoto() {
        let base = makePhoto(id: "asset:A", sha: "same", serverID: serverID)
        var other = base
        other.id = "asset:B"
        other.tags = ["desktop"]
        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "asset:A", hlc: 10, by: "a", photo: shared(base, serverID: serverID), tagsAdd: ["phone"]),
            makeRecord(.photoUpsert, id: "asset:B", hlc: 11, by: "b", photo: shared(other, serverID: serverID), tagsAdd: ["desktop"])
        ])
        let materialized = state.materialize(serverID: serverID)
        XCTAssertEqual(materialized.photos.count, 1)
        XCTAssertEqual(Set(materialized.photos[0].tags), ["phone", "desktop"])
    }

    func testDelayedOlderAddCannotLowerATagVersion() {
        let base = makePhoto(id: "p1", serverID: serverID)
        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID))
        ])
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 30, by: "a", photo: shared(base, serverID: serverID), tagsAdd: ["beach"]))
        // Arrives late from another writer, older than the applied add.
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 25, by: "b", photo: shared(base, serverID: serverID), tagsAdd: ["beach"]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 27, by: "b", photo: shared(base, serverID: serverID), tagsRemove: ["beach"]))
        XCTAssertEqual(state.photos["p1"]?.tags.keys.sorted(), ["beach"])
    }

    func testFaceMovesUpdateDerivedCountsIncrementally() {
        let base = makePhoto(id: "p1", serverID: serverID)
        let person = SharedPerson(person: Person(name: "Ada"))
        let faceA = SharedFace(
            face: PhotoFace(personID: person.id, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        )
        let faceB = SharedFace(
            face: PhotoFace(personID: person.id, rect: NormRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        )

        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID)),
            makeRecord(.personUpsert, id: person.id.uuidString, hlc: 11, by: "a", person: person)
        ])
        var changes = state.apply([
            makeRecord(.photoPatch, id: "p1", hlc: 20, by: "a", photo: shared(base, serverID: serverID), facesSet: [faceA, faceB])
        ])
        XCTAssertTrue(changes.changedPeople.contains(person.id.uuidString))
        var incremental = state.materialize(serverID: serverID, changes: changes)
        XCTAssertEqual(incremental.people.first?.faceCount, 2)

        changes = state.apply([
            makeRecord(.photoPatch, id: "p1", hlc: 30, by: "b", photo: shared(base, serverID: serverID), facesDelete: [faceB.id])
        ])
        incremental = state.materialize(serverID: serverID, changes: changes)
        XCTAssertEqual(incremental.people.first?.faceCount, 1)

        changes = state.apply([makeRecord(.photoDelete, id: "p1", hlc: 40, by: "a")])
        incremental = state.materialize(serverID: serverID, changes: changes)
        XCTAssertEqual(incremental.people.first?.faceCount, 0)
    }

    func testIncrementalSyncMergesDuplicateSHAEntities() {
        let first = makePhoto(id: "asset:A", sha: "same", serverID: serverID)
        var second = first
        second.id = "asset:B"
        second.tags = ["desktop"]

        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "asset:A", hlc: 10, by: "a", photo: shared(first, serverID: serverID), tagsAdd: ["phone"]),
            makeRecord(.photoUpsert, id: "asset:B", hlc: 11, by: "b", photo: shared(second, serverID: serverID), tagsAdd: ["desktop"])
        ])
        let changes = state.apply([
            makeRecord(.photoPatch, id: "asset:A", hlc: 20, by: "a", photo: shared(first, serverID: serverID), tagsAdd: ["beach"])
        ])
        let incremental = state.materialize(serverID: serverID, changes: changes)
        XCTAssertEqual(incremental.photos.count, 1)
        XCTAssertEqual(Set(incremental.photos[0].tags), ["phone", "desktop", "beach"])
    }

    func testNewestFieldWinsRegardlessOfArrivalOrder() {
        let base = makePhoto(id: "p1", serverID: serverID)
        let older = makeRecord(
            .photoPatch, id: "p1", hlc: 100, by: "a",
            photo: shared(base, serverID: serverID), changed: ["isFavorite"]
        )
        var newestPhoto = base
        newestPhoto.isFavorite = true
        let newest = makeRecord(
            .photoPatch, id: "p1", hlc: 200, by: "b",
            photo: shared(newestPhoto, serverID: serverID), changed: ["isFavorite"]
        )

        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "p1", hlc: 50, by: "a", photo: shared(base, serverID: serverID))
        ])
        state.apply(newest)
        state.apply(older) // delayed upload from the other device
        XCTAssertEqual(state.photos["p1"]?.photo.isFavorite, true)
    }

    func testConcurrentTagAddsBothSurviveAndOlderAddCannotResurrectARemove() {
        let base = makePhoto(id: "p1", serverID: serverID)
        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID))
        ])
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 20, by: "a", photo: shared(base, serverID: serverID), tagsAdd: ["beach"]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 21, by: "b", photo: shared(base, serverID: serverID), tagsAdd: ["sunset"]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 30, by: "a", photo: shared(base, serverID: serverID), tagsRemove: ["beach"]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 25, by: "b", photo: shared(base, serverID: serverID), tagsAdd: ["beach"]))

        let materialized = state.materialize(serverID: serverID).photos.first
        XCTAssertEqual(Set(materialized?.tags ?? []), ["sunset"])
    }

    func testFacesAreASetWithPerFaceLastWriter() throws {
        let base = makePhoto(id: "p1", serverID: serverID)
        let faceID = UUID()
        let personID = UUID()
        let first = SharedFace(
            face: PhotoFace(id: faceID, personID: nil, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        )
        var assigned = first
        assigned.personID = personID
        let otherFace = SharedFace(
            face: PhotoFace(rect: NormRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        )

        var state = MergedMetadata()
        state.apply([makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID))])
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 20, by: "a", photo: shared(base, serverID: serverID), facesSet: [first, otherFace]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 30, by: "b", photo: shared(base, serverID: serverID), facesSet: [assigned]))

        let faces = try XCTUnwrap(state.photos["p1"]?.faces.values.compactMap(\.face))
        XCTAssertEqual(faces.count, 2)
        XCTAssertEqual(faces.first { $0.id == faceID }?.personID, personID)

        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 40, by: "a", photo: shared(base, serverID: serverID), facesDelete: [otherFace.id]))
        let afterDelete = state.photos["p1"]?.faces.values.compactMap(\.face) ?? []
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertEqual(afterDelete.first?.id, faceID)
    }

    func testDeleteTombstoneBeatsAnOlderEditButNotANewerOne() {
        let base = makePhoto(id: "p1", serverID: serverID)
        var state = MergedMetadata()
        state.apply([makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID))])
        state.apply(makeRecord(.photoDelete, id: "p1", hlc: 30, by: "a"))
        state.apply(
            makeRecord(.photoPatch, id: "p1", hlc: 20, by: "b", photo: shared(base, serverID: serverID), changed: ["isFavorite"])
        )
        XCTAssertNil(state.photos["p1"])

        state.apply(
            makeRecord(.photoUpsert, id: "p1", hlc: 40, by: "b", photo: shared(base, serverID: serverID))
        )
        XCTAssertNotNil(state.photos["p1"])
    }

    func testSnapshotRoundTripPreservesVersionsTagsAndFaces() throws {
        let base = makePhoto(id: "p1", serverID: serverID)
        let person = SharedPerson(person: Person(name: "Ada"))
        let face = SharedFace(face: PhotoFace(personID: person.id, rect: NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))

        var state = MergedMetadata()
        state.apply([
            makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID), tagsAdd: ["beach"], facesSet: [face]),
            makeRecord(.personUpsert, id: person.id.uuidString, hlc: 11, by: "a", person: person),
            makeRecord(.photoDelete, id: "gone", hlc: 12, by: "a"),
            makeRecord(.deletedHash, id: "sha-x", hlc: 13, by: "a", sha256: "deadbeef")
        ])

        let raw = state.encodeSnapshot(generation: 3, watermark: ["a": 4])
        let decoded = try MergedMetadata.decodeSnapshot(raw)

        XCTAssertEqual(decoded.header.generation, 3)
        XCTAssertEqual(decoded.header.watermark["a"], 4)
        XCTAssertEqual(decoded.metadata.photos["p1"]?.tags.keys.sorted(), ["beach"])
        XCTAssertEqual(decoded.metadata.people[person.id.uuidString]?.person.name, "Ada")
        XCTAssertNotNil(decoded.metadata.photoTombstones["gone"])
        XCTAssertNotNil(decoded.metadata.deletedHashes["deadbeef"])

        let materialized = decoded.metadata.materialize(serverID: serverID)
        XCTAssertEqual(materialized.photos.first?.id, "remote:p1")
        XCTAssertEqual(materialized.photos.first?.faces.first?.personID, person.id)
        XCTAssertEqual(materialized.people.first?.name, "Ada")
    }

    func testFieldsFromDifferentWritersMergeInsteadOfReplacingTheRecord() {
        let base = makePhoto(id: "p1", serverID: serverID)
        var renamed = base
        renamed.filename = "Renamed.jpg"
        var tagged = base
        tagged.isFavorite = true

        var state = MergedMetadata()
        state.apply([makeRecord(.photoUpsert, id: "p1", hlc: 10, by: "a", photo: shared(base, serverID: serverID))])
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 20, by: "a", photo: shared(renamed, serverID: serverID), changed: ["filename"]))
        state.apply(makeRecord(.photoPatch, id: "p1", hlc: 21, by: "b", photo: shared(tagged, serverID: serverID), changed: ["isFavorite"]))

        XCTAssertEqual(state.photos["p1"]?.photo.filename, "Renamed.jpg")
        XCTAssertEqual(state.photos["p1"]?.photo.isFavorite, true)
    }
}

// MARK: - Replication against the mock bucket

@MainActor
final class MetadataReplicationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9000")!
    private let bucket = "backu-test"
    private var serverID = UUID()
    private var prefix = ""

    private func requireServer() async throws {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1.5
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: config)
        do {
            _ = try await session.data(for: request)
        } catch {
            throw XCTSkip("Mock S3 is not running on \(endpoint) — start Tools/MockS3/mock_s3.py")
        }
    }

    private func makeServer() -> ServerConfig {
        ServerConfig(
            name: "Mock",
            provider: .custom,
            endpoint: endpoint.absoluteString,
            region: "us-east-1",
            bucket: bucket,
            accessKeyID: "testkey",
            prefix: prefix,
            pathStyle: true
        )
    }

    private func makeClient() -> S3Client {
        S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
        )
    }

    override func setUp() async throws {
        prefix = "MetaTests-\(UUID().uuidString.prefix(8))"
        serverID = UUID()
    }

    private func cleanup(_ ids: [UUID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: AppPaths.metadataStateFile(id))
            try? FileManager.default.removeItem(at: AppPaths.metadataCacheFile(id))
            try? FileManager.default.removeItem(at: AppPaths.metadataOutboxFile(id))
        }
    }

    func testTwoWritersMergeWithoutTouchingTheSameObject() async throws {
        try await requireServer()
        let server = makeServer()
        let client = makeClient()
        let store = S3MetadataStore(client: client, prefix: server.normalizedPrefix)
        let aID = UUID()
        let bID = UUID()
        defer { cleanup([aID, bID]) }

        let catalogA = CatalogStore(loadFromDisk: false)
        let photoA = makePhoto(id: "asset:A", sha: "sha-a", serverID: aID)
        catalogA.mergeScanned([photoA])
        catalogA.setFavorite(photoA.id, isFavorite: true)

        let serviceA = MetadataService(serverID: aID, writerID: "writer-a")
        serviceA.configure(catalog: catalogA)
        let deltaA = catalogA.takeMetadataDelta()
        _ = serviceA.recordLocalChanges(delta: deltaA, catalog: catalogA)
        try await serviceA.flush(store: store)

        let catalogB = CatalogStore(loadFromDisk: false)
        let serviceB = MetadataService(serverID: bID, writerID: "writer-b")
        serviceB.configure(catalog: catalogB)
        let firstSync = try await serviceB.sync(store: store)
        XCTAssertTrue(firstSync.hasHead == false)
        XCTAssertTrue(firstSync.sawLog)
        XCTAssertEqual(firstSync.photos.first?.id, "remote:asset:A")
        catalogB.mergePersonRecords(firstSync.people)
        XCTAssertEqual(catalogB.importRemotePhotos(firstSync.photos), 1)

        // Device B edits a different field of the same photo.
        let importedID = try XCTUnwrap(catalogB.photos.first?.id)
        catalogB.addTag("sunset", to: importedID)
        let deltaB = catalogB.takeMetadataDelta()
        _ = serviceB.recordLocalChanges(delta: deltaB, catalog: catalogB)
        try await serviceB.flush(store: store)

        let secondSync = try await serviceA.sync(store: store)
        XCTAssertTrue(secondSync.changed)
        XCTAssertEqual(secondSync.photos.first?.isFavorite, true)
        XCTAssertEqual(secondSync.photos.first?.tags, ["sunset"])
        XCTAssertEqual(secondSync.photos.first?.copies.first?.atlasGroup, "group-asset:A")

        // Nothing new: the head is absent and the segments are unchanged, so a
        // third sync still works but does not duplicate anything.
        let thirdSync = try await serviceA.sync(store: store)
        XCTAssertFalse(thirdSync.changed)
    }

    func testCompactionLetsAFreshDeviceStartFromOneSnapshot() async throws {
        try await requireServer()
        let server = makeServer()
        let client = makeClient()
        let store = S3MetadataStore(client: client, prefix: server.normalizedPrefix)
        let aID = UUID()
        let bID = UUID()
        defer { cleanup([aID, bID]) }

        let catalogA = CatalogStore(loadFromDisk: false)
        var photos: [PhotoItem] = []
        for index in 0..<20 {
            photos.append(makePhoto(id: "asset:\(index)", sha: "sha-\(index)", serverID: aID))
        }
        catalogA.mergeScanned(photos)
        catalogA.setFavorite("asset:0", isFavorite: true)

        let serviceA = MetadataService(serverID: aID, writerID: "writer-a")
        serviceA.configure(catalog: catalogA)
        _ = serviceA.recordLocalChanges(delta: catalogA.takeMetadataDelta(), catalog: catalogA)
        try await serviceA.flush(store: store)

        // Pull our own segments into local state before compacting: a snapshot
        // must never be built from a state that is missing its own writes.
        _ = try await serviceA.sync(store: store)
        await serviceA.compactIfNeeded(store: store, force: true)

        let serviceB = MetadataService(serverID: bID, writerID: "writer-b")
        let fresh = try await serviceB.sync(store: store)
        XCTAssertTrue(fresh.changed)
        XCTAssertEqual(fresh.photos.count, 20)
        XCTAssertEqual(fresh.photos.first { $0.id == "remote:asset:0" }?.isFavorite, true)

        // The snapshot is now what a fresh device reads; no per-segment replay
        // is needed. This is the exact property that keeps cold start bounded.
        let headData = try await client.getObject(
            key: S3Client.join(server.normalizedPrefix, MetadataLayout.headKey)
        )
        let head = try JSONFile.decoder.decode(MetadataHead.self, from: headData)
        XCTAssertNotNil(head.snapshot)
        XCTAssertEqual(head.watermark["writer-a"], 0)
    }

    func testDeletedHashTombstoneSurvivesSnapshot() async throws {
        try await requireServer()
        let server = makeServer()
        let client = makeClient()
        let store = S3MetadataStore(client: client, prefix: server.normalizedPrefix)
        let aID = UUID()
        let bID = UUID()
        defer { cleanup([aID, bID]) }

        let catalogA = CatalogStore(loadFromDisk: false)
        let photo = makePhoto(id: "asset:x", sha: "sha-x", serverID: aID)
        catalogA.mergeScanned([photo])
        catalogA.removePhotos([photo.id])

        let serviceA = MetadataService(serverID: aID, writerID: "writer-a")
        serviceA.configure(catalog: catalogA)
        _ = serviceA.recordLocalChanges(delta: catalogA.takeMetadataDelta(), catalog: catalogA)
        try await serviceA.flush(store: store)
        _ = try await serviceA.sync(store: store)
        await serviceA.compactIfNeeded(store: store, force: true)

        let serviceB = MetadataService(serverID: bID, writerID: "writer-b")
        let outcome = try await serviceB.sync(store: store)
        XCTAssertTrue(outcome.deletedHashes.contains("sha-x"))
        XCTAssertTrue(outcome.photos.isEmpty)
    }
}
