import XCTest

@MainActor
final class AuditMediaServerRegressionTests: XCTestCase {
    func testAtlasQueueUsesEachPhotosServerClient() async {
        AuditMediaServerURLProtocol.reset()
        defer { AuditMediaServerURLProtocol.reset() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-atlas-\(UUID().uuidString)")
        let store = AtlasStore(directory: directory)
        defer {
            store.clearMemory()
            try? FileManager.default.removeItem(at: directory)
        }

        let aID = UUID()
        let bID = UUID()
        let a = ServerConfig(
            id: aID,
            name: "A",
            provider: .custom,
            endpoint: "http://127.0.0.1",
            region: "us-east-1",
            bucket: "bucket-a",
            accessKeyID: "audit-key",
            prefix: "A",
            pathStyle: true
        )
        let b = ServerConfig(
            id: bID,
            name: "B",
            provider: .custom,
            endpoint: "http://127.0.0.1",
            region: "us-east-1",
            bucket: "bucket-b",
            accessKeyID: "audit-key",
            prefix: "B",
            pathStyle: true
        )

        func client(_ server: ServerConfig) -> S3Client {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuditMediaServerURLProtocol.self]
            return S3Client(
                connection: server.connection,
                credentials: S3Credentials(accessKeyID: "audit-key", secretAccessKey: "audit-secret"),
                session: URLSession(configuration: configuration),
                headCache: nil
            )
        }

        let clientA = client(a)
        let clientB = client(b)
        defer {
            clientA.session.invalidateAndCancel()
            clientB.session.invalidateAndCancel()
        }

        func photo(_ index: Int, server: ServerConfig) -> PhotoItem {
            PhotoItem(
                id: "remote:\(server.bucket)-\(index)",
                localIdentifier: nil,
                filename: "IMG_\(index).jpg",
                copies: [PhotoCopy(
                    serverID: server.id,
                    objectKey: "\(server.normalizedPrefix)/IMG_\(index).jpg",
                    sidecarKey: "\(server.normalizedPrefix)/IMG_\(index).jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "sha-\(server.bucket)-\(index)",
                    atlasGroup: "group-\(server.bucket)-\(index)",
                    atlasCell: 0
                )],
                sha256: "sha-\(server.bucket)-\(index)",
                serverID: server.id
            )
        }

        // Fill A's four active slots and leave one A request queued. B is then
        // enqueued behind it; B must retain its own client and prefix.
        store.prepare(photos: (0..<5).map { photo($0, server: a) }, level: .preview, client: clientA, prefix: "A")
        store.prepare(photos: [photo(0, server: b)], level: .preview, client: clientB, prefix: "B")

        for _ in 0..<100 where AuditMediaServerURLProtocol.getTotal < 6 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(AuditMediaServerURLProtocol.getTotal, 6)
        XCTAssertEqual(AuditMediaServerURLProtocol.getCount(bucket: "bucket-a"), 5, "A's sheets should use A's client")
        XCTAssertEqual(AuditMediaServerURLProtocol.getCount(bucket: "bucket-b"), 1, "B's queued sheet should use B's client")
    }

    func testRemoteThumbnailPrefersSelectedCopiesKey() async {
        AuditMediaServerURLProtocol.reset()
        defer { AuditMediaServerURLProtocol.reset() }

        let aID = UUID()
        let bID = UUID()
        let a = ServerConfig(
            id: aID,
            name: "A",
            provider: .custom,
            endpoint: "http://127.0.0.1",
            region: "us-east-1",
            bucket: "bucket-a",
            accessKeyID: "audit-key",
            prefix: "A",
            pathStyle: true
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditMediaServerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = S3Client(
            connection: a.connection,
            credentials: S3Credentials(accessKeyID: "audit-key", secretAccessKey: "audit-secret"),
            session: session,
            headCache: nil
        )
        let item = PhotoItem(
            id: "remote:audit-thumbnail-key",
            localIdentifier: nil,
            filename: "IMG_AUDIT.jpg",
            copies: [
                PhotoCopy(
                    serverID: aID,
                    objectKey: "A/IMG_AUDIT.jpg",
                    sidecarKey: "A/IMG_AUDIT.jpg.json",
                    thumbnailKey: "A/.backu/thumbs/a.jpg",
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "sha"
                ),
                PhotoCopy(
                    serverID: bID,
                    objectKey: "B/IMG_AUDIT.jpg",
                    sidecarKey: "B/IMG_AUDIT.jpg.json",
                    thumbnailKey: "B/.backu/thumbs/b.jpg",
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "sha"
                )
            ],
            sha256: "sha",
            remoteThumbnailKey: "B/.backu/thumbs/b.jpg",
            serverID: aID
        )

        _ = await RemoteAssetLoader.load(photo: item, server: a, client: client, thumbnail: true)
        XCTAssertEqual(
            AuditMediaServerURLProtocol.lastGetPath,
            "/bucket-a/A/.backu/thumbs/a.jpg",
            "Loading A's thumbnail must use A's copy key, not B's legacy/global key"
        )
    }
}

private final class AuditMediaServerURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var getPaths: [String] = []

    static func getCount(bucket: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return getPaths.filter { $0.contains("/\(bucket)/") }.count
    }

    static var getTotal: Int {
        lock.lock()
        defer { lock.unlock() }
        return getPaths.count
    }

    static var lastGetPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return getPaths.last
    }

    static func reset() {
        lock.lock()
        getPaths.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET" {
            Self.lock.lock()
            Self.getPaths.append(path)
            Self.lock.unlock()
        }
        let failed = request.httpMethod == "GET"
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
