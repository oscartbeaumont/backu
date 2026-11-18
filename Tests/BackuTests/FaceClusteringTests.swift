import XCTest

@MainActor
final class FaceClusteringTests: XCTestCase {
    private func face(personID: UUID, embedding: Int) -> PhotoFace {
        PhotoFace(
            personID: personID,
            rect: NormRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            embeddingIndex: embedding
        )
    }

    func testSimilarUnnamedPeopleAreMerged() async throws {
        let catalog = CatalogStore(loadFromDisk: false)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-face-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = FaceEmbeddingStore(url: storeURL)

        let a = await store.append([1, 0.05, 0.1, 0])
        let b = await store.append([1, 0.06, 0.09, 0])
        let c = await store.append([9, 8, 7, 6])
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertGreaterThanOrEqual(b, 0)
        XCTAssertGreaterThanOrEqual(c, 0)

        let first = catalog.createPerson(coverPhotoID: "p1")
        let second = catalog.createPerson(coverPhotoID: "p2")
        let unrelated = catalog.createPerson(coverPhotoID: "p3")
        catalog.mergeScanned([
            PhotoItem(
                id: "p1",
                filename: "a.jpg",
                faces: [face(personID: first.id, embedding: a)],
                analyzedAt: Date()
            ),
            PhotoItem(
                id: "p2",
                filename: "b.jpg",
                faces: [face(personID: second.id, embedding: b)],
                analyzedAt: Date()
            ),
            PhotoItem(
                id: "p3",
                filename: "c.jpg",
                faces: [face(personID: unrelated.id, embedding: c)],
                analyzedAt: Date()
            )
        ], removingMissing: false)

        let merged = await FaceClusterer().mergeSimilarPeople(catalog: catalog, store: store)
        XCTAssertEqual(merged, 1, "The two similar unnamed people should merge")
        XCTAssertEqual(catalog.people.count, 2, "The unrelated person must stay separate")
        let photosAcrossPeople = catalog.people.reduce(0) { $0 + catalog.photos(of: $1.id).count }
        XCTAssertEqual(photosAcrossPeople, 3, "No photo should be lost when people merge")
    }
}
