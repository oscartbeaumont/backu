import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

private enum AuditMediaFixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func solid(_ colour: (CGFloat, CGFloat, CGFloat), side: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    static func platform(_ colour: (CGFloat, CGFloat, CGFloat), side: Int) -> PlatformImage {
        ImageUtilities.platformImage(from: solid(colour, side: side))
    }

    static func jpegData(side: Int = 32) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(
            destination,
            solid((0.4, 0.6, 0.8), side: side),
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class AuditMediaFaceEmbeddingRegressionTests: XCTestCase {
    func testInvalidVectorLengthsAreRejectedWithoutPoisoningTheStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-face-embeddings-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FaceEmbeddingStore(url: url)

        let emptyIndex = await store.append([])
        let oversizedIndex = await store.append(
            [Float](repeating: 1, count: FaceEmbeddingStore.dimension + 1)
        )
        XCTAssertEqual(emptyIndex, -1, "An empty vector cannot be addressed by vector(at:)")
        XCTAssertEqual(oversizedIndex, -1, "A vector larger than the persistent format limit must not be written")

        let validIndex = await store.append([1, 2, 3])
        XCTAssertEqual(validIndex, 0, "Rejected vectors must not consume an index")
        await store.flush()

        let reloaded = FaceEmbeddingStore(url: url)
        let reloadedCount = await reloaded.count
        XCTAssertEqual(reloadedCount, 1, "A rejected record must not hide later valid records on reload")
        let reloadedVector = await reloaded.vector(at: 0)
        XCTAssertEqual(reloadedVector, [1, 2, 3])
    }
}

final class AuditMediaFaceAnalysisRegressionTests: XCTestCase {
    func testMinimumFaceFractionUsesTheImageShortEdge() async throws {
        let path = AuditMediaFixtures.repoRoot
            .appendingPathComponent("Tests/Fixtures/library/IMG_4821.JPG")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Run swift Tools/Fixtures/prepare-fixtures.swift first")
        }
        let source = try XCTUnwrap(
            ImageMetadataReader.uprightCGImage(url: path, maxPixel: 1600)
        )
        let baselineStore = FaceEmbeddingStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let baseline = await FaceAnalyzer().analyze(image: source, embeddingStore: baselineStore)
        let face = try XCTUnwrap(baseline.faces.first { $0.kind == .person })

        // Widen the canvas without changing the face or the short edge. The
        // documented threshold is face pixels / short-edge pixels; that value
        // stays constant. min(normalized width, normalized height) does not.
        let canvasWidth = source.width * 3
        let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: source.height))
        context.draw(
            source,
            in: CGRect(
                x: CGFloat(canvasWidth - source.width) / 2,
                y: 0,
                width: CGFloat(source.width),
                height: CGFloat(source.height)
            )
        )
        let wide = try XCTUnwrap(context.makeImage())

        let faceWidthPixels = face.rect.width * CGFloat(source.width)
        let faceHeightPixels = face.rect.height * CGFloat(source.height)
        let shortEdgeFraction = min(faceWidthPixels, faceHeightPixels)
            / CGFloat(min(source.width, source.height))
        let normalizedBoxMinimum = min(
            face.rect.width * CGFloat(source.width) / CGFloat(canvasWidth),
            face.rect.height
        )
        guard shortEdgeFraction > normalizedBoxMinimum + 0.02 else {
            throw XCTSkip("This fixture's face shape does not distinguish the two threshold calculations")
        }
        let threshold = (shortEdgeFraction + normalizedBoxMinimum) / 2

        var analyzer = FaceAnalyzer()
        analyzer.minimumFaceFraction = threshold
        let wideStore = FaceEmbeddingStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let outcome = await analyzer.analyze(image: wide, embeddingStore: wideStore)
        XCTAssertTrue(
            outcome.faces.contains { $0.kind == .person },
            "The same face must pass when its short-edge fraction is unchanged"
        )
    }
}

@MainActor
final class AuditMediaImageCacheRegressionTests: XCTestCase {
    func testFaceCropCacheKeyIncludesRequestedSize() async throws {
        let cache = ImageCache()
        let photo = PhotoItem(id: "remote:face-crop", filename: "portrait.jpg")
        let face = PhotoFace(rect: NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        var loadedSizes: [CGFloat] = []
        cache.remoteThumbnailLoader = { _, size in
            loadedSizes.append(size.width)
            return AuditMediaFixtures.platform((0.4, 0.6, 0.8), side: Int(size.width))
        }

        let smallImage = await cache.faceImage(photo: photo, face: face, size: 100)
        let largeImage = await cache.faceImage(photo: photo, face: face, size: 400)
        let small = try XCTUnwrap(smallImage)
        let large = try XCTUnwrap(largeImage)

        XCTAssertEqual(loadedSizes, [100, 400], "Each requested crop resolution needs its own source decode")
        XCTAssertGreaterThan(
            ImageUtilities.cgImage(from: large)!.width,
            ImageUtilities.cgImage(from: small)!.width * 2,
            "A 400 px request must not reuse a crop decoded for a 100 px request"
        )
    }

    func testCachedPreviewIncludesAnAlreadyDecodedAtlasCell() async throws {
        let sheet = try XCTUnwrap(AtlasEncoder.encode(
            members: [
                ThumbnailAtlas.Member(
                    id: "remote:atlas-preview",
                    digest: "atlas-preview-digest",
                    image: AuditMediaFixtures.solid((1, 0, 0), side: 64)
                )
            ],
            level: .preview
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-atlas-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let atlases = AtlasStore(directory: directory)
        try sheet.data.write(
            to: directory.appendingPathComponent("preview-\(sheet.group).heic"),
            options: .atomic
        )
        let photo = PhotoItem(
            id: "remote:atlas-preview",
            filename: "atlas-preview.jpg",
            copies: [
                PhotoCopy(
                    serverID: UUID(),
                    objectKey: "atlas-preview.jpg",
                    sidecarKey: "atlas-preview.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "atlas-preview-digest",
                    atlasGroup: sheet.group,
                    atlasCell: 0
                )
            ]
        )
        _ = await atlases.tile(for: photo, level: .preview, client: nil)
        let cache = ImageCache()
        cache.atlasEnabled = true
        cache.atlasStore = atlases

        XCTAssertNotNil(cache.cachedAtlasPreview(for: photo), "The test must first warm the atlas cell")
        XCTAssertNotNil(
            cache.cachedPreview(for: photo),
            "The viewer's instant underlay should include the same decoded atlas preview the grid paints"
        )
    }

    func testRemoteThumbnailUsesTheSelectedServersCopyKey() async throws {
        AuditMediaRemoteAssetProtocol.reset()
        defer { AuditMediaRemoteAssetProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditMediaRemoteAssetProtocol.self]
        let session = URLSession(configuration: config)
        let server = ServerConfig(
            name: "Selected",
            provider: .custom,
            endpoint: "http://remote-asset.test",
            region: "us-east-1",
            bucket: "bucket",
            accessKeyID: "key",
            prefix: "selected",
            pathStyle: true
        )
        let client = S3Client(
            connection: server.connection,
            credentials: S3Credentials(accessKeyID: "key", secretAccessKey: "secret"),
            session: session,
            headCache: .disabled()
        )
        let otherServerID = UUID()
        let selectedCopy = PhotoCopy(
            serverID: server.id,
            objectKey: "selected/photo.jpg",
            sidecarKey: "selected/photo.jpg.json",
            thumbnailKey: "selected/thumb.jpg",
            uploadedAt: Date(),
            byteCount: 1,
            etag: nil,
            sha256: "selected-sha"
        )
        let otherCopy = PhotoCopy(
            serverID: otherServerID,
            objectKey: "other/photo.jpg",
            sidecarKey: "other/photo.jpg.json",
            thumbnailKey: "other/thumb.jpg",
            uploadedAt: Date(),
            byteCount: 1,
            etag: nil,
            sha256: "other-sha"
        )
        let photo = PhotoItem(
            id: "remote:multi-server-thumb",
            filename: "photo.jpg",
            copies: [otherCopy, selectedCopy],
            remoteThumbnailKey: "other/thumb.jpg",
            serverID: server.id
        )
        let safeName = SigV4Signer.sha256Hex(
            Data((server.id.uuidString + "selected/thumb.jpg").utf8)
        )
        let cacheURL = AppPaths.imageCache.appendingPathComponent("\(safeName).jpg")
        let otherSafeName = SigV4Signer.sha256Hex(
            Data((server.id.uuidString + "other/thumb.jpg").utf8)
        )
        let otherCacheURL = AppPaths.imageCache.appendingPathComponent("\(otherSafeName).jpg")
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: otherCacheURL)
        }

        let image = await RemoteAssetLoader.load(
            photo: photo,
            server: server,
            client: client,
            thumbnail: true
        )

        XCTAssertNotNil(image)
        XCTAssertEqual(
            AuditMediaRemoteAssetProtocol.lastURL?.path,
            "/bucket/selected/thumb.jpg",
            "The global thumbnail key may belong to another server; the selected copy's key must win"
        )
    }
}

final class AuditMediaAtlasDecoderRegressionTests: XCTestCase {
    func testDecoderRejectsPreviewPixelsAtGridGeometry() throws {
        let sheet = try XCTUnwrap(AtlasEncoder.encode(
            members: [
                ThumbnailAtlas.Member(
                    id: "photo-1",
                    digest: "digest-1",
                    image: AuditMediaFixtures.solid((1, 0, 0), side: 64)
                )
            ],
            level: .preview
        ))

        let decoded = AtlasDecoder.decode(data: sheet.data, group: sheet.group, level: .grid)

        XCTAssertNil(
            decoded,
            "A 384 px preview sheet must not be accepted as a 2304 px grid sheet"
        )
    }
}

@MainActor
final class AuditMediaAtlasCancellationRegressionTests: XCTestCase {
    func testCancelledPreviewPreloadDoesNotStartAnotherBatch() async throws {
        let sheet = try XCTUnwrap(AtlasEncoder.encode(
            members: [
                ThumbnailAtlas.Member(
                    id: "photo-1",
                    digest: "digest-1",
                    image: AuditMediaFixtures.solid((0.4, 0.6, 0.8), side: 64)
                )
            ],
            level: .preview
        ))
        let firstBatchStarted = expectation(description: "First four preview requests started")
        AuditMediaAtlasProtocol.reset(data: sheet.data, firstBatchStarted: firstBatchStarted)
        defer { AuditMediaAtlasProtocol.reset(data: Data(), firstBatchStarted: nil) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditMediaAtlasProtocol.self]
        let session = URLSession(configuration: config)
        let client = S3Client(
            connection: S3Connection(
                endpoint: URL(string: "http://atlas-cancel.test"),
                region: "us-east-1",
                bucket: "bucket",
                pathStyle: true
            ),
            credentials: S3Credentials(accessKeyID: "key", secretAccessKey: "secret"),
            session: session,
            headCache: .disabled()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-atlas-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtlasStore(directory: directory)
        let photos = (0..<5).map { index in
            PhotoItem(
                id: "remote:atlas-\(index)",
                filename: "atlas-\(index).jpg",
                copies: [
                    PhotoCopy(
                        serverID: UUID(),
                        objectKey: "photo-\(index).jpg",
                        sidecarKey: "photo-\(index).jpg.json",
                        thumbnailKey: nil,
                        uploadedAt: Date(),
                        byteCount: 1,
                        etag: nil,
                        sha256: "digest-\(index)",
                        atlasGroup: "group-\(index)",
                        atlasCell: 0
                    )
                ]
            )
        }

        let preload = Task { await store.preloadPreviews(photos: photos, client: client) }
        await fulfillment(of: [firstBatchStarted], timeout: 5)
        preload.cancel()
        AuditMediaAtlasProtocol.releaseAll()
        await preload.value

        XCTAssertEqual(
            AuditMediaAtlasProtocol.requestCount,
            4,
            "Cancellation must stop the loop before it schedules the fifth sheet"
        )
    }
}

private final class AuditMediaRemoteAssetProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _lastURL: URL?

    static var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _lastURL
    }

    static func reset() {
        lock.lock()
        _lastURL = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._lastURL = request.url
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: AuditMediaFixtures.jpegData())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AuditMediaAtlasProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var pending: [AuditMediaAtlasProtocol] = []
    private static var responseData = Data()
    private static var isOpen = false
    private static var firstBatchStarted: XCTestExpectation?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset(data: Data, firstBatchStarted: XCTestExpectation?) {
        lock.lock()
        count = 0
        pending.removeAll()
        responseData = data
        isOpen = false
        self.firstBatchStarted = firstBatchStarted
        lock.unlock()
    }

    static func releaseAll() {
        lock.lock()
        isOpen = true
        let waiting = pending
        pending.removeAll()
        let data = responseData
        lock.unlock()
        for protocolInstance in waiting {
            protocolInstance.respond(with: data)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let shouldWait = !Self.isOpen
        if shouldWait { Self.pending.append(self) }
        let expectation = Self.firstBatchStarted
        let data = Self.responseData
        let reachedFirstBatch = Self.count == 4
        Self.lock.unlock()

        if reachedFirstBatch { expectation?.fulfill() }
        if shouldWait { return }
        respond(with: data)
    }

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/heic"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
