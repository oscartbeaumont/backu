import XCTest

@MainActor
final class AuditSecondaryUIUnitRegressionTests: XCTestCase {
    func testMergeIntoRemovedTargetDoesNotDeleteSourceOrOrphanFaces() {
        let catalog = CatalogStore(loadFromDisk: false)
        let source = catalog.createPerson(name: "Source")
        let target = catalog.createPerson(name: "Target")
        let face = PhotoFace(personID: source.id, rect: NormRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        catalog.mergeScanned([
            PhotoItem(id: "asset:merge-race", filename: "merge-race.jpg", faces: [face])
        ], removingMissing: false)

        // A remote metadata sync can remove the target after the merge sheet
        // captured its id but before the person confirms the merge.
        catalog.deletePerson(target.id)
        catalog.mergePeople(source.id, into: target.id)

        XCTAssertNotNil(catalog.person(id: source.id), "A stale target must not consume the source person")
        XCTAssertEqual(
            catalog.photo(id: "asset:merge-race")?.faces.first?.personID,
            source.id,
            "A rejected merge must leave the face attached to the surviving source"
        )
        XCTAssertNil(catalog.person(id: target.id))
    }

    func testDeletingTheLastLocalPhotoClearsThePersonFaceCount() {
        let catalog = CatalogStore(loadFromDisk: false)
        let person = catalog.createPerson(name: "Only photo")
        let face = PhotoFace(personID: person.id, rect: NormRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        catalog.mergeScanned([
            PhotoItem(id: "asset:only-photo", localIdentifier: "only-photo", filename: "only.jpg", faces: [face])
        ], removingMissing: false)

        catalog.removePhotos(["asset:only-photo"])

        XCTAssertTrue(catalog.photos(of: person.id).isEmpty)
        XCTAssertEqual(catalog.person(id: person.id)?.faceCount, 0, "Deleted photos must not leave a visible ghost person")
    }

    func testRemovingTheLastServerCopyClearsThePersonFaceCount() {
        let catalog = CatalogStore(loadFromDisk: false)
        let person = catalog.createPerson(name: "Remote only")
        let serverID = UUID()
        let face = PhotoFace(personID: person.id, rect: NormRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        let remote = PhotoItem(
            id: "remote:only-photo",
            filename: "remote.jpg",
            faces: [face],
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/remote.jpg",
                    sidecarKey: "Backu/remote.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "remote-hash"
                )
            ],
            serverID: serverID
        )
        XCTAssertEqual(catalog.importRemotePhotos([remote]), 1)

        catalog.removeServerCopies(serverID)

        XCTAssertNil(catalog.photo(id: remote.id))
        XCTAssertEqual(catalog.person(id: person.id)?.faceCount, 0, "Removing a bucket must not leave a visible ghost person")
    }

    func testRemoteMetadataRemovalClearsThePersonFaceCount() {
        let catalog = CatalogStore(loadFromDisk: false)
        let person = catalog.createPerson(name: "Removed remotely")
        let serverID = UUID()
        let face = PhotoFace(personID: person.id, rect: NormRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        let remote = PhotoItem(
            id: "remote:removed-photo",
            filename: "removed.jpg",
            faces: [face],
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/removed.jpg",
                    sidecarKey: "Backu/removed.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "removed-hash"
                )
            ],
            serverID: serverID
        )
        XCTAssertEqual(catalog.importRemotePhotos([remote]), 1)

        catalog.removeRemotePhotos(serverID: serverID, removedIDs: [remote.id], deletedHashes: [])

        XCTAssertNil(catalog.photo(id: remote.id))
        XCTAssertEqual(catalog.person(id: person.id)?.faceCount, 0, "Remote deletions must not leave a visible ghost person")
    }
}
