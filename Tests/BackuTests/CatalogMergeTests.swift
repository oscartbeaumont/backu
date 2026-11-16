import XCTest

@MainActor
final class CatalogMergeTests: XCTestCase {
    private func photo(id: String, filename: String = "IMG.jpg", local: Bool = true) -> PhotoItem {
        PhotoItem(
            id: id,
            localIdentifier: local ? id.replacingOccurrences(of: "asset:", with: "") : nil,
            filename: filename,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 100,
            pixelHeight: 100
        )
    }

    func testRescanReAdoptsAnAssetThatWasTemporarilyMissing() {
        let store = CatalogStore(loadFromDisk: false)
        var original = photo(id: "asset:1")
        original.copies = [
            PhotoCopy(
                serverID: UUID(),
                objectKey: "Backu/Photos/2023/11/IMG.jpg",
                sidecarKey: "Backu/Photos/2023/11/IMG.jpg.json",
                thumbnailKey: nil,
                uploadedAt: Date(),
                byteCount: 1,
                etag: nil,
                sha256: "abc"
            )
        ]
        store.mergeScanned([original])

        // A scan with videos disabled, or limited access, misses the asset.
        store.mergeScanned([photo(id: "asset:2")], removingMissing: true)
        XCTAssertEqual(store.photo(id: "asset:1")?.localIdentifier, nil, "Demoted to remote-only")

        // Turning the setting back on must give the asset its library link back.
        store.mergeScanned([photo(id: "asset:1")])
        XCTAssertEqual(store.photo(id: "asset:1")?.localIdentifier, "1")
    }

    func testLimitedAccessDoesNotDeleteUnseenPhotos() {
        let store = CatalogStore(loadFromDisk: false)
        store.mergeScanned([photo(id: "asset:1"), photo(id: "asset:2")])
        store.addTag("keep", to: "asset:2")

        // Limited access returns only asset 1; nothing may be removed.
        store.mergeScanned([photo(id: "asset:1")], removingMissing: false)
        XCTAssertNotNil(store.photo(id: "asset:2"))
        XCTAssertEqual(store.photo(id: "asset:2")?.tags, ["keep"])
    }

    func testFavoritesSurviveARescan() {
        let store = CatalogStore(loadFromDisk: false)
        store.mergeScanned([photo(id: "asset:1")])
        store.setFavorite("asset:1", isFavorite: true)
        store.mergeScanned([photo(id: "asset:1")])
        XCTAssertEqual(store.photo(id: "asset:1")?.isFavorite, true)
    }

    func testRemoteIndexToleratesDuplicatePeople() throws {
        let person = UUID()
        let document = RemoteIndexDocument(
            updatedAt: Date(),
            device: "test",
            people: [
                .init(id: person, name: "Ada", isPet: false, faceCount: 1, coverThumbnail: nil),
                .init(id: person, name: "Ada again", isPet: false, faceCount: 1, coverThumbnail: nil)
            ],
            photos: [
                .init(
                    id: "x",
                    key: "Backu/a.jpg",
                    sidecarKey: "Backu/a.jpg.json",
                    thumbnailKey: nil,
                    sha256: "abc",
                    filename: "a.jpg",
                    capturedAt: Date(),
                    width: 10,
                    height: 10,
                    isVideo: false,
                    duration: nil,
                    favorite: false,
                    tags: [],
                    personIDs: [person],
                    camera: nil,
                    lens: nil,
                    place: nil,
                    latitude: nil,
                    longitude: nil,
                    uti: nil,
                    byteCount: 1,
                    faces: [.init(id: UUID(), personID: person, kind: "person", x: 0.2, y: 0.2, width: 0.2, height: 0.2)]
                )
            ]
        )
        XCTAssertNoThrow(document.photoItems(serverID: UUID()))
        XCTAssertEqual(document.photoItems(serverID: UUID()).first?.faces.count, 1)
    }

    func testCanonicalURIKeepsTrailingSlash() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/bucket/folder/"))
        XCTAssertEqual(SigV4Signer.canonicalURI(for: url), "/bucket/folder/")
    }

    func testHostileFilenamesCannotEscapeThePrefix() {
        for name in ["../../etc/passwd", "a/b/c.jpg", "..", "evil%2F..%2Fx.jpg"] {
            let item = PhotoItem(id: "x", filename: name, takenAt: Date())
            let relative = BackupEngine.objectRelativeKey(for: item, in: ServerConfig(name: "t", provider: .custom, endpoint: "https://e.com", region: "us-east-1", bucket: "b", accessKeyID: "k"))
            XCTAssertFalse(relative.contains(".."))
            XCTAssertEqual(relative.split(separator: "/").count, 4, "Unexpected key: \(relative)")
        }
    }
}
