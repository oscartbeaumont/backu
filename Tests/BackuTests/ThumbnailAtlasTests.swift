import CoreGraphics
import XCTest

/// The atlas is only safe because of three properties, and each one is checked
/// here: a group id is a pure function of its members, cell geometry survives
/// encode/decode (including row order), and the pointer rides along in the
/// index/sidecar so a second device can find the sheet.
final class ThumbnailAtlasTests: XCTestCase {
    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat, side: Int) -> CGImage {
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

    private func pixel(_ image: CGImage, x: Int = 0, y: Int = 0) -> (Int, Int, Int) {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    func testGroupIdentifierIsStableAndOrdered() {
        let a = ThumbnailAtlas.groupIdentifier(digests: ["a", "b", "c"])
        let b = ThumbnailAtlas.groupIdentifier(digests: ["a", "b", "c"])
        let reordered = ThumbnailAtlas.groupIdentifier(digests: ["b", "a", "c"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, reordered, "A cell index only means something in batch order")
        XCTAssertEqual(a.count, ThumbnailAtlas.groupIdentifierLength)
    }

    func testCellsKeepTheirTopLeftRowOrder() throws {
        let layout = AtlasLayout(cell: 8, columns: 2, rows: 2)
        let colours: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0),
            (0, 0, 1), (1, 1, 0)
        ]
        let members = colours.enumerated().map { index, colour in
            ThumbnailAtlas.Member(
                id: "photo-\(index)",
                digest: "digest-\(index)",
                image: solid(red: colour.0, green: colour.1, blue: colour.2, side: 64)
            )
        }
        let sheet = try XCTUnwrap(AtlasEncoder.encode(
            members: members,
            levelName: "test",
            layout: layout,
            keyPrefix: "test",
            codec: .jpeg,
            quality: 0.95
        ))
        let decoded = try XCTUnwrap(AtlasDecoder.decode(
            data: sheet.data,
            group: sheet.group,
            level: .preview,
            layout: layout
        ))

        // Row 0 is the top row, and cropping uses the same top-left origin the
        // encoder draws into. Getting this wrong swaps whole rows of photos.
        let topLeft = pixel(try XCTUnwrap(decoded.tile(0)))
        let topRight = pixel(try XCTUnwrap(decoded.tile(1)))
        let bottomLeft = pixel(try XCTUnwrap(decoded.tile(2)))
        let bottomRight = pixel(try XCTUnwrap(decoded.tile(3)))

        XCTAssertGreaterThan(topLeft.0, 150)
        XCTAssertGreaterThan(topRight.1, 150)
        XCTAssertGreaterThan(bottomLeft.2, 150)
        XCTAssertGreaterThan(bottomRight.0, 150)
        XCTAssertGreaterThan(bottomRight.1, 150)
    }

    func testHeicPreviewIsSmallerThanJpegAtTheSameCellSize() throws {
        let layout = AtlasLayout(cell: 64, columns: 6, rows: 6)
        let members = (0..<layout.capacity).map { index in
            ThumbnailAtlas.Member(
                id: "p\(index)",
                digest: "d\(index)",
                image: solid(
                    red: CGFloat(index % 7) / 7,
                    green: CGFloat(index % 5) / 5,
                    blue: CGFloat(index % 3) / 3,
                    side: 64
                )
            )
        }
        let jpeg = try XCTUnwrap(AtlasEncoder.encode(
            members: members,
            levelName: "preview",
            layout: layout,
            keyPrefix: "p",
            codec: .jpeg,
            quality: 0.5
        ))
        let heic = try XCTUnwrap(AtlasEncoder.encode(
            members: members,
            levelName: "preview",
            layout: layout,
            keyPrefix: "p",
            codec: .heic,
            quality: 0.5
        ))
        XCTAssertLessThan(heic.data.count, jpeg.data.count)
        XCTAssertNotNil(AtlasDecoder.decode(data: heic.data, group: heic.group, level: .preview))
    }

    @MainActor
    func testCatalogRecordsAndSidecarCarryThePointer() throws {
        let serverID = UUID()
        let store = CatalogStore(loadFromDisk: false)
        let photo = PhotoItem(id: "asset:1", localIdentifier: "1", filename: "IMG.jpg")
        store.mergeScanned([photo])
        store.recordUpload(
            copy: PhotoCopy(
                serverID: serverID,
                objectKey: "Backu/Photos/a.jpg",
                sidecarKey: "Backu/Photos/a.jpg.json",
                thumbnailKey: "Backu/.backu/thumbs/a.jpg",
                uploadedAt: Date(),
                byteCount: 1,
                etag: nil,
                sha256: "sha-a"
            ),
            for: photo.id
        )

        store.recordAtlas(serverID: serverID, group: "group-1", assignments: [photo.id: 7])
        let updated = try XCTUnwrap(store.photo(id: photo.id))
        XCTAssertEqual(updated.copy(on: serverID)?.atlasGroup, "group-1")
        XCTAssertEqual(updated.copy(on: serverID)?.atlasCell, 7)

        let sidecar = SidecarDocument.make(
            photo: updated,
            people: [:],
            device: "test",
            sha256: "sha-a",
            serverID: serverID
        )
        XCTAssertEqual(sidecar.atlasGroup, "group-1")
        XCTAssertEqual(sidecar.atlasCell, 7)

        // The index is the path a second device actually reads.
        let document = RemoteIndexDocument.make(
            photos: [updated],
            people: [],
            serverID: serverID,
            device: "test"
        )
        let data = try JSONFile.encoder().encode(document)
        let restored = try JSONFile.decoder.decode(RemoteIndexDocument.self, from: data)
        let imported = restored.photoItems(serverID: serverID)
        XCTAssertEqual(imported.first?.copy(on: serverID)?.atlasGroup, "group-1")
        XCTAssertEqual(imported.first?.copy(on: serverID)?.atlasCell, 7)
    }
}
