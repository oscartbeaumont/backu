import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum ImageMetadataReader {
    static func read(url: URL) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return metadata
        }

        if let width = properties[kCGImagePropertyPixelWidth] as? Int { metadata.fileSize = nil; _ = width }
        metadata.orientation = properties[kCGImagePropertyOrientation] as? Int

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            metadata.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            metadata.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
                metadata.iso = first
            } else if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
                metadata.iso = iso
            }
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            metadata.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            metadata.latitude = latitudeRef == "S" ? -latitude : latitude
            metadata.longitude = longitudeRef == "W" ? -longitude : longitude
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
                let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
                metadata.altitude = belowSeaLevel ? -altitude : altitude
            }
        }

        if let type = CGImageSourceGetType(source) as String? {
            metadata.uti = type
            if let ut = UTType(type) {
                metadata.fileExtension = ut.preferredFilenameExtension
            }
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
            metadata.fileSize = size
        }
        return metadata
    }

    /// Downsamples an image, applying EXIF orientation, for Vision and previews.
    static func uprightCGImage(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func thumbnailJPEG(url: URL, maxPixel: Int, quality: CGFloat = 0.8) -> Data? {
        guard let cgImage = uprightCGImage(url: url, maxPixel: maxPixel) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
