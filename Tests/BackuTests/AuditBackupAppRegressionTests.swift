import CoreGraphics
import Foundation
import XCTest

/// Focused regressions for backup queue, replica, paging, and atlas state.
@MainActor
final class BackupIssueRegressionTests: XCTestCase {
    private static let isolationHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackuIssueRegressionTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try isolateHome()
        BackupIssueS3URLProtocol.reset()
        BackupIssueURLProtocol.setHandler(nil)
    }

    override func tearDownWithError() throws {
        BackupIssueS3URLProtocol.reset()
        BackupIssueURLProtocol.setHandler(nil)
        try super.tearDownWithError()
    }

    func testIssue46MetadataOnlyRunDoesNotCountOriginalBytesAsTransferred() async {
        let fixture = MetadataFixture(singleDestination: true)
        defer { fixture.stop() }

        let result = await fixture.run()
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(
            fixture.engine.transferredBytes,
            0,
            "A metadata-only run sends a sidecar, not the existing 5 MB original"
        )
    }

    func testIssue47FailedReplicaMetadataUpdateRemainsPendingForRetry() async {
        let fixture = MetadataFixture()
        defer { fixture.stop() }

        let first = await fixture.run()
        XCTAssertEqual(first.completedCount, 1)
        XCTAssertEqual(first.failedCount, 1)
        XCTAssertEqual(BackupIssueS3URLProtocol.putCount(bucket: "bucket-b"), 1)
        XCTAssertNotNil(
            fixture.catalog.photo(id: fixture.photoID)?.sidecarDirtyAt,
            "Replica A succeeding must not clear the pending sidecar update for replica B, which failed"
        )

        BackupIssueS3URLProtocol.failBucketB = false
        let retry = await fixture.run()
        XCTAssertGreaterThanOrEqual(retry.totalCount, 1, "Retry should still contain B's failed metadata update")
        XCTAssertEqual(retry.failedCount, 0)
        XCTAssertEqual(BackupIssueS3URLProtocol.putCount(bucket: "bucket-b"), 2, "Retry should write B's sidecar again")
        XCTAssertNil(fixture.catalog.photo(id: fixture.photoID)?.sidecarDirtyAt)
    }

    func testRemoteOnlySidecarClearsAfterDestinationsWithCandidateWorkComplete() async {
        let fixture = MetadataFixture(remoteOnlyCopyOnAOnly: true)
        defer { fixture.stop() }

        let result = await fixture.run()
        XCTAssertEqual(result.totalCount, 1, "Only the destination holding the remote-only copy has candidate work")
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(BackupIssueS3URLProtocol.putCount(bucket: "bucket-b"), 0)
        XCTAssertNil(
            fixture.catalog.photo(id: fixture.photoID)?.sidecarDirtyAt,
            "A successful sidecar write to every destination that had candidate work must clear the dirty flag"
        )
    }

    func testIssue60ModifiedLocalAssetIsRequeued() {
        let server = makeServer()
        let uploadedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let copy = PhotoCopy(
            serverID: server.id,
            objectKey: "Backu/Photos/2023/11/IMG_0001-old.jpg",
            sidecarKey: "Backu/Photos/2023/11/IMG_0001-old.jpg.json",
            uploadedAt: uploadedAt,
            byteCount: 3,
            sha256: "old-hash"
        )
        let photo = PhotoItem(
            id: "asset:modified-after-upload",
            localIdentifier: "modified-after-upload",
            filename: "IMG_0001.jpg",
            modifiedAt: uploadedAt.addingTimeInterval(60),
            copies: [copy],
            sha256: "old-hash"
        )
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned([photo], removingMissing: false)

        let candidates = BackupEngine().candidatesForBackup(
            catalog: catalog,
            server: server,
            force: false,
            limit: nil
        )

        XCTAssertEqual(
            candidates.map(\.id),
            [photo.id],
            "A local asset modified after its recorded upload must be queued again"
        )
    }

    func testIssue62LegacySidecarFallbackImportsMoreThanFiveHundredPhotos() async throws {
        let server = makeServer()
        let count = 501
        var objects: [(key: String, data: Data)] = []
        var xml = "<ListBucketResult><IsTruncated>false</IsTruncated>"
        for index in 0..<count {
            let photo = makePhoto(id: "asset:legacy-\(index)", filename: "IMG_\(index).jpg")
            let key = BackupEngine.objectKey(for: photo, in: server) + ".json"
            let data = try SidecarDocument.make(
                photo: photo,
                people: [:],
                device: "issue62",
                sha256: nil
            ).data()
            objects.append((key, data))
            xml += "<Contents><Key>\(key)</Key><Size>\(data.count)</Size></Contents>"
        }
        xml += "</ListBucketResult>"
        let listData = Data(xml.utf8)
        let sidecarObjects = objects
        BackupIssueURLProtocol.setHandler { request in
            if request.httpMethod == "GET",
               URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                   .queryItems?.contains(where: { $0.name == "list-type" }) == true {
                return (200, listData, ["Content-Type": "application/xml"])
            }
            let key = Self.objectKey(for: request)
            if let object = sidecarObjects.first(where: { $0.key == key }) {
                return (200, object.data, ["Content-Type": "application/json"])
            }
            return (404, Data(), [:])
        }
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }

        let result = try await RemoteLibrary.load(client: client, server: server)

        XCTAssertFalse(result.indexFound)
        XCTAssertEqual(result.photos.count, count)
        XCTAssertTrue(result.photos.contains { $0.id == "remote:asset:legacy-500" })
    }

    func testListAllObjectsFollowsContinuationPagesPastTwentyThousandObjects() async throws {
        let server = makeServer()
        let totalCount = 20_001
        stubObjectPages(totalCount: totalCount, pageSize: 1_000)
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }

        let objects = try await client.listAllObjects(prefix: "Backu/Photos/")

        XCTAssertEqual(objects.count, totalCount)
        XCTAssertEqual(objects.last?.key, "Backu/Photos/object-20000.jpg")
    }

    func testListAllObjectsSurfacesAnExplicitLimitWhenAnotherPageRemains() async throws {
        let server = makeServer()
        stubObjectPages(totalCount: 4, pageSize: 2)
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }

        do {
            _ = try await client.listAllObjects(prefix: "Backu/Photos/", limit: 2)
            XCTFail("A bounded listing must report truncation instead of returning a partial library")
        } catch let S3Error.listTruncated(limit) {
            XCTAssertEqual(limit, 2)
        } catch {
            XCTFail("Unexpected listing error: \(error)")
        }
    }

    func testIssue63FullAtlasBatchRecordsPointerForBoundaryPhoto() async throws {
        let server = makeServer()
        BackupIssueURLProtocol.setHandler { _ in (200, Data(), ["ETag": "\"sheet\""]) }
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }
        let catalog = CatalogStore(loadFromDisk: false)
        let photos = (0..<ThumbnailAtlas.groupCapacity).map { index in
            PhotoItem(
                id: "asset:atlas-\(index)",
                filename: "IMG_\(index).jpg",
                takenAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        catalog.mergeScanned(photos, removingMissing: false)
        let batch = AtlasBatch(server: server, client: client, catalog: catalog)
        let image = try solidImage()

        // BackupEngine records the upload copy after adding the tile. A full
        // batch must therefore flush only after those copies are available.
        for (index, photo) in photos.enumerated() {
            await batch.add(
                photoID: photo.id,
                digest: String(repeating: String(format: "%x", index % 16), count: 64),
                grid: image,
                preview: image
            )
            let key = BackupEngine.objectKey(for: photo, in: server)
            catalog.recordUpload(
                copy: PhotoCopy(
                    serverID: server.id,
                    objectKey: key,
                    sidecarKey: key + ".json",
                    uploadedAt: Date(),
                    byteCount: 1,
                    sha256: String(repeating: String(format: "%x", index % 16), count: 64)
                ),
                for: photo.id
            )
        }
        await batch.flush()

        XCTAssertEqual(batch.uploadedPhotos, ThumbnailAtlas.groupCapacity)
        let missingPointers = photos.filter {
            catalog.photo(id: $0.id)?.copy(on: server.id)?.atlasPointer == nil
        }
        XCTAssertEqual(missingPointers.map(\.id), [], "Every photo in a published atlas group needs its cell pointer")
    }

    // MARK: - Fixtures

    @MainActor
    private final class MetadataFixture {
        let photoID = "asset:issue-metadata-only"
        let catalog: CatalogStore
        let settings: AppSettings
        let engine = BackupEngine()
        let destinations: [BackupEngine.Destination]
        let faceStore: FaceEmbeddingStore
        let defaultsName: String
        let faceStoreURL: URL

        init(singleDestination: Bool = false, remoteOnlyCopyOnAOnly: Bool = false) {
            defaultsName = "BackupIssueRegressionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            settings = AppSettings(defaults: defaults)
            settings.atlasThumbnailsEnabled = false
            settings.faceRecognitionEnabled = false
            catalog = CatalogStore(loadFromDisk: false)
            faceStoreURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("backup-issue-faces-\(UUID().uuidString).bin")
            faceStore = FaceEmbeddingStore(url: faceStoreURL)

            let a = Self.server(id: UUID(), name: "A", bucket: "bucket-a", prefix: "A")
            let b = Self.server(id: UUID(), name: "B", bucket: "bucket-b", prefix: "B")
            let servers = singleDestination ? [a] : [a, b]
            destinations = servers.map {
                BackupEngine.Destination(server: $0, client: Self.client(server: $0))
            }

            var photo = PhotoItem(
                id: photoID,
                localIdentifier: remoteOnlyCopyOnAOnly ? nil : "issue-local-identifier",
                filename: "IMG_ISSUE.jpg",
                takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                pixelWidth: 100,
                pixelHeight: 100,
                serverID: remoteOnlyCopyOnAOnly ? a.id : nil
            )
            photo.metadata.fileSize = 5_000_000
            photo.copies = destinations.filter { destination in
                !remoteOnlyCopyOnAOnly || destination.server.id == a.id
            }.map { destination in
                PhotoCopy(
                    serverID: destination.server.id,
                    objectKey: "\(destination.server.normalizedPrefix)/Photos/IMG_ISSUE.jpg",
                    sidecarKey: "\(destination.server.normalizedPrefix)/Photos/IMG_ISSUE.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    byteCount: 5_000_000,
                    etag: nil,
                    sha256: "issue-sha"
                )
            }
            catalog.mergeScanned([photo], removingMissing: false)
            catalog.mutatePhoto(photoID) { $0.sidecarDirtyAt = Date() }
        }

        func run() async -> (completedCount: Int, failedCount: Int, totalCount: Int) {
            engine.start(
                destinations: destinations,
                catalog: catalog,
                settings: settings,
                faceStore: faceStore,
                trigger: .manual
            )
            await engine.awaitCompletion()
            return (engine.completedCount, engine.failedCount, engine.totalCount)
        }

        func stop() {
            for destination in destinations {
                destination.client.session.invalidateAndCancel()
            }
            BackupIssueS3URLProtocol.reset()
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: faceStoreURL)
        }

        private static func server(id: UUID, name: String, bucket: String, prefix: String) -> ServerConfig {
            ServerConfig(
                id: id,
                name: name,
                provider: .custom,
                endpoint: "http://127.0.0.1",
                region: "us-east-1",
                bucket: bucket,
                accessKeyID: "issue-key",
                prefix: prefix,
                pathStyle: true
            )
        }

        private static func client(server: ServerConfig) -> S3Client {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BackupIssueS3URLProtocol.self]
            let session = URLSession(configuration: configuration)
            return S3Client(
                connection: server.connection,
                credentials: S3Credentials(accessKeyID: "issue-key", secretAccessKey: "issue-secret"),
                session: session,
                headCache: nil
            )
        }
    }

    private func makeServer() -> ServerConfig {
        ServerConfig(
            name: "Issue",
            provider: .custom,
            endpoint: "http://issue.invalid",
            region: "us-east-1",
            bucket: "issue-bucket",
            accessKeyID: "issue-key",
            prefix: "Backu",
            pathStyle: true
        )
    }

    private func makeClient(server: ServerConfig) -> S3Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupIssueURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return S3Client(
            connection: server.connection,
            credentials: S3Credentials(accessKeyID: "issue-key", secretAccessKey: "issue-secret"),
            session: session,
            headCache: nil
        )
    }

    private func stubObjectPages(totalCount: Int, pageSize: Int) {
        let pageCount = (totalCount + pageSize - 1) / pageSize
        BackupIssueURLProtocol.setHandler { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard request.httpMethod == "GET", query.contains(where: { $0.name == "list-type" }) else {
                return (404, Data(), [:])
            }
            let pageIndex = query.first(where: { $0.name == "continuation-token" })?.value.flatMap(Int.init) ?? 0
            let start = pageIndex * pageSize
            let end = min(totalCount, start + pageSize)
            var xml = "<ListBucketResult>"
            for index in start..<end {
                xml += "<Contents><Key>Backu/Photos/object-\(index).jpg</Key><Size>1</Size></Contents>"
            }
            let isTruncated = pageIndex + 1 < pageCount
            xml += "<IsTruncated>\(isTruncated ? "true" : "false")</IsTruncated>"
            if isTruncated {
                xml += "<NextContinuationToken>\(pageIndex + 1)</NextContinuationToken>"
            }
            xml += "</ListBucketResult>"
            return (200, Data(xml.utf8), ["Content-Type": "application/xml"])
        }
    }

    private func makePhoto(id: String, filename: String = "IMG_0001.jpg", sha256: String? = nil) -> PhotoItem {
        PhotoItem(
            id: id,
            localIdentifier: String(id.dropFirst("asset:".count)),
            filename: filename,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 1,
            pixelHeight: 1,
            sha256: sha256
        )
    }

    private func solidImage() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 4,
                height: 4,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }

    private func isolateHome() throws {
        try FileManager.default.createDirectory(
            at: Self.isolationHome,
            withIntermediateDirectories: true
        )
        setenv("CFFIXED_USER_HOME", Self.isolationHome.path, 1)
        setenv("BACKU_AUDIT_ISOLATED_HOME", "1", 1)
        setenv("BACKU_FOREGROUND_UPLOADS", "1", 1)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let expectedPrefix = Self.isolationHome.resolvingSymlinksInPath().path + "/"
        guard let support, support.path.hasPrefix(expectedPrefix) else {
            throw NSError(
                domain: "BackupIssueTestIsolation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Application Support did not move into the test home: \(support?.path as Any)"]
            )
        }
    }

    nonisolated private static func objectKey(for request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        let prefix = "/issue-bucket/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : String(path.dropFirst())
    }
}

private final class BackupIssueS3URLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var shouldFailBucketB = true
    private static var paths: [String] = []

    static var failBucketB: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return shouldFailBucketB
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            shouldFailBucketB = newValue
        }
    }

    static func putCount(bucket: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.filter { $0.contains("/\(bucket)/") }.count
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        shouldFailBucketB = true
        paths.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if request.httpMethod == "PUT" {
            Self.lock.lock()
            Self.paths.append(path)
            Self.lock.unlock()
        }
        let failed = request.httpMethod == "GET" || (Self.failBucketB && path.contains("/bucket-b/"))
        let body = failed
            ? Data("<Error><Code>AccessDenied</Code><Message>forced failure</Message></Error>".utf8)
            : Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: failed ? 400 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BackupIssueURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, data: Data, headers: [String: String])

    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ newValue: Handler?) {
        lock.lock()
        handler = newValue
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: Handler?
        Self.lock.lock()
        handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: result.status,
                httpVersion: nil,
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                client?.urlProtocol(self, didLoad: result.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
