import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The container used for the small preview Backu stores next to an original.
///
/// Previews are app-internal objects (`.backu/thumbs/…`), so the only
/// requirements are that ImageIO can write them quickly and that every device
/// running Backu can read them back. Both HEIC and JPEG satisfy that on the
/// deployment targets.
///
/// The measurements in `Tools/CompressionBench` show HEIC at 900 px and
/// quality 0.8 is ~47 % smaller than JPEG q0.8 at ~1.9 dB lower PSNR (~40 dB,
/// visually transparent at preview size), while using the hardware HEVC
/// encoder and decoder. AVIF saves another 16 % of the bytes but costs roughly
/// six times more encode CPU per preview, a poor trade for a background upload.
enum PreviewFormat: String, CaseIterable, Sendable {
    case heic
    case jpeg

    var utType: UTType {
        switch self {
        case .heic: return UTType("public.heic") ?? .jpeg
        case .jpeg: return .jpeg
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: return "heic"
        case .jpeg: return "jpg"
        }
    }

    var contentType: String {
        switch self {
        case .heic: return "image/heic"
        case .jpeg: return "image/jpeg"
        }
    }

    /// HEIC when this OS can write it, JPEG otherwise.
    static var preferred: PreviewFormat {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(UTType.heic.identifier) ? .heic : .jpeg
    }

    /// The format of a stored preview key, so a bucket written by an older
    /// build (`.jpg`) or a newer one (`.heic`) is decoded from its real bytes
    /// rather than from an assumed extension.
    static func from(key: String) -> PreviewFormat? {
        let ext = (key as NSString).pathExtension.lowercased()
        switch ext {
        case "heic", "heif": return .heic
        case "jpg", "jpeg": return .jpeg
        default: return nil
        }
    }
}

struct EncodedPreview: Sendable {
    var data: Data
    var format: PreviewFormat
}

/// Encodes the viewer/grid preview that is uploaded beside every original.
enum PreviewCodec {
    /// Matches the size the viewer asks for (1200 px) with a little headroom
    /// for the grid's higher pixel density on iPad and Mac.
    static let maxPixel = 900

    static func encode(
        url: URL,
        maxPixel: Int = maxPixel,
        format: PreviewFormat = .preferred,
        quality: CGFloat = 0.8
    ) -> EncodedPreview? {
        guard let image = ImageMetadataReader.uprightCGImage(url: url, maxPixel: maxPixel) else {
            return nil
        }
        return encode(image: image, maxPixel: maxPixel, format: format, quality: quality)
    }

    static func encode(
        image: CGImage,
        maxPixel: Int = maxPixel,
        format: PreviewFormat = .preferred,
        quality: CGFloat = 0.8
    ) -> EncodedPreview? {
        let sized = ImageUtilities.resize(image, maxPixel: maxPixel) ?? image
        guard let data = encode(sized: sized, format: format, quality: quality) else {
            // The preferred format is available on every supported OS; this is
            // a guard against a future OS dropping it or a simulator quirk.
            guard format != .jpeg,
                  let fallback = encode(sized: sized, format: .jpeg, quality: quality) else {
                return nil
            }
            return EncodedPreview(data: fallback, format: .jpeg)
        }
        return EncodedPreview(data: data, format: format)
    }

    private static func encode(sized image: CGImage, format: PreviewFormat, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.utType.identifier as CFString,
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
