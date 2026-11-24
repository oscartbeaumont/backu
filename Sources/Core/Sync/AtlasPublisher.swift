import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds immutable atlas groups while a backup run is uploading photos.
///
/// Tiles are accumulated until a group is full, then both levels are encoded,
/// written to the bucket and referenced from the catalog in one step. Nothing
/// is ever rewritten: the group id is the hash of its members, so re-running a
/// backup over the same photos produces the same keys and the PUT is a no-op
/// copy of identical bytes.
///
/// Order matters only within a group; the cell index is the position in the
/// batch. A crash between the sheet PUT and the catalog write leaves an
/// unreferenced sheet (harmless, and collectable later) and the photos still
/// have their per-photo thumbnail, so the grid never breaks.
@MainActor
final class AtlasBatch {
    private struct Pending {
        var photoID: String
        var digest: String
        var grid: CGImage
        var preview: CGImage
    }

    private let server: ServerConfig
    private let client: S3Client
    private let catalog: CatalogStore
    private var pending: [Pending] = []

    private(set) var uploadedSheets = 0
    private(set) var uploadedPhotos = 0

    init(server: ServerConfig, client: S3Client, catalog: CatalogStore) {
        self.server = server
        self.client = client
        self.catalog = catalog
    }

    var pendingCount: Int { pending.count }

    func add(photoID: String, digest: String, grid: CGImage, preview: CGImage) async {
        // BackupEngine records each upload copy after add returns. Flush the
        // previous group before accepting the next photo so those copies exist
        // when the atlas pointers are recorded.
        if pending.count >= ThumbnailAtlas.groupCapacity {
            await flush()
        }
        pending.append(Pending(photoID: photoID, digest: digest, grid: grid, preview: preview))
    }

    func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let server = self.server
        let client = self.client

        // Encoding a group is ~70 ms of CPU for both levels. Doing it on the
        // main actor during a foreground backup would be a visible hitch; the
        // CGImages are immutable and safe to hand to a background task.
        let encoded = await Task.detached(priority: .utility) {
            ThumbnailAtlas.Level.allCases.compactMap { level -> ThumbnailAtlas.EncodedSheet? in
                let members = batch.map { item in
                    ThumbnailAtlas.Member(
                        id: item.photoID,
                        digest: item.digest,
                        image: level == .grid ? item.grid : item.preview
                    )
                }
                return AtlasEncoder.encode(members: members, level: level)
            }
        }.value

        // Both levels must exist before anything is referenced: a pointer that
        // resolves for the grid but not for previews would show placeholders.
        guard encoded.count == ThumbnailAtlas.Level.allCases.count,
              let group = encoded.first?.group
        else { return }

        for sheet in encoded {
            let key = S3Client.join(server.normalizedPrefix, sheet.key)
            do {
                try await client.putObject(
                    key: key,
                    data: sheet.data,
                    contentType: sheet.codec.contentType
                )
                // The sidecar lets a bucket be audited and repaired without the
                // app's catalog. It is never read while browsing.
                if let level = ThumbnailAtlas.Level(rawValue: sheet.level),
                   let document = try? JSONFile.encoder().encode(sheet.document) {
                    try? await client.putObject(
                        key: S3Client.join(
                            server.normalizedPrefix,
                            ThumbnailAtlas.sidecarKey(level: level, group: sheet.group)
                        ),
                        data: document,
                        contentType: "application/json"
                    )
                }
                uploadedSheets += 1
            } catch {
                // A sheet that fails to upload is not fatal: no pointer is
                // recorded and the grid falls back to per-photo thumbnails. The
                // next run rebuilds the same group from the same inputs.
                return
            }
        }

        var assignments: [String: Int] = [:]
        for (cell, item) in batch.enumerated() {
            assignments[item.photoID] = cell
        }
        catalog.recordAtlas(serverID: server.id, group: group, assignments: assignments)
        uploadedPhotos += batch.count
    }
}

enum AtlasTileRenderer {
    /// Reads the original once and returns the existing 900 px thumbnail plus
    /// the two atlas tiles. Keeping this in one pass matters: the run already
    /// decodes every photo for EXIF and faces, and a second decode per photo
    /// would show up in backup time on a large import.
    static func render(url: URL, thumbnailMaxPixel: Int = 900) -> (thumbnail: Data, grid: CGImage, preview: CGImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        guard let thumbnail = jpegData(upright, quality: 0.8) else { return nil }
        guard let grid = square(upright, side: ThumbnailAtlas.Level.grid.layout.cell),
              let preview = square(upright, side: ThumbnailAtlas.Level.preview.layout.cell) else {
            return nil
        }
        return (thumbnail, grid, preview)
    }

    /// Aspect-fill, upright square. Unlike the encoder's cell drawing this
    /// works from a non-square source, so the tiles are uniform before they
    /// ever reach a sheet.
    static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = max(CGFloat(side) / width, CGFloat(side) / height)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(side) - width * scale) / 2,
                y: (CGFloat(side) - height * scale) / 2,
                width: width * scale,
                height: height * scale
            )
        )
        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
