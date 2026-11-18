import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable, content-addressed thumbnail atlases.
///
/// A library opened on a second device currently fetches one JPEG per tile. A
/// grid of 30 photos is 30 requests, and a fast scroll across a large library
/// is hundreds of round trips; the per-tile request cost, not the pixels, is
/// what leaves tiles blank.
///
/// An atlas packs a fixed batch of photos into one image. Each level of the
/// same batch is a separate file under the same group id:
///
///     .backu/atlas/v1/grid/<group>.jpg     6x6 cells, 384 px each
///     .backu/atlas/v1/preview/<group>.jpg  6x6 cells, 64 px each
///
/// The group id is the SHA-256 of the batch's photo digests, so a sheet is
/// immutable: changing a photo produces a new group, and an unchanged group
/// can be cached forever. A photo only stores `(group, cell)`, and every level
/// is derived from that pair. There is no mutable sheet to invalidate and no
/// ETag to poll.
enum ThumbnailAtlas {
    /// Bumped only when the layout or the file naming changes; old groups then
    /// simply stop being referenced instead of being read incorrectly.
    static let schema = "backu.atlas.v1"
    static let pathPrefix = ".backu/atlas/v1"
    static let groupIdentifierLength = 20

    /// Photos per group. Small enough that one sheet is a cheap download and a
    /// fast decode, large enough that a screen of 15 tiles is one request.
    static let groupCapacity = 36

    /// The three levels the app uses. The preview level covers the whole
    /// library in a few hundred kilobytes per thousand photos; the grid level
    /// is the final tile; `detail` is the per-photo JPEG that already exists.
    enum Level: String, CaseIterable, Sendable {
        case grid
        case preview

        var layout: AtlasLayout {
            switch self {
            case .grid:
                return AtlasLayout(cell: 384, columns: 6, rows: 6)
            case .preview:
                return AtlasLayout(cell: 64, columns: 6, rows: 6)
            }
        }

        /// HEIC is roughly half the bytes of JPEG at the same PSNR
        /// (`Tools/AtlasBench`: 10.8 KB vs 18.5 KB per 384 px tile at 40 dB),
        /// and Apple devices decode it in hardware. AVIF is smaller again but
        /// costs software decode on every scroll, so it loses on a phone.
        var codec: AtlasCodec {
            switch self {
            case .grid, .preview: return .heic
            }
        }

        var quality: Double {
            switch self {
            case .grid: return 0.62
            case .preview: return 0.50
            }
        }

        var keyPrefix: String {
            "\(ThumbnailAtlas.pathPrefix)/\(rawValue)"
        }
    }

    /// A photo inside a group. `id` is the catalog id (or digest when the
    /// caller only has bytes), `digest` is the object's SHA-256.
    struct Member: Sendable {
        var id: String
        var digest: String
        var image: CGImage
    }

    struct EncodedSheet: Sendable {
        var level: String
        var layout: AtlasLayout
        var codec: AtlasCodec
        var group: String
        var key: String
        var data: Data
        var document: SheetDocument
    }

    /// Self-describing sidecar so a bucket can be audited and repaired without
    /// the app's catalog. It is never read on the browsing hot path.
    struct SheetDocument: Codable, Sendable {
        struct Entry: Codable, Sendable {
            var id: String
            var digest: String
            var cell: Int
        }

        var schema: String = ThumbnailAtlas.schema
        var level: String
        var group: String
        var cell: Int
        var columns: Int
        var rows: Int
        var format: String
        var byteCount: Int
        var entries: [Entry]
    }

    /// Stable group id for an ordered batch. Order is part of the contract: a
    /// photo's cell is its index within the batch that produced the group.
    static func groupIdentifier(digests: [String]) -> String {
        let joined = digests.joined(separator: "\n")
        let full = SHA256.hash(data: Data(joined.utf8))
        return String(full.compactMap { String(format: "%02x", $0) }.joined().prefix(groupIdentifierLength))
    }

    static func key(level: Level, group: String) -> String {
        "\(level.keyPrefix)/\(group).\(level.codec.filenameExtension)"
    }

    static func sidecarKey(level: Level, group: String) -> String {
        "\(level.keyPrefix)/\(group).json"
    }
}

/// Cell geometry for one level. Pure value type so the benchmark, the upload
/// path and the cache can all agree without sharing state.
struct AtlasLayout: Codable, Hashable, Sendable {
    var cell: Int
    var columns: Int
    var rows: Int

    var capacity: Int { columns * rows }
    var pixelWidth: Int { cell * columns }
    var pixelHeight: Int { cell * rows }

    /// Cell rectangle in CoreGraphics *image* space (origin top-left), which
    /// is what `CGImage.cropping(to:)` expects and what an encoded sheet's
    /// pixel rows look like.
    func rect(cell index: Int) -> CGRect {
        let column = index % columns
        let row = index / columns
        return CGRect(x: column * cell, y: row * cell, width: cell, height: cell)
    }

    /// Cell rectangle for drawing into a `CGContext` (origin bottom-left).
    /// Row 0 must end up at the top of the encoded image, so it is drawn last.
    func contextRect(cell index: Int) -> CGRect {
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: column * cell,
            y: (rows - 1 - row) * cell,
            width: cell,
            height: cell
        )
    }

    /// Photos are stored already upright and square (aspect-fill), so a tile
    /// is a straight crop. `CGImage.cropping(to:)` shares the decoded buffer.
    func crop(_ index: Int, from image: CGImage) -> CGImage? {
        guard index >= 0, index < capacity else { return nil }
        return image.cropping(to: rect(cell: index))
    }
}

enum AtlasCodec: String, Codable, Sendable {
    case jpeg
    case heic
    case avif

    var contentType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .heic: return "image/heic"
        case .avif: return "image/avif"
        }
    }

    var filenameExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .jpeg
        }
    }
}

enum AtlasEncoder {
    /// Renders `members` into one sheet of the level's default geometry.
    static func encode(
        members: [ThumbnailAtlas.Member],
        level: ThumbnailAtlas.Level,
        codec: AtlasCodec? = nil,
        quality: Double? = nil
    ) -> ThumbnailAtlas.EncodedSheet? {
        encode(
            members: members,
            levelName: level.rawValue,
            layout: level.layout,
            keyPrefix: level.keyPrefix,
            codec: codec ?? level.codec,
            quality: quality ?? level.quality
        )
    }

    /// Explicit geometry, used by the benchmark to sweep cell sizes and codecs
    /// without changing the app's defaults.
    static func encode(
        members: [ThumbnailAtlas.Member],
        levelName: String,
        layout: AtlasLayout,
        keyPrefix: String,
        codec: AtlasCodec,
        quality: Double
    ) -> ThumbnailAtlas.EncodedSheet? {
        guard !members.isEmpty else { return nil }
        let batch = Array(members.prefix(layout.capacity))
        let group = ThumbnailAtlas.groupIdentifier(digests: batch.map(\.digest))

        guard let context = CGContext(
            data: nil,
            width: layout.pixelWidth,
            height: layout.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.pixelWidth, height: layout.pixelHeight))

        for (index, member) in batch.enumerated() {
            drawAspectFill(member.image, into: layout.contextRect(cell: index), context: context)
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            codec.utType.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyHasAlpha: false,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let bytes = data as Data
        let document = ThumbnailAtlas.SheetDocument(
            level: levelName,
            group: group,
            cell: layout.cell,
            columns: layout.columns,
            rows: layout.rows,
            format: codec.rawValue,
            byteCount: bytes.count,
            entries: batch.enumerated().map { index, member in
                .init(id: member.id, digest: member.digest, cell: index)
            }
        )
        return ThumbnailAtlas.EncodedSheet(
            level: levelName,
            layout: layout,
            codec: codec,
            group: group,
            key: "\(keyPrefix)/\(group).\(codec.filenameExtension)",
            data: bytes,
            document: document
        )
    }

    /// Draws an image into a cell, centred and cropped rather than squashed.
    /// CoreGraphics' origin is bottom-left; the maths is the same either way
    /// because the crop is symmetric, but the extra offset keeps the cell exact
    /// when the source is not square.
    private static func drawAspectFill(_ image: CGImage, into rect: CGRect, context: CGContext) {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let scale = max(rect.width / width, rect.height / height)
        let drawWidth = width * scale
        let drawHeight = height * scale
        let drawRect = CGRect(
            x: rect.midX - drawWidth / 2,
            y: rect.midY - drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: drawRect)
        context.restoreGState()
    }
}

/// A decoded sheet. Decoding once and cropping is the point of the format:
/// 36 individual JPEG decodes become one, and each tile is a buffer view.
final class AtlasDecodedSheet {
    let group: String
    let level: ThumbnailAtlas.Level
    let layout: AtlasLayout
    let image: CGImage
    let loadedAt = Date()

    init(group: String, level: ThumbnailAtlas.Level, layout: AtlasLayout? = nil, image: CGImage) {
        self.group = group
        self.level = level
        self.layout = layout ?? level.layout
        self.image = image
    }

    func tile(_ cell: Int) -> CGImage? {
        layout.crop(cell, from: image)
    }
}

enum AtlasDecoder {
    /// Decodes a sheet with the pixels materialised immediately. Lazy decode
    /// would otherwise land inside the next frame commit, exactly where the
    /// grid cannot afford it.
    static func decode(
        data: Data,
        group: String,
        level: ThumbnailAtlas.Level,
        layout: AtlasLayout? = nil
    ) -> AtlasDecodedSheet? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: source, group: group, level: level, layout: layout)
    }

    static func decode(
        url: URL,
        group: String,
        level: ThumbnailAtlas.Level,
        layout: AtlasLayout? = nil
    ) -> AtlasDecodedSheet? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: source, group: group, level: level, layout: layout)
    }

    private static func decode(
        source: CGImageSource,
        group: String,
        level: ThumbnailAtlas.Level,
        layout: AtlasLayout?
    ) -> AtlasDecodedSheet? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return AtlasDecodedSheet(group: group, level: level, layout: layout, image: image)
    }
}
