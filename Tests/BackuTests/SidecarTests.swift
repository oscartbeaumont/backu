import XCTest

final class SidecarTests: XCTestCase {
    private let samplePerson = Person(name: "Ada")

    private func samplePhoto() -> PhotoItem {
        var metadata = PhotoMetadata()
        metadata.cameraMake = "Apple"
        metadata.cameraModel = "iPhone 17 Pro"
        metadata.lensModel = "Main Camera 24mm f/1.78"
        metadata.iso = 64
        metadata.fNumber = 1.78
        metadata.exposureTime = 1.0 / 120
        metadata.focalLength = 24
        metadata.latitude = 51.5072
        metadata.longitude = -0.1276
        metadata.placeName = "London, England"

        let person = samplePerson
        return PhotoItem(
            id: "asset:ABC",
            localIdentifier: "ABC",
            filename: "IMG_0001.HEIC",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 4032,
            pixelHeight: 3024,
            tags: ["holiday", "london"],
            metadata: metadata,
            faces: [PhotoFace(personID: person.id, rect: NormRect(x: 0.2, y: 0.3, width: 0.1, height: 0.12))]
        )
    }

    func testSidecarRoundTrip() throws {
        let photo = samplePhoto()
        let doc = SidecarDocument.make(
            photo: photo,
            people: [samplePerson.id: samplePerson],
            device: "iPhone",
            sha256: "deadbeef"
        )
        let data = try doc.data()
        let decoded = try JSONFile.decoder.decode(SidecarDocument.self, from: data)

        XCTAssertEqual(decoded.id, photo.id)
        XCTAssertEqual(decoded.tags, ["holiday", "london"])
        XCTAssertEqual(decoded.people.first?.name, "Ada")
        XCTAssertEqual(decoded.location?.place, "London, England")
        XCTAssertEqual(decoded.camera.model, "iPhone 17 Pro")
        XCTAssertEqual(decoded.faces.count, 1)
        XCTAssertEqual(decoded.sha256, "deadbeef")
        XCTAssertEqual(decoded.schema, "backu.photo.v1")
    }

    func testRemoteIndexRoundTrip() throws {
        let photo = samplePhoto()
        let serverID = UUID()
        let copy = PhotoCopy(
            serverID: serverID,
            objectKey: "Backu/Photos/2023/11/IMG_0001-abcd1234.HEIC",
            sidecarKey: "Backu/Photos/2023/11/IMG_0001-abcd1234.HEIC.json",
            thumbnailKey: "Backu/.backu/thumbs/abcd.jpg",
            uploadedAt: Date(),
            byteCount: 1234,
            etag: nil,
            sha256: "abc"
        )
        var stored = photo
        stored.copies = [copy]
        stored.sha256 = "abc"

        let document = RemoteIndexDocument.make(
            photos: [stored],
            people: [Person(name: "Ada")],
            serverID: serverID,
            device: "iPhone"
        )
        let data = try JSONFile.encoder().encode(document)
        let decoded = try JSONFile.decoder.decode(RemoteIndexDocument.self, from: data)
        let items = decoded.photoItems(serverID: serverID)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.copy(on: serverID)?.objectKey, copy.objectKey)
        XCTAssertEqual(items.first?.tags, ["holiday", "london"])
        XCTAssertEqual(items.first?.metadata.latitude, 51.5072)
        XCTAssertEqual(items.first?.isRemoteOnly, true)
    }

    func testObjectKeyLayoutIsSafeAndStable() {
        let photo = samplePhoto()
        let server = ServerConfig(
            name: "Test",
            provider: .custom,
            endpoint: "http://127.0.0.1:9000",
            region: "us-east-1",
            bucket: "backu-test",
            accessKeyID: "testkey",
            prefix: "Backu",
            pathStyle: true
        )
        let relative = BackupEngine.objectRelativeKey(for: photo, in: server)
        XCTAssertTrue(relative.hasPrefix("Photos/2023/11/"))
        XCTAssertTrue(relative.hasSuffix(".heic"))
        XCTAssertEqual(relative.split(separator: "/").count, 4)
        XCTAssertFalse(relative.contains(" "))

        let key = BackupEngine.objectKey(for: photo, in: server)
        XCTAssertEqual(key, "Backu/" + relative)
        XCTAssertEqual(BackupEngine.sanitize("a/b:c?d"), "a-b-c-d")
        XCTAssertEqual(BackupEngine.fileExtension(for: photo), "heic")
    }

    func testVectorMath() {
        XCTAssertEqual(VectorMath.distance([0, 0], [3, 4]), 5, accuracy: 0.0001)
        let centroid = VectorMath.centroid([[0, 0], [2, 2]])
        XCTAssertEqual(centroid ?? [], [1, 1])
        XCTAssertEqual(VectorMath.distance([0], [1, 2]), .greatestFiniteMagnitude)
    }

    func testFaceEmbeddingStorePersistsVectors() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FaceEmbeddingStore(url: url)
        let first = await store.append([1, 2, 3])
        let second = await store.append([4, 5, 6])
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        await store.flush()
        let reloaded = FaceEmbeddingStore(url: url)
        let count = await reloaded.count
        XCTAssertEqual(count, 2)
        let vector = await reloaded.vector(at: 1)
        XCTAssertEqual(vector, [4, 5, 6])
    }
}
