// Generates a synthetic library for the scroll-performance test.
//
//   swift Tools/Performance/make-large-library.swift
//   ./Tools/Performance/setup.sh
//
// 300 small (900×900) JPEGs with distinct gradients and noise, EXIF dates
// spread across 2012–2026 and GPS/camera metadata. The output directory is
// git-ignored: these photos exist only to give the grid enough rows to scroll.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let count = 300
let side = 900
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("Tests/Fixtures/performance/library")
try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Small deterministic PRNG so repeated runs produce the same library.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: side * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        min(1, max(0, b * (1 + s * (cos(h * 2 * .pi) * 0.5)))),
        min(1, max(0, b * (1 + s * (cos((h - 1.0 / 3) * 2 * .pi) * 0.5)))),
        min(1, max(0, b * (1 + s * (cos((h - 2.0 / 3) * 2 * .pi) * 0.5)))),
        a
    ])!
}

let calendar = Calendar(identifier: .gregorian)
var utc = calendar
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let start = utc.date(from: DateComponents(year: 2012, month: 1, day: 1))!

var random = SplitMix64(state: 0xBAC4_0000_1234_5678)
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.timeZone = TimeZone(secondsFromGMT: 0)
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

var written = 0
for index in 0..<count {
    // Spread across the whole range with a slight cluster per month.
    let fraction = (Double(index) + random.unit() * 0.8) / Double(count)
    let date = start.addingTimeInterval(fraction * 14.5 * 365 * 24 * 3600)
    let hue = random.unit()
    let secondHue = (hue + 0.25 + random.unit() * 0.4).truncatingRemainder(dividingBy: 1)
    let saturation = 0.25 + random.unit() * 0.6

    context.setFillColor(hsb(hue, saturation * 0.7, 0.75))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    // Diagonal sweep: the dominant colour of each photo.
    let colours = [hsb(hue, saturation, 0.9), hsb(secondHue, saturation * 0.8, 0.55)] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(random.int(0...400))),
            end: CGPoint(x: CGFloat(side), y: CGFloat(random.int(400...side))),
            options: []
        )
    }

    // A soft sun / horizon so thumbnails read as photos at a glance.
    let sun = hsb((hue + 0.08).truncatingRemainder(dividingBy: 1), 0.15, 1.0, 0.75)
    if let glow = CGGradient(colorsSpace: colorSpace, colors: [sun, hsb(hue, saturation, 0.8, 0)] as CFArray, locations: [0, 1]) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: CGFloat(random.int(120...side - 120)), y: CGFloat(random.int(200...side - 120))),
            startRadius: 0,
            endCenter: CGPoint(x: Double(side) / 2, y: Double(side) / 2),
            endRadius: Double(random.int(220...640)),
            options: []
        )
    }

    // Fine grain: many small translucent marks, cheap to draw and very
    // obviously different once the grid starts scrolling fast.
    for _ in 0..<70 {
        let size = CGFloat(random.int(3...26))
        context.setFillColor(hsb(random.unit(), 0.3, random.unit() > 0.5 ? 0.98 : 0.25, 0.06 + random.unit() * 0.16))
        context.fill(CGRect(
            x: CGFloat(random.int(0...side)),
            y: CGFloat(random.int(0...side)),
            width: size,
            height: size * CGFloat(0.3 + random.unit() * 1.7)
        ))
    }

    guard let image = context.makeImage() else { continue }

    let filename = String(format: "IMG_%04d.JPG", 1000 + index)
    let outputURL = outputDirectory.appendingPathComponent(filename)
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date),
        kCGImagePropertyExifDateTimeDigitized: formatter.string(from: date),
        kCGImagePropertyExifFNumber: 1.6 + random.unit() * 1.2,
        kCGImagePropertyExifExposureTime: 1.0 / Double(random.int(40...500)),
        kCGImagePropertyExifISOSpeedRatings: [random.int(32...1600)],
        kCGImagePropertyExifFocalLength: Double(random.int(13...70)),
        kCGImagePropertyExifLensModel: "Backu Perf synthetic lens",
        kCGImagePropertyExifPixelXDimension: side,
        kCGImagePropertyExifPixelYDimension: side
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "Backu",
        kCGImagePropertyTIFFModel: "Perf Camera \(random.int(1...6))",
        kCGImagePropertyTIFFSoftware: "26.0",
        kCGImagePropertyTIFFDateTime: formatter.string(from: date)
    ]
    let latitude = -60.0 + random.unit() * 120
    let longitude = -170.0 + random.unit() * 340
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: abs(latitude),
        kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(longitude),
        kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W",
        kCGImagePropertyGPSAltitude: random.unit() * 2400,
        kCGImagePropertyGPSAltitudeRef: 0
    ]
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyOrientation: 1,
        kCGImageDestinationLossyCompressionQuality: 0.82
    ]

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        print("skip \(filename): cannot create destination")
        continue
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        written += 1
    } else {
        print("failed \(filename)")
    }
}

let bytes = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path))?.count ?? 0
print("wrote \(written) photos (\(bytes) files) to \(outputDirectory.path)")
