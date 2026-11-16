// Builds the marketing screenshot library: eight CC0 photos (landscapes and
// pets, no people) with synthetic EXIF so the listing screenshots look like a
// real library. Outputs are git-ignored; the sources are downloaded by
// Tools/Fixtures/download-marketing.sh.
//
//   swift Tools/Fixtures/prepare-marketing.swift
//
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct Shot {
    let source: String
    let output: String
    let date: String
    let latitude: Double
    let longitude: Double
    let place: String
    let focal: Double
    let aperture: Double
    let iso: Int
}

let shots: [Shot] = [
    Shot(source: "asturias.jpg", output: "IMG_7301.JPG", date: "2026:04:18 09:42:13", latitude: 43.1969, longitude: -4.8494, place: "Asturias, Spain", focal: 24, aperture: 1.78, iso: 64),
    Shot(source: "greek-lake.jpg", output: "IMG_7288.JPG", date: "2026:04:12 17:06:41", latitude: 35.2401, longitude: 24.4712, place: "Crete, Greece", focal: 26, aperture: 1.78, iso: 80),
    Shot(source: "phaistos.jpg", output: "IMG_7287.JPG", date: "2026:04:11 11:18:02", latitude: 35.0512, longitude: 24.8150, place: "Phaistos, Greece", focal: 48, aperture: 2.2, iso: 100),
    Shot(source: "dog-beach.jpg", output: "IMG_7044.JPG", date: "2026:01:05 14:22:37", latitude: 56.9499, longitude: 8.3912, place: "Nørre Vorupør, Denmark", focal: 24, aperture: 1.78, iso: 125),
    Shot(source: "dog-island.jpg", output: "IMG_6990.JPG", date: "2025:11:16 10:05:24", latitude: 10.6918, longitude: -61.7597, place: "Chacachacare, Trinidad", focal: 26, aperture: 1.78, iso: 100),
    Shot(source: "cat-grass.jpg", output: "IMG_7202.JPG", date: "2026:03:02 16:40:09", latitude: 51.8330, longitude: -1.8433, place: "Cotswolds, England", focal: 24, aperture: 1.78, iso: 200),
    Shot(source: "cat-tabby.jpg", output: "IMG_7203.JPG", date: "2026:03:02 16:44:51", latitude: 51.8330, longitude: -1.8433, place: "Cotswolds, England", focal: 70, aperture: 2.8, iso: 320),
    Shot(source: "kerala.jpg", output: "IMG_7012.JPG", date: "2025:12:28 08:12:55", latitude: 10.0889, longitude: 77.0595, place: "Kerala, India", focal: 24, aperture: 1.78, iso: 64)
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let raw = root.appendingPathComponent("Tests/Fixtures/marketing/raw")
let output = root.appendingPathComponent("Tests/Fixtures/marketing/library")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

var count = 0
for shot in shots {
    let sourceURL = raw.appendingPathComponent(shot.source)
    guard let image = thumbnail(sourceURL, maxPixel: 1800) else {
        print("skip \(shot.source)")
        continue
    }
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: shot.date,
        kCGImagePropertyExifDateTimeDigitized: shot.date,
        kCGImagePropertyExifFNumber: shot.aperture,
        kCGImagePropertyExifExposureTime: 1.0 / 160,
        kCGImagePropertyExifISOSpeedRatings: [shot.iso],
        kCGImagePropertyExifFocalLength: shot.focal,
        kCGImagePropertyExifLensModel: "Main Camera",
        kCGImagePropertyExifPixelXDimension: image.width,
        kCGImagePropertyExifPixelYDimension: image.height
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "Apple",
        kCGImagePropertyTIFFModel: "iPhone 17 Pro",
        kCGImagePropertyTIFFSoftware: "26.0"
    ]
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: abs(shot.latitude),
        kCGImagePropertyGPSLatitudeRef: shot.latitude >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(shot.longitude),
        kCGImagePropertyGPSLongitudeRef: shot.longitude >= 0 ? "E" : "W"
    ]
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyGPSDictionary: gps,
        kCGImageDestinationLossyCompressionQuality: 0.86
    ]
    let destinationURL = output.appendingPathComponent(shot.output)
    guard let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    if CGImageDestinationFinalize(dest) {
        count += 1
        print("wrote \(shot.output) · \(shot.place)")
    }
}
print("\(count) marketing photos in \(output.path)")
