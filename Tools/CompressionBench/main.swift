// Compression benchmark for Backu.
//
// Standalone (no SPM, no app sources) so it can measure the same ImageIO paths
// the app uses without booting the UI. Every number is produced by the OS
// codecs on the machine that runs it, which is the point: published codec
// comparisons do not tell you what an iPhone will do.
//
//   swiftc -O -o /tmp/backu-compression Tools/CompressionBench/main.swift
//   /tmp/backu-compression thumbs /tmp/out photo1.jpg photo2.heic ...
//   /tmp/backu-compression stream /tmp/out/photo.jpg
//   /tmp/backu-compression psnr /tmp/out/photo.avif /tmp/out/photo.png
//   /tmp/backu-compression decode /tmp/out/photo.avif
//
// Tab-separated output so the shell wrapper can turn it into CSV.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

func fileSize(_ path: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func time<T>(_ repeats: Int = 1, _ body: () -> T) -> (T, Double) {
    var result = body()
    var seconds: [Double] = []
    for _ in 0..<repeats {
        let start = CFAbsoluteTimeGetCurrent()
        result = body()
        seconds.append(CFAbsoluteTimeGetCurrent() - start)
    }
    return (result, median(seconds))
}

func decode(url: URL, maxPixel: Int? = nil) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    if let maxPixel {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    return CGImageSourceCreateImageAtIndex(
        source,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    )
}

func typeIdentifier(for path: String) -> String {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let type = CGImageSourceGetType(source) else { return "" }
    return type as String
}

func uti(for format: String) -> UTType? {
    switch format {
    case "jpeg", "jpg": return .jpeg
    case "heic": return UTType("public.heic")
    case "avif": return UTType("public.avif")
    case "png": return .png
    case "webp": return UTType("org.webmproject.webp")
    case "jxl": return UTType("public.jpeg-xl")
    default: return UTType(filenameExtension: format)
    }
}

func extensionName(for format: String) -> String {
    switch format {
    case "jpeg": return "jpg"
    default: return format
    }
}

// MARK: - PSNR

/// Mean squared error over 8-bit RGBA, after normalising both images to the
/// same pixel grid. Preview quality is only meaningful against the same
/// downscale, so the caller passes the lossless reference.
func psnr(_ a: CGImage, _ b: CGImage) -> Double {
    let width = min(a.width, b.width)
    let height = min(a.height, b.height)
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height * 2)

    func render(_ image: CGImage, into offset: Int) -> Bool {
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.advanced(by: offset),
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
    }

    guard render(a, into: 0), render(b, into: bytesPerRow * height) else { return 0 }
    var sum = 0.0
    for index in 0..<(bytesPerRow * height) {
        let delta = Double(pixels[index]) - Double(pixels[bytesPerRow * height + index])
        sum += delta * delta
    }
    let mse = sum / Double(bytesPerRow * height)
    if mse == 0 { return .infinity }
    return 10 * log10((255.0 * 255.0) / mse)
}

// MARK: - Thumbnail matrix

struct EncodeResult {
    var path: String
    var bytes: Int64
    var seconds: Double
    var psnr: Double
    var decodeMilliseconds: Double
}

func encodePreview(
    source: URL,
    maxPixel: Int,
    format: String,
    quality: Double,
    directory: URL
) -> EncodeResult? {
    guard let ut = uti(for: format),
          let image = decode(url: source, maxPixel: maxPixel) else { return nil }
    let stem = source.deletingPathExtension().lastPathComponent
    let path = directory.appendingPathComponent("\(stem)-\(maxPixel)-\(format)\(Int(quality * 100)).\(extensionName(for: format))")
    try? FileManager.default.removeItem(at: path)

    let created = { () -> Data? in
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            ut.identifier as CFString,
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
    let (data, encodeSeconds) = time(3, created)
    guard let data, (try? data.write(to: path)) != nil else { return nil }

    guard let decoded = decode(url: path) else { return nil }
    let (_, decodeSeconds) = time(9) { decode(url: path) }
    return EncodeResult(
        path: path.path,
        bytes: fileSize(path.path),
        seconds: encodeSeconds * 1000,
        // Measured against the lossless downscale that was handed to the
        // encoder, so quality is comparable across formats and qualities.
        psnr: psnr(decoded, image),
        decodeMilliseconds: decodeSeconds * 1000
    )
}

// MARK: - Incremental / streaming probe

/// Feeds a file to ImageIO in chunks and reports the first byte offset at which
/// an image comes back. A format that cannot decode incrementally only reports
/// the total (or never), which is the difference between "stream me" and
/// "wait for the whole object".
func streamProbe(path: String, maxPixel: Int) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
    let total = data.count
    let chunk = max(16 * 1024, total / 64)
    let source = CGImageSourceCreateIncremental(nil)
    var fed = 0
    var firstImage: Int?
    var firstFullFrame: Int?
    var firstThumbnail: Int?

    func attempt() {
        if firstImage == nil,
           let image = CGImageSourceCreateImageAtIndex(
               source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
           ) {
            firstImage = fed
            _ = image
        }
        if firstThumbnail == nil, maxPixel > 0,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
               kCGImageSourceShouldCache: false,
           ] as CFDictionary) {
            firstThumbnail = fed
            _ = thumbnail
        }
        if firstFullFrame == nil, CGImageSourceGetStatus(source) == .statusComplete {
            firstFullFrame = fed
        }
    }

    let head = min(total, 16 * 1024)
    CGImageSourceUpdateData(source, data.prefix(head) as CFData, false)
    fed = head
    attempt()
    while fed < total {
        let end = min(total, fed + chunk)
        CGImageSourceUpdateData(source, data[fed..<end] as CFData, end == total)
        fed = end
        attempt()
    }
    func percent(_ value: Int?) -> String {
        guard let value else { return "never" }
        return String(format: "%.1f%%", 100 * Double(value) / Double(total))
    }
    print([
        URL(fileURLWithPath: path).lastPathComponent,
        typeIdentifier(for: path),
        String(total),
        percent(firstImage),
        percent(firstThumbnail),
        percent(firstFullFrame),
    ].joined(separator: "\t"))
}

// MARK: - Commands

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"

switch command {
case "thumbs":
    guard arguments.count > 4 else {
        FileHandle.standardError.write(Data("usage: thumbs <outdir> <maxPixel> <files...>\n".utf8))
        exit(2)
    }
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let maxPixel = Int(arguments[3]) ?? 900
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    print("file\tformat\tquality\tbytes\tencode_ms\tdecode_ms\tpsnr")
    for path in arguments.dropFirst(4) {
        let source = URL(fileURLWithPath: path)
        for format in ["jpeg", "heic", "avif"] {
            for quality in [0.7, 0.8, 0.9] {
                if let result = encodePreview(
                    source: source,
                    maxPixel: maxPixel,
                    format: format,
                    quality: quality,
                    directory: directory
                ) {
                    print([
                        source.lastPathComponent,
                        format,
                        String(format: "%.2f", quality),
                        String(result.bytes),
                        String(format: "%.1f", result.seconds),
                        String(format: "%.2f", result.decodeMilliseconds),
                        String(format: "%.2f", result.psnr),
                    ].joined(separator: "\t"))
                }
            }
        }
    }

case "psnr":
    guard arguments.count > 3,
          let a = decode(url: URL(fileURLWithPath: arguments[2])),
          let b = decode(url: URL(fileURLWithPath: arguments[3])) else { exit(2) }
    print(String(format: "%.3f", psnr(a, b)))

case "stream":
    for path in arguments.dropFirst(2) {
        streamProbe(path: path, maxPixel: 1600)
    }

case "decode":
    print("file\ttype\tbytes\tfull_ms\tthumb1200_ms")
    for path in arguments.dropFirst(2) {
        guard let image = decode(url: URL(fileURLWithPath: path)), image.width > 0 else {
            print("\(path)\tunreadable")
            continue
        }
        let (_, full) = time(9) { decode(url: URL(fileURLWithPath: path)) }
        let (_, thumb) = time(9) { decode(url: URL(fileURLWithPath: path), maxPixel: 1200) }
        print([
            URL(fileURLWithPath: path).lastPathComponent,
            typeIdentifier(for: path),
            String(fileSize(path)),
            String(format: "%.2f", full * 1000),
            String(format: "%.2f", thumb * 1000),
        ].joined(separator: "\t"))
    }

case "formats":
    let sources = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
    let destinations = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    for type in ["public.jpeg", "public.heic", "public.avif", "public.jpeg-xl", "org.webmproject.webp"] {
        print("\(type)\tdecode=\(sources.contains(type))\tencode=\(destinations.contains(type))")
    }

default:
    print("""
    usage: backu-compression <command> ...

      thumbs <outdir> <maxPixel> <files...>   encode previews in jpeg/heic/avif
      psnr <a> <b>                            PSNR between two images
      stream <files...>                       incremental decode byte offsets
      decode <files...>                       full and 1200px decode timings
      formats                                 codec availability on this OS
    """)
}
