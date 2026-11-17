import XCTest

@MainActor
final class UploadJournalTests: XCTestCase {
    func testJournalRoundTripAndStalePurge() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let journal = UploadJournal(fileURL: url, now: { now })
        let server = UUID()

        journal.begin(
            UploadRecord(
                photoID: "asset:1",
                serverID: server,
                objectKey: "Backu/a.jpg",
                sidecarKey: "Backu/a.jpg.json",
                byteCount: 10,
                sha256: nil,
                startedAt: now
            )
        )
        XCTAssertEqual(journal.pending(serverID: server).count, 1)

        let reloaded = UploadJournal(fileURL: url, now: { now })
        XCTAssertEqual(reloaded.pending(serverID: server).first?.objectKey, "Backu/a.jpg")

        reloaded.finish(photoID: "asset:1", serverID: server)
        XCTAssertTrue(reloaded.pending(serverID: server).isEmpty)

        journal.begin(
            UploadRecord(
                photoID: "asset:2",
                serverID: server,
                objectKey: "Backu/b.jpg",
                sidecarKey: "Backu/b.jpg.json",
                byteCount: 10,
                sha256: nil,
                startedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
            )
        )
        XCTAssertEqual(journal.purgeStale(), 1)
        XCTAssertTrue(journal.pending(serverID: server).isEmpty)
    }

    func testReconcilerRestoresACompletedUploadWithoutTransfer() async throws {
        guard await mockIsReachable() else {
            throw XCTSkip("Mock S3 is not running on 127.0.0.1:9000")
        }
        let catalog = CatalogStore(loadFromDisk: false)
        let photo = PhotoItem(
            id: "asset:journal-\(UUID().uuidString)",
            localIdentifier: "journal",
            filename: "Journal.jpg",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 100,
            pixelHeight: 100,
            metadata: PhotoMetadata()
        )
        catalog.mergeScanned([photo])

        let server = ServerConfig(
            name: "Mock",
            provider: .custom,
            endpoint: "http://127.0.0.1:9000",
            region: "us-east-1",
            bucket: "backu-test",
            accessKeyID: "testkey",
            prefix: "Backu",
            pathStyle: true
        )
        let client = S3Client(
            connection: server.connection,
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
        )
        let key = BackupEngine.objectKey(for: photo, in: server)
        let sidecarKey = key + ".json"
        let body = Data("already uploaded".utf8)
        let sidecar = SidecarDocument.make(
            photo: photo,
            people: [:],
            device: "test",
            sha256: "journal-hash"
        )
        try await client.putObject(key: key, data: body, contentType: "image/jpeg")
        try await client.putObject(key: sidecarKey, data: try sidecar.data(), contentType: "application/json")
        defer {
            Task {
                try? await client.deleteObject(key: key)
                try? await client.deleteObject(key: sidecarKey)
            }
        }

        let journalURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = UploadJournal(fileURL: journalURL)
        journal.begin(
            UploadRecord(
                photoID: photo.id,
                serverID: server.id,
                objectKey: key,
                sidecarKey: sidecarKey,
                byteCount: Int64(body.count),
                sha256: nil,
                startedAt: Date()
            )
        )

        let recovered = await UploadReconciler.reconcile(
            server: server,
            client: client,
            catalog: catalog,
            journal: journal
        )
        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(journal.pending(serverID: server.id).isEmpty)
        let copy = try XCTUnwrap(catalog.photo(id: photo.id)?.copy(on: server.id))
        XCTAssertEqual(copy.objectKey, key)
        XCTAssertEqual(copy.sha256, "journal-hash")
        XCTAssertEqual(copy.byteCount, Int64(body.count))
    }

    private func mockIsReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9000/")!)
        request.timeoutInterval = 1.5
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 1.5
        do {
            _ = try await URLSession(configuration: config).data(for: request)
            return true
        } catch {
            return false
        }
    }
}
