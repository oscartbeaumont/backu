import CoreGraphics
import XCTest

/// End-to-end atlas test against `Tools/MockS3`: encode, upload, resolve a
/// photo pointer, download, decode, crop and then serve from the disk cache.
/// Skips itself when the mock is not running.
@MainActor
final class AtlasStoreIntegrationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9000")!
    private let bucket = "backu-test"
    private let serverID = UUID()

    private func makeClient() -> S3Client {
        S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
        )
    }

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

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, side: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    private func colour(_ image: PlatformImage) -> (Int, Int, Int) {
        let cgImage = ImageUtilities.cgImage(from: image)!
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    func testSheetDownloadsOnceThenServesFromDisk() async throws {
        try await requireServer()
        let client = makeClient()

        let layout = ThumbnailAtlas.Level.grid.layout
        let members = (0..<layout.capacity).map { index in
            ThumbnailAtlas.Member(
                id: "photo-\(index)",
                digest: "digest-\(index)",
                image: solid(
                    index == 5 ? 0.1 : 0.9,
                    index == 5 ? 0.2 : 0.1,
                    index == 5 ? 0.9 : 0.1,
                    side: layout.cell
                )
            )
        }
        let sheet = try XCTUnwrap(AtlasEncoder.encode(members: members, level: .grid))
        try await client.putObject(
            key: sheet.key,
            data: sheet.data,
            contentType: ThumbnailAtlas.Level.grid.codec.contentType
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-store-test-\(UUID().uuidString)")
        let store = AtlasStore(directory: directory)

        let photo = PhotoItem(
            id: "remote:1",
            localIdentifier: nil,
            filename: "IMG_0001.jpg",
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/Photos/IMG_0001.jpg",
                    sidecarKey: "Backu/Photos/IMG_0001.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "digest-5",
                    atlasGroup: sheet.group,
                    atlasCell: 5
                )
            ],
            serverID: serverID
        )

        let firstTile = await store.tile(for: photo, level: .grid, client: client)
        let first = try XCTUnwrap(firstTile)
        let firstColour = colour(first)
        XCTAssertGreaterThan(firstColour.2, 150, "Cell 5 must be the blue tile")
        XCTAssertEqual(store.downloads, 1)

        // A new store with the same directory is what a relaunch looks like:
        // the sheet comes from disk, and no network request is made.
        let relaunched = AtlasStore(directory: directory)
        let secondTile = await relaunched.tile(for: photo, level: .grid, client: client)
        let second = try XCTUnwrap(secondTile)
        XCTAssertEqual(colour(second).2, firstColour.2)
        XCTAssertEqual(relaunched.downloads, 0)
        XCTAssertEqual(relaunched.diskHits, 1)

        // Synchronous lookup is what the grid paints from without blocking.
        XCTAssertNotNil(relaunched.cachedTile(for: photo, level: .grid))
        relaunched.clearMemory()
        XCTAssertNil(relaunched.cachedTile(for: photo, level: .grid))

        try? await client.deleteObject(key: sheet.key)
        try? FileManager.default.removeItem(at: directory)
    }

    func testPointerSurvivesIndexAndSidecar() async throws {
        let photo = PhotoItem(
            id: "remote:1",
            localIdentifier: nil,
            filename: "IMG_0001.jpg",
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/Photos/IMG_0001.jpg",
                    sidecarKey: "Backu/Photos/IMG_0001.jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "abc",
                    atlasGroup: "0123456789abcdef0123",
                    atlasCell: 11
                )
            ]
        )
        let index = RemoteIndexDocument.make(
            photos: [photo],
            people: [],
            serverID: serverID,
            device: "test"
        )
        let restored = try JSONFile.decoder.decode(
            RemoteIndexDocument.self,
            from: JSONFile.encoder().encode(index)
        )
        XCTAssertEqual(restored.photos.first?.atlasGroup, "0123456789abcdef0123")
        XCTAssertEqual(restored.photos.first?.atlasCell, 11)
        XCTAssertEqual(AtlasStore.pointer(for: restored.photoItems(serverID: serverID)[0], serverID: serverID)?.cell, 11)
    }
}

/// Exercises the publish path: tiles in, immutable sheets out, pointers in the
/// catalog, and cells that decode back to the right photo.
@MainActor
final class AtlasBatchIntegrationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9000")!
    private let bucket = "backu-test"

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

    private func tile(_ index: Int, side: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let shade = CGFloat(index % 8) / 8
        context.setFillColor(CGColor(red: shade, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    func testBatchPublishesTwoLevelsForTheSameGroupAndRecordsPointers() async throws {
        try await requireServer()
        let server = ServerConfig(
            name: "Mock",
            provider: .custom,
            endpoint: endpoint.absoluteString,
            region: "us-east-1",
            bucket: bucket,
            accessKeyID: "testkey",
            prefix: "AtlasBatchTests-\(UUID().uuidString.prefix(8))",
            pathStyle: true
        )
        let serverID = server.id
        let client = S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
        )
        let catalog = CatalogStore(loadFromDisk: false)
        let count = ThumbnailAtlas.groupCapacity + 4
        let photos = (0..<count).map { index in
            PhotoItem(id: "asset:\(index)", localIdentifier: "\(index)", filename: "IMG_\(index).jpg")
        }
        catalog.mergeScanned(photos)
        for (index, photo) in photos.enumerated() {
            catalog.recordUpload(
                copy: PhotoCopy(
                    serverID: serverID,
                    objectKey: "\(server.normalizedPrefix)/Photos/\(index).jpg",
                    sidecarKey: "\(server.normalizedPrefix)/Photos/\(index).jpg.json",
                    thumbnailKey: nil,
                    uploadedAt: Date(),
                    byteCount: 1,
                    etag: nil,
                    sha256: "sha-\(index)"
                ),
                for: photo.id
            )
        }

        let batch = AtlasBatch(server: server, client: client, catalog: catalog)
        for (index, photo) in photos.enumerated() {
            await batch.add(
                photoID: photo.id,
                digest: "sha-\(index)",
                grid: tile(index, side: ThumbnailAtlas.Level.grid.layout.cell),
                preview: tile(index, side: ThumbnailAtlas.Level.preview.layout.cell)
            )
        }
        await batch.flush()

        XCTAssertEqual(batch.uploadedPhotos, count)
        XCTAssertEqual(batch.uploadedSheets, 4, "Two groups × two levels")

        let firstGroup = try XCTUnwrap(catalog.photo(id: photos[0].id)?.copy(on: serverID)?.atlasGroup)
        let secondGroup = try XCTUnwrap(catalog.photo(id: photos[36].id)?.copy(on: serverID)?.atlasGroup)
        XCTAssertNotEqual(firstGroup, secondGroup)
        XCTAssertEqual(catalog.photo(id: photos[0].id)?.copy(on: serverID)?.atlasCell, 0)
        XCTAssertEqual(catalog.photo(id: photos[35].id)?.copy(on: serverID)?.atlasCell, 35)
        XCTAssertEqual(catalog.photo(id: photos[35].id)?.copy(on: serverID)?.atlasGroup, firstGroup)
        XCTAssertEqual(catalog.photo(id: photos[36].id)?.copy(on: serverID)?.atlasCell, 0)
        XCTAssertEqual(catalog.photo(id: photos[36].id)?.copy(on: serverID)?.atlasGroup, secondGroup)

        // The sheet the catalog points at is the one in the bucket, and the
        // cell decodes back to the same photo's tile.
        let gridKey = S3Client.join(server.normalizedPrefix, ThumbnailAtlas.key(level: .grid, group: firstGroup))
        let previewKey = S3Client.join(server.normalizedPrefix, ThumbnailAtlas.key(level: .preview, group: firstGroup))
        let gridData = try await client.getObject(key: gridKey)
        let previewData = try await client.getObject(key: previewKey)
        XCTAssertNotNil(AtlasDecoder.decode(data: gridData, group: firstGroup, level: .grid))
        XCTAssertNotNil(AtlasDecoder.decode(data: previewData, group: firstGroup, level: .preview))
        XCTAssertLessThan(previewData.count, gridData.count)

        try? await client.deleteObject(key: gridKey)
        try? await client.deleteObject(key: previewKey)
        try? await client.deleteObject(
            key: S3Client.join(server.normalizedPrefix, ThumbnailAtlas.key(level: .grid, group: secondGroup))
        )
        try? await client.deleteObject(
            key: S3Client.join(server.normalizedPrefix, ThumbnailAtlas.key(level: .preview, group: secondGroup))
        )
    }
}
