// Builds the simulator photo library used for manual and UI testing.
//
//   swift Tools/Fixtures/prepare-fixtures.swift
//   xcrun simctl addmedia booted Tests/Fixtures/library/*.jpg
//
// Source images come from Wikimedia Commons (public domain US government
// portraits plus two CC BY-SA dog photos). See Fixtures/ATTRIBUTION.md.

import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct Fixture {
    let source: String
    let output: String
    let date: String
    let make: String
    let model: String
    let lens: String
    let iso: Int
    let aperture: Double
    let shutter: Double
    let focal: Double
    let latitude: Double
    let longitude: Double
    let place: String
}

let fixtures: [Fixture] = [
    Fixture(source: "obama.jpg", output: "IMG_4821.JPG", date: "2025:06:14 10:24:11", make: "Apple", model: "iPhone 17 Pro", lens: "iPhone 17 Pro back triple camera 6.86mm f/1.78", iso: 64, aperture: 1.78, shutter: 1.0 / 120, focal: 24, latitude: 51.5072, longitude: -0.1276, place: "London"),
    Fixture(source: "michelle.jpg", output: "IMG_4822.JPG", date: "2025:06:14 10:26:02", make: "Apple", model: "iPhone 17 Pro", lens: "iPhone 17 Pro back triple camera 6.86mm f/1.78", iso: 100, aperture: 1.78, shutter: 1.0 / 90, focal: 24, latitude: 51.5072, longitude: -0.1276, place: "London"),
    Fixture(source: "two-people.jpg", output: "IMG_4910.JPG", date: "2025:06:15 16:02:44", make: "Apple", model: "iPhone 17 Pro", lens: "iPhone 17 Pro back camera 2.22mm f/2.2", iso: 200, aperture: 2.2, shutter: 1.0 / 60, focal: 13, latitude: 48.8566, longitude: 2.3522, place: "Paris"),
    Fixture(source: "biden.jpg", output: "IMG_5104.JPG", date: "2024:11:03 09:12:30", make: "Apple", model: "iPhone 15 Pro", lens: "iPhone 15 Pro back triple camera 6.765mm f/1.78", iso: 80, aperture: 1.78, shutter: 1.0 / 100, focal: 24, latitude: 40.7128, longitude: -74.0060, place: "New York"),
    Fixture(source: "harris.jpg", output: "IMG_5105.JPG", date: "2024:11:03 09:15:08", make: "Apple", model: "iPhone 15 Pro", lens: "iPhone 15 Pro back triple camera 6.765mm f/1.78", iso: 125, aperture: 1.78, shutter: 1.0 / 120, focal: 24, latitude: 40.7128, longitude: -74.0060, place: "New York"),
    Fixture(source: "obama-2.jpg", output: "IMG_5120.JPG", date: "2024:12:21 18:44:55", make: "Apple", model: "iPhone 15 Pro", lens: "iPhone 15 Pro back camera 6.765mm f/1.78", iso: 400, aperture: 1.78, shutter: 1.0 / 40, focal: 24, latitude: 37.7749, longitude: -122.4194, place: "San Francisco"),
    Fixture(source: "jemison.jpg", output: "IMG_6033.JPG", date: "2022:03:08 13:20:19", make: "Sony", model: "ILCE-7M4", lens: "FE 35mm F1.4 GM", iso: 320, aperture: 1.4, shutter: 1.0 / 250, focal: 35, latitude: 34.6134, longitude: -118.2142, place: "Lancaster"),
    Fixture(source: "golden.jpg", output: "IMG_6034.JPG", date: "2022:03:08 15:08:02", make: "Sony", model: "ILCE-7M4", lens: "FE 35mm F1.4 GM", iso: 200, aperture: 1.8, shutter: 1.0 / 800, focal: 35, latitude: 34.6134, longitude: -118.2142, place: "Lancaster"),
    Fixture(source: "dog-2.jpg", output: "IMG_7201.JPG", date: "2023:08:19 11:41:37", make: "Apple", model: "iPhone 14 Pro", lens: "iPhone 14 Pro back triple camera 6.86mm f/1.78", iso: 160, aperture: 1.78, shutter: 1.0 / 200, focal: 24, latitude: -33.8688, longitude: 151.2093, place: "Sydney"),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawDirectory = root.appendingPathComponent("Tests/Fixtures/raw")
let outputDirectory = root.appendingPathComponent("Tests/Fixtures/library")
let missingSources = fixtures.map(\.source).filter {
    !FileManager.default.fileExists(atPath: rawDirectory.appendingPathComponent($0).path)
}
guard missingSources.isEmpty else {
    print("missing required fixture sources: \(missingSources.joined(separator: ", "))")
    exit(1)
}
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    print("cannot create fixture output directory: \(error.localizedDescription)")
    exit(1)
}

func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

var written = 0
var failed = 0
for fixture in fixtures {
    let sourceURL = rawDirectory.appendingPathComponent(fixture.source)
    guard let image = loadImage(sourceURL, maxPixel: 1600) else {
        print("failed \(fixture.source): cannot read")
        failed += 1
        continue
    }
    let outputURL = outputDirectory.appendingPathComponent(fixture.output)

    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: fixture.date,
        kCGImagePropertyExifDateTimeDigitized: fixture.date,
        kCGImagePropertyExifFNumber: fixture.aperture,
        kCGImagePropertyExifExposureTime: fixture.shutter,
        kCGImagePropertyExifISOSpeedRatings: [fixture.iso],
        kCGImagePropertyExifFocalLength: fixture.focal,
        kCGImagePropertyExifLensModel: fixture.lens,
        kCGImagePropertyExifPixelXDimension: image.width,
        kCGImagePropertyExifPixelYDimension: image.height
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: fixture.make,
        kCGImagePropertyTIFFModel: fixture.model,
        kCGImagePropertyTIFFSoftware: "17.1",
        kCGImagePropertyTIFFDateTime: fixture.date
    ]
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: abs(fixture.latitude),
        kCGImagePropertyGPSLatitudeRef: fixture.latitude >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(fixture.longitude),
        kCGImagePropertyGPSLongitudeRef: fixture.longitude >= 0 ? "E" : "W",
        kCGImagePropertyGPSAltitude: 35.0,
        kCGImagePropertyGPSAltitudeRef: 0
    ]
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyOrientation: 1,
        kCGImageDestinationLossyCompressionQuality: 0.84
    ]

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        print("failed \(fixture.output): cannot create destination")
        failed += 1
        continue
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        written += 1
        print("wrote \(fixture.output) \(image.width)x\(image.height) · \(fixture.place)")
    } else {
        print("failed \(fixture.output)")
        failed += 1
    }
}
// One deliberately large, high-entropy photo so the multipart upload path is
// exercised by the UI test (small fixtures stay on the single-PUT fast path).
func writeNoiseFixture() -> Bool {
    let width = 5000
    let height = 4000
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let buffer = context.data else {
        print("failed large fixture: no context")
        return false
    }
    let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for index in 0..<(width * height) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let value = UInt8((seed >> 33) & 0xFF)
        let offset = index * 4
        pixels[offset] = value
        pixels[offset + 1] = value &+ 37
        pixels[offset + 2] = value &+ 91
        pixels[offset + 3] = 255
    }
    guard let image = context.makeImage() else {
        print("failed large fixture: no image")
        return false
    }
    let outputURL = outputDirectory.appendingPathComponent("IMG_9001.JPG")
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2021:04:02 12:00:00",
        kCGImagePropertyExifFNumber: 1.6,
        kCGImagePropertyExifExposureTime: 1.0 / 60,
        kCGImagePropertyExifISOSpeedRatings: [125],
        kCGImagePropertyExifFocalLength: 26,
        kCGImagePropertyExifLensModel: "iPhone 12 Pro back triple camera 4.2mm f/1.6",
        kCGImagePropertyExifPixelXDimension: width,
        kCGImagePropertyExifPixelYDimension: height
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "Apple",
        kCGImagePropertyTIFFModel: "iPhone 12 Pro",
        kCGImagePropertyTIFFSoftware: "16.4"
    ]
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 64.1466,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 21.9426,
        kCGImagePropertyGPSLongitudeRef: "W"
    ]
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyGPSDictionary: gps,
        kCGImageDestinationLossyCompressionQuality: 0.95
    ]
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        print("failed large fixture: cannot create destination")
        return false
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        print("wrote IMG_9001.JPG \(width)x\(height) · \(bytes) bytes")
        return true
    }
    print("failed large fixture")
    return false
}
if !writeNoiseFixture() {
    failed += 1
}

if failed > 0 {
    print("\(failed) required fixtures failed")
    exit(1)
}

print("\(written) fixtures written to \(outputDirectory.path)")
