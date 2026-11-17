import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(Darwin)
import Darwin
#endif

// Standalone benchmark for thumbnail atlases.
//
// It is compiled with swiftc against the app's real atlas format and the real
// S3 client, so the numbers come from the same encoder, decoder and signer the
// app ships:
//
//   swiftc -O -o /tmp/backu-atlas-bench \
//     Sources/Core/Models/StorageProvider.swift \
//     Sources/Core/Models/ServerConfig.swift \
//     Sources/Core/S3/*.swift \
//     Sources/Core/Library/ThumbnailAtlas.swift \
//     Tools/AtlasBench/main.swift
//
// Tools/AtlasBench/run.sh builds it, starts shaped mock buckets and writes a
// JSON report plus a Markdown summary.

// MARK: - Options

struct Options {
    var endpoint = URL(string: "http://127.0.0.1:9301")!
    var bucket = "backu-test"
    var accessKey = "testkey"
    var secret = "testsecret"
    var region = "us-east-1"
    var fixtures = "Tests/Fixtures/raw"
    var extraFixtures = "Tests/Fixtures/marketing/raw"
    var photoLimit = 300
    var mode = "all" // local, network, all
    var runs = 3
    var uploadPrefix = "atlas-bench"
    var output: String?
    var profile = "shaped"
    var corpusDirectory = "Tests/Fixtures/atlas-corpus"
    var seedIndex = false
    var noAtlas = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            func value() -> String {
                index += 1
                return index < arguments.count ? arguments[index] : ""
            }
            switch name {
            case "--endpoint": if let url = URL(string: value()) { options.endpoint = url }
            case "--bucket": options.bucket = value()
            case "--access-key": options.accessKey = value()
            case "--secret": options.secret = value()
            case "--region": options.region = value()
            case "--fixtures": options.fixtures = value()
            case "--extra-fixtures": options.extraFixtures = value()
            case "--photos": options.photoLimit = max(1, Int(value()) ?? 300)
            case "--mode": options.mode = value()
            case "--runs": options.runs = max(1, Int(value()) ?? 3)
            case "--prefix": options.uploadPrefix = value()
            case "--profile": options.profile = value()
            case "--output": options.output = value()
            case "--corpus": options.corpusDirectory = value()
      case "--seed-index": options.seedIndex = true
      case "--no-atlas": options.noAtlas = true
            case "--help", "-h":
                print(Self.help)
                exit(0)
            default:
                print("Unknown option \(name)\n")
                print(Self.help)
                exit(2)
            }
            index += 1
        }
        return options
    }

    static let help = """
    Usage: backu-atlas-bench [options]

      --endpoint URL        default http://127.0.0.1:9301
      --bucket NAME         default backu-test
      --access-key KEY      default testkey
      --secret SECRET       default testsecret
      --region REGION       default us-east-1
      --fixtures DIR        photo directory (default Tests/Fixtures/raw)
      --extra-fixtures DIR  additional photos, mixed in (default marketing raw)
      --photos N            number of photos to use (default 300)
      --mode MODE           local, network or all (default all)
      --runs N              measured network runs (default 3)
      --prefix KEY          object key prefix for uploads
      --profile NAME        label written to the report
      --output PATH         JSON report path
      --corpus DIR          generated crop cache (default Tests/Fixtures/atlas-corpus)
      --seed-index          write .backu/index.json for a remote-only UI experiment
      --no-atlas            seed the index without atlas pointers (baseline)
    """
}

// MARK: - Report types

struct ByteStat: Codable {
    var totalBytes: Int
    var perTileBytes: Double
}

struct CodecRow: Codable {
    var name: String
    var level: String
    var cell: Int
    var codec: String
    var quality: Double
    var encodedBytes: Int
    var tilesPerSheet: Int
    var bytesPerTile: Double
    var encodeMillis: Double
    var decodeMillisPerTile: Double
}

struct ScenarioRow: Codable {
    var name: String
    var detail: String
    var tiles: Int
    var requests: Int
    var bytes: Int
    var firstTileMillis: Double
    var allTilesMillis: Double
    var decodeMillisPerTile: Double
    var runs: [Double]
}

struct Report: Codable {
    var profile: String
    var photos: Int
    var generatedAt: String
    var codecs: [CodecRow]
    var library: [String: ByteStat]
    var scenarios: [ScenarioRow]
    var notes: [String]
}

// MARK: - Image helpers

func loadPhotos(_ options: Options) -> [(name: String, url: URL)] {
    var urls: [URL] = []
    for directory in [options.fixtures, options.extraFixtures] {
        let dir = URL(fileURLWithPath: directory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        urls.append(contentsOf: files.filter {
            ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }
    var selected = Array(urls.prefix(options.photoLimit))
    if selected.count < options.photoLimit {
        // The scroll fixtures are synthetic gradients; codec sizes measured on
        // them flatter every encoder. Real photos are expanded into
        // deterministic crops so the corpus has photographic entropy at the
        // requested count.
        let corpus = expandCorpus(
            sources: selected,
            target: options.photoLimit,
            directory: URL(fileURLWithPath: options.corpusDirectory)
        )
        if corpus.count > selected.count {
            selected = corpus
        }
    }
    // Interleave sources so a "first screen" is not 15 crops of one photo.
    var state: UInt64 = 0x9E3779B97F4A7C15
    func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    for index in stride(from: selected.count - 1, to: 0, by: -1) {
        selected.swapAt(index, Int(next() % UInt64(index + 1)))
    }
    return selected.enumerated().map { index, url in
        ("photo-\(index)-\(String(url.lastPathComponent.prefix(24)))", url)
    }
}

/// Crops real photographs into enough distinct 1600 px tiles to model a
/// library. Crops are cached on disk, so the first run pays the cost.
func expandCorpus(sources: [URL], target: Int, directory: URL) -> [URL] {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let existing = ((try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    if existing.count >= target { return Array(existing.prefix(target)) }

    print("→ Expanding \(sources.count) real photos into \(target) crops")
    var written = existing
    let fractions: [CGFloat] = [0.6, 0.44, 0.32]
    let divisions = 4
    outer: for source in sources {
        guard let image = loadUpright(source, maxPixel: 2000) else { continue }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        for fraction in fractions {
            let side = min(width, height) * fraction
            for row in 0..<divisions {
                for column in 0..<divisions {
                    let maxX = max(0, width - side)
                    let maxY = max(0, height - side)
                    let x = maxX * CGFloat(column) / CGFloat(divisions - 1)
                    let y = maxY * CGFloat(row) / CGFloat(divisions - 1)
                    guard let crop = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
                        continue
                    }
                    guard let scaled = renderSquare(crop, side: 1600),
                          let data = encode(scaled, codec: .jpeg, quality: 0.92) else { continue }
                    let url = directory.appendingPathComponent(
                        String(format: "crop-%03d-%@.jpg", written.count, source.deletingPathExtension().lastPathComponent)
                    )
                    try? data.write(to: url)
                    written.append(url)
                    if written.count >= target { break outer }
                }
            }
        }
    }
    return written
}

func loadUpright(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// EXIF-upright, aspect-fill square at `side` pixels. This is what an upload
/// would render from the original with ImageIO's thumbnail path.
func squareTile(url: URL, side: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: side * 2
    ]
    guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return renderSquare(upright, side: side)
}

func renderSquare(_ image: CGImage, side: Int) -> CGImage? {
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
    let scale = max(CGFloat(side) / width, CGFloat(side) / height)
    let rect = CGRect(
        x: (CGFloat(side) - width * scale) / 2,
        y: (CGFloat(side) - height * scale) / 2,
        width: width * scale,
        height: height * scale
    )
    context.interpolationQuality = .high
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.draw(image, in: rect)
    return context.makeImage()
}

/// Current app behaviour: longest edge 900 px, JPEG q0.8, upright.
func legacyThumbnail(url: URL, maxPixel: Int = 900, quality: Double = 0.8) -> Data? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return encode(image, codec: .jpeg, quality: quality)
}

func encode(_ image: CGImage, codec: AtlasCodec, quality: Double) -> Data? {
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
    return data as Data
}

func decodeTime(data: Data, cropCells: Int, layout: AtlasLayout?, iterations: Int) -> Double {
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .nan }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return .nan
        }
        if let layout {
            for cell in 0..<min(cropCells, layout.capacity) {
                _ = image.cropping(to: layout.rect(cell: cell))
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        samples.append(elapsed / Double(max(1, cropCells)))
    }
    samples.sort()
    return samples[samples.count / 2]
}

func measure<T>(_ body: () -> T) -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return (value, elapsed)
}

func kb(_ bytes: Int) -> String {
    String(format: "%.1f KB", Double(bytes) / 1024)
}

// MARK: - Network harness

struct FetchOutcome {
    var requests: Int
    var bytes: Int
    var firstTile: Double
    var allTiles: Double
}

enum FetchStrategy {
    /// One 900 px JPEG per photo, as the app ships today.
    case legacyIndividual
    /// One correctly-sized JPEG per photo, no atlas.
    case individual
    /// Atlas only.
    case atlas
}

/// Downloads a scroll's worth of tiles and decodes them the way the grid does,
/// returning when the first tile is paintable and when the last one is.
@MainActor
final class ScrollReplay {
    let client: S3Client

    init(client: S3Client) {
        self.client = client
    }

    /// - Parameters:
    ///   - tiles: tile index into the library, in display order.
    ///   - individualKeys: tile index -> object key for individual strategies.
    ///   - atlas: level plus tile index -> sheet object key, for atlas strategies.
    func replay(
        tiles: [Int],
        individualKeys: [Int: String]?,
        atlas: (level: ThumbnailAtlas.Level, keyForTile: [Int: String])?,
        concurrency: Int
    ) async -> FetchOutcome {
        let started = DispatchTime.now().uptimeNanoseconds
        var requests = 0
        var bytes = 0
        var painted = 0
        var firstTileAt: Double?
        let lock = NSLock()
        let client = self.client

        func paint(count: Int) {
            lock.lock()
            painted += count
            if firstTileAt == nil { firstTileAt = seconds(since: started) }
            lock.unlock()
        }

        func record(requestCount: Int, byteCount: Int) {
            lock.lock()
            requests += requestCount
            bytes += byteCount
            lock.unlock()
        }

        if let atlas {
            // Distinct sheets in the order their first tile appears, so the
            // replay asks for what the viewport asks for.
            var orderedSheets: [String] = []
            var seen = Set<String>()
            for tile in tiles {
                guard let key = atlas.keyForTile[tile] else { continue }
                if seen.insert(key).inserted { orderedSheets.append(key) }
            }
            let cellCounts = Dictionary(grouping: tiles) { atlas.keyForTile[$0] ?? "" }.mapValues(\.count)
            await withTaskGroup(of: (String, Data?).self) { group in
                var iterator = orderedSheets.makeIterator()
                func addNext() {
                    guard let sheet = iterator.next() else { return }
                    group.addTask {
                        let data = try? await client.getObject(key: sheet)
                        return (sheet, data)
                    }
                }
                for _ in 0..<concurrency { addNext() }
                while let (sheet, data) = await group.next() {
                    if let data {
                        record(requestCount: 1, byteCount: data.count)
                        let decoded = AtlasDecoder.decode(
                            data: data,
                            group: sheet,
                            level: atlas.level
                        )
                        if decoded != nil { paint(count: cellCounts[sheet] ?? 1) }
                    }
                    addNext()
                }
            }
        } else if let keys = individualKeys {
            await withTaskGroup(of: (Int, Data?).self) { group in
                var iterator = tiles.makeIterator()
                func addNext() {
                    guard let tile = iterator.next() else { return }
                    group.addTask {
                        guard let key = keys[tile] else { return (tile, nil) }
                        return (tile, try? await client.getObject(key: key))
                    }
                }
                for _ in 0..<concurrency { addNext() }
                while let (_, data) = await group.next() {
                    if let data {
                        record(requestCount: 1, byteCount: data.count)
                        _ = AtlasDecoder.decode(
                            data: data,
                            group: "individual",
                            level: .grid
                        )
                        paint(count: 1)
                    }
                    addNext()
                }
            }
        }

        let all = seconds(since: started)
        return FetchOutcome(
            requests: requests,
            bytes: bytes,
            firstTile: firstTileAt ?? all,
            allTiles: all
        )
    }

    private func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

// MARK: - Main

let options = Options.parse(CommandLine.arguments)
let photos = loadPhotos(options)
guard !photos.isEmpty else {
    print("No fixture photos found. Run Tools/Fixtures/download-fixtures.sh first.")
    exit(1)
}

var notes: [String] = []
var codecRows: [CodecRow] = []
var libraryBytes: [String: ByteStat] = [:]

print("→ \(photos.count) photos from \(options.fixtures) and \(options.extraFixtures)")

// Source tiles, rendered once per size. Like the app, the upload path starts
// from the upright original.
let tileCache = TileCache()
let legacyData: [Data] = photos.compactMap { legacyThumbnail(url: $0.url) }
print("→ current 900 px thumbnails: \(kb(legacyData.reduce(0) { $0 + $1.count })) total, \(kb(legacyData.isEmpty ? 0 : legacyData.reduce(0) { $0 + $1.count } / legacyData.count)) each")
libraryBytes["current-900-jpeg-q80"] = ByteStat(
    totalBytes: legacyData.reduce(0) { $0 + $1.count },
    perTileBytes: legacyData.isEmpty ? 0 : Double(legacyData.reduce(0) { $0 + $1.count }) / Double(legacyData.count)
)

// MARK: Local encode/decode matrix

if options.mode == "local" || options.mode == "all" {
    print("\n→ Encoding matrix")

    let variants: [(name: String, layout: AtlasLayout, codec: AtlasCodec, quality: Double)] = [
        ("grid 384 jpeg q62", AtlasLayout(cell: 384, columns: 6, rows: 6), .jpeg, 0.62),
        ("grid 384 jpeg q75", AtlasLayout(cell: 384, columns: 6, rows: 6), .jpeg, 0.75),
        ("grid 256 jpeg q62", AtlasLayout(cell: 256, columns: 8, rows: 8), .jpeg, 0.62),
        ("grid 384 heic q62", AtlasLayout(cell: 384, columns: 6, rows: 6), .heic, 0.62),
        ("grid 384 avif q62", AtlasLayout(cell: 384, columns: 6, rows: 6), .avif, 0.62),
        ("preview 128 jpeg q45", AtlasLayout(cell: 128, columns: 8, rows: 8), .jpeg, 0.45),
        ("preview 96 jpeg q45", AtlasLayout(cell: 96, columns: 8, rows: 8), .jpeg, 0.45),
        ("preview 64 jpeg q45", AtlasLayout(cell: 64, columns: 8, rows: 8), .jpeg, 0.45),
        ("preview 64 jpeg q30", AtlasLayout(cell: 64, columns: 8, rows: 8), .jpeg, 0.30),
        ("preview 64 heic q35", AtlasLayout(cell: 64, columns: 8, rows: 8), .heic, 0.35),
        ("preview 64 avif q35", AtlasLayout(cell: 64, columns: 8, rows: 8), .avif, 0.35)
    ]

    for variant in variants {
        let step = max(1, photos.count / variant.layout.capacity)
        let sample = photos.enumerated().filter { $0.offset % step == 0 }.map(\.element).prefix(variant.layout.capacity)
        let members: [ThumbnailAtlas.Member] = sample.enumerated().compactMap { index, photo in
            guard let tile = tileCache.tile(url: photo.url, side: variant.layout.cell) else {
                return nil
            }
            return ThumbnailAtlas.Member(id: photo.name, digest: "digest-\(index)", image: tile)
        }
        let (sheet, encodeMillis) = measure {
            AtlasEncoder.encode(
                members: members,
                levelName: "sweep",
                layout: variant.layout,
                keyPrefix: "\(ThumbnailAtlas.pathPrefix)/sweep",
                codec: variant.codec,
                quality: variant.quality
            )
        }
        guard let sheet else { continue }
        let decode = decodeTime(
            data: sheet.data,
            cropCells: members.count,
            layout: variant.layout,
            iterations: 15
        )
        let row = CodecRow(
            name: variant.name,
            level: "sweep",
            cell: variant.layout.cell,
            codec: variant.codec.rawValue,
            quality: variant.quality,
            encodedBytes: sheet.data.count,
            tilesPerSheet: members.count,
            bytesPerTile: Double(sheet.data.count) / Double(members.count),
            encodeMillis: encodeMillis,
            decodeMillisPerTile: decode
        )
        codecRows.append(row)
        print(String(
            format: "  %-22s %8s/sheet %7s/tile  encode %6.1f ms  decode %5.2f ms/tile",
            (variant.name as NSString).utf8String!,
            (kb(sheet.data.count) as NSString).utf8String!,
            (String(format: "%.0f B", row.bytesPerTile) as NSString).utf8String!,
            encodeMillis,
            decode
        ))
    }

    // Individual correctly-sized thumbnails are the honest non-atlas baseline.
    for (label, side, quality) in [("individual-384-jpeg-q62", 384, 0.62), ("individual-900-jpeg-q80", 900, 0.8)] {
        var total = 0
        var encodeTotal = 0.0
        var decodeTotal = 0.0
        var count = 0
        for photo in photos.prefix(ThumbnailAtlas.groupCapacity) {
            guard let tile = tileCache.tile(url: photo.url, side: side) else { continue }
            let (data, millis) = measure { encode(tile, codec: .jpeg, quality: quality) }
            guard let data else { continue }
            total += data.count
            encodeTotal += millis
            decodeTotal += decodeTime(data: data, cropCells: 1, layout: nil, iterations: 10)
            count += 1
        }
        guard count > 0 else { continue }
        let row = CodecRow(
            name: label,
            level: "individual",
            cell: side,
            codec: "jpeg",
            quality: quality,
            encodedBytes: total,
            tilesPerSheet: count,
            bytesPerTile: Double(total) / Double(count),
            encodeMillis: encodeTotal,
            decodeMillisPerTile: decodeTotal / Double(count)
        )
        codecRows.append(row)
        print(String(
            format: "  %-22s %8s total %7.0f B/tile encode %6.1f ms (%d)  decode %5.2f ms/tile",
            (label as NSString).utf8String!,
            (kb(total) as NSString).utf8String!,
            row.bytesPerTile,
            encodeTotal,
            count,
            row.decodeMillisPerTile
        ))
    }

    // Whole-library sizes at the product's levels.
    for level in ThumbnailAtlas.Level.allCases {
        var totalBytes = 0
        var encodedTiles = 0
        var sheets = 0
        var encodeMillis = 0.0
        let tileSide = level.layout.cell
        let members = photos.compactMap { photo -> ThumbnailAtlas.Member? in
            guard let tile = tileCache.tile(url: photo.url, side: tileSide) else { return nil }
            return ThumbnailAtlas.Member(id: photo.name, digest: "digest-\(photo.name)", image: tile)
        }
        for start in stride(from: 0, to: members.count, by: ThumbnailAtlas.groupCapacity) {
            let batch = Array(members[start..<min(members.count, start + ThumbnailAtlas.groupCapacity)])
            let (sheet, millis) = measure {
                AtlasEncoder.encode(members: batch, level: level)
            }
            guard let sheet else { continue }
            totalBytes += sheet.data.count
            encodedTiles += batch.count
            sheets += 1
            encodeMillis += millis
        }
        guard encodedTiles > 0 else { continue }
        libraryBytes[level.rawValue] = ByteStat(
            totalBytes: totalBytes,
            perTileBytes: Double(totalBytes) / Double(encodedTiles)
        )
        print("  \(level.rawValue) level: \(sheets) sheets, \(kb(totalBytes)) for \(encodedTiles) photos, \(String(format: "%.2f", encodeMillis)) ms encode")
    }
}

// MARK: Network

struct AtlasSet {
    var level: ThumbnailAtlas.Level
    var layout: AtlasLayout
    var keyForTile: [Int: String]
    /// Object key -> group, for seeding an index.
    var groupByKey: [String: String]
    var sheets: [(key: String, data: Data)]

    func group(byKey key: String) -> String? { groupByKey[key] }
}

func buildSet(
    level: ThumbnailAtlas.Level,
    layout: AtlasLayout,
    photos: [(name: String, url: URL)],
    cache: TileCache,
    client: S3Client,
    upload: Bool
) async -> AtlasSet {
    let members = photos.compactMap { photo -> ThumbnailAtlas.Member? in
        guard let tile = cache.tile(url: photo.url, side: layout.cell) else { return nil }
        return ThumbnailAtlas.Member(
            id: photo.name,
            digest: "digest-\(photo.name)",
            image: tile
        )
    }
    var keyForTile: [Int: String] = [:]
    var groupByKey: [String: String] = [:]
    var sheets: [(key: String, data: Data)] = []
    for start in stride(from: 0, to: members.count, by: layout.capacity) {
        let batch = Array(members[start..<min(members.count, start + layout.capacity)])
        guard let sheet = AtlasEncoder.encode(
            members: batch,
            levelName: level.rawValue,
            layout: layout,
            // Exactly the key the app looks for, so a seeded bucket can be
            // opened by the real app in the UI experiment.
            keyPrefix: level.keyPrefix,
            codec: level.codec,
            quality: level.quality
        ) else { continue }
        sheets.append((sheet.key, sheet.data))
        groupByKey[sheet.key] = sheet.group
        for offset in 0..<batch.count {
            keyForTile[start + offset] = sheet.key
        }
        if upload {
            try? await client.putObject(key: sheet.key, data: sheet.data, contentType: level.codec.contentType)
        }
    }
    return AtlasSet(
        level: level,
        layout: layout,
        keyForTile: keyForTile,
        groupByKey: groupByKey,
        sheets: sheets
    )
}

if options.mode == "network" || options.mode == "all" {
    print("\n→ Uploading fixtures to \(options.endpoint)")

    let connection = S3Connection(
        endpoint: options.endpoint,
        region: options.region,
        bucket: options.bucket,
        pathStyle: true
    )
    let credentials = S3Credentials(accessKeyID: options.accessKey, secretAccessKey: options.secret)
    let client = S3Client(
        connection: connection,
        credentials: credentials,
        headCache: .disabled()
    )

    // Correctly-sized individual thumbnails, for the no-atlas baseline.
    var individual384: [Data] = []
    var individual384Encode = 0.0
    for photo in photos {
        guard let tile = tileCache.tile(url: photo.url, side: 384) else { continue }
        let (data, millis) = measure { encode(tile, codec: .jpeg, quality: 0.62) }
        individual384Encode += millis
        if let data { individual384.append(data) }
    }
    libraryBytes["individual-384-jpeg-q62"] = ByteStat(
        totalBytes: individual384.reduce(0) { $0 + $1.count },
        perTileBytes: individual384.isEmpty ? 0 : Double(individual384.reduce(0) { $0 + $1.count }) / Double(individual384.count)
    )
    notes.append(String(format: "individual 384 encode: %.1f ms/photo", individual384Encode / Double(max(1, individual384.count))))

    let legacyKeys = (0..<legacyData.count).map { "\(options.uploadPrefix)/current-900/\($0).jpg" }
    let individualKeys = (0..<individual384.count).map { "\(options.uploadPrefix)/individual-384/\($0).jpg" }

    let uploadStarted = DispatchTime.now().uptimeNanoseconds
    for (index, data) in legacyData.enumerated() {
        try await client.putObject(key: legacyKeys[index], data: data, contentType: "image/jpeg")
    }
    for (index, data) in individual384.enumerated() {
        try await client.putObject(key: individualKeys[index], data: data, contentType: "image/jpeg")
    }

    let gridSet = await buildSet(
        level: .grid,
        layout: .init(cell: 384, columns: 6, rows: 6),
        photos: photos,
        cache: tileCache,
        client: client,
        upload: true
    )
    let previewSet = await buildSet(
        level: .preview,
        layout: .init(cell: 64, columns: 6, rows: 6),
        photos: photos,
        cache: tileCache,
        client: client,
        upload: true
    )
    let uploadMillis = Double(DispatchTime.now().uptimeNanoseconds - uploadStarted) / 1_000_000
    notes.append(String(format: "uploaded %d objects in %.0f ms", legacyData.count + individual384.count + gridSet.sheets.count + previewSet.sheets.count, uploadMillis))

    let legacyKeyByTile = Dictionary(uniqueKeysWithValues: legacyKeys.enumerated().map { ($0.offset, $0.element) })
    let individualKeyByTile = Dictionary(uniqueKeysWithValues: individualKeys.enumerated().map { ($0.offset, $0.element) })

    // 15 tiles per screen (3-column iPhone, five visible rows).
    let screens = 10
    let tilesPerScreen = 15
    let scrollTiles = Array(0..<min(photos.count, screens * tilesPerScreen))
    let firstScreen = Array(scrollTiles.prefix(tilesPerScreen))

    @MainActor
    func runScenario(
        name: String,
        detail: String,
        tiles: [Int],
        atlas: AtlasSet?,
        individual: [Int: String]?,
        concurrency: Int
    ) async -> ScenarioRow {
        let replay = ScrollReplay(client: client)
        var outcomes: [FetchOutcome] = []
        var measurements: [Double] = []
        for _ in 0..<options.runs {
            let outcome = await replay.replay(
                tiles: tiles,
                individualKeys: individual,
                atlas: atlas.map { (level: $0.level, keyForTile: $0.keyForTile) },
                concurrency: concurrency
            )
            outcomes.append(outcome)
            measurements.append(outcome.allTiles * 1000)
        }
        let median = outcomes.sorted { $0.allTiles < $1.allTiles }[outcomes.count / 2]
        return ScenarioRow(
            name: name,
            detail: detail,
            tiles: tiles.count,
            requests: median.requests,
            bytes: median.bytes,
            firstTileMillis: median.firstTile * 1000,
            allTilesMillis: median.allTiles * 1000,
            decodeMillisPerTile: 0,
            runs: measurements
        )
    }

    var scenarios: [ScenarioRow] = []

    scenarios.append(await runScenario(
        name: "cold first screen — current",
        detail: "15 × 900 px individual JPEGs, 3 concurrent",
        tiles: firstScreen,
        atlas: nil,
        individual: legacyKeyByTile,
        concurrency: 3
    ))

    scenarios.append(await runScenario(
        name: "fast scroll 10 screens — current",
        detail: "150 × 900 px individual JPEGs, 3 concurrent",
        tiles: scrollTiles,
        atlas: nil,
        individual: legacyKeyByTile,
        concurrency: 3
    ))

    scenarios.append(await runScenario(
        name: "cold first screen — right-sized",
        detail: "15 × 384 px individual JPEGs, 6 concurrent",
        tiles: firstScreen,
        atlas: nil,
        individual: individualKeyByTile,
        concurrency: 6
    ))

    scenarios.append(await runScenario(
        name: "fast scroll 10 screens — right-sized",
        detail: "150 × 384 px individual JPEGs, 6 concurrent",
        tiles: scrollTiles,
        atlas: nil,
        individual: individualKeyByTile,
        concurrency: 6
    ))

    scenarios.append(await runScenario(
        name: "cold first screen — grid atlas",
        detail: "one 6×6 HEIC sheet, 36 tiles",
        tiles: firstScreen,
        atlas: gridSet,
        individual: nil,
        concurrency: 6
    ))

    scenarios.append(await runScenario(
        name: "fast scroll 10 screens — grid atlas",
        detail: "150 tiles from 5 HEIC sheets",
        tiles: scrollTiles,
        atlas: gridSet,
        individual: nil,
        concurrency: 6
    ))

    scenarios.append(await runScenario(
        name: "cold first screen — preview atlas",
        detail: "one 6×6 preview sheet, 64 px cells",
        tiles: firstScreen,
        atlas: previewSet,
        individual: nil,
        concurrency: 6
    ))

    scenarios.append(await runScenario(
        name: "fast scroll 10 screens — preview atlas",
        detail: "150 previews from 5 sheets",
        tiles: scrollTiles,
        atlas: previewSet,
        individual: nil,
        concurrency: 6
    ))

    // Pulling every preview into the local cache once is the offline-scroll
    // story: after this, any part of the library paints from memory.
    let allTiles = Array(0..<min(photos.count, previewSet.keyForTile.count))
    scenarios.append(await runScenario(
        name: "bulk preview pull (whole library)",
        detail: "\(allTiles.count) previews from \(previewSet.sheets.count) sheets",
        tiles: allTiles,
        atlas: previewSet,
        individual: nil,
        concurrency: 6
    ))

    if options.seedIndex {
        // Makes the app see this bucket as a library written by another
        // device: every photo is remote-only, every one carries an atlas
        // pointer, and the per-photo thumbnail is there as a fallback.
        let entries = photos.enumerated().compactMap { index, photo -> RemoteIndexDocument.PhotoEntry? in
            guard let gridKey = gridSet.keyForTile[index],
                  let group = gridSet.group(byKey: gridKey),
                  let legacyKey = legacyKeyByTile[index] else { return nil }
            let date = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -index,
                to: Date()
            ) ?? Date()
            return RemoteIndexDocument.PhotoEntry(
                id: "seed-\(index)",
                key: legacyKey,
                sidecarKey: legacyKey + ".json",
                thumbnailKey: legacyKey,
                atlasGroup: options.noAtlas ? nil : group,
                atlasCell: options.noAtlas ? nil : index % ThumbnailAtlas.groupCapacity,
                sha256: "seed-digest-\(index)",
                filename: "IMG_\(1000 + index).jpg",
                capturedAt: date,
                width: 1600,
                height: 1600,
                isVideo: false,
                duration: nil,
                favorite: index % 17 == 0,
                tags: [],
                personIDs: [],
                camera: "Apple iPhone 17 Pro",
                lens: "Main Camera",
                place: nil,
                latitude: nil,
                longitude: nil,
                uti: "public.jpeg",
                byteCount: 1,
                faces: []
            )
        }
        let document = RemoteIndexDocument(
            updatedAt: Date(),
            device: "atlas-bench",
            people: [],
            photos: entries
        )
        let data = try JSONFile.encoder().encode(document)
        try await client.putObject(
            key: ".backu/index.json",
            data: data,
            contentType: "application/json"
        )
        print("→ Seeded .backu/index.json with \(entries.count) remote photos")
    }

    for row in scenarios {
        print(String(
            format: "  %-40s %3d req %9s  first %7.1f ms  all %8.1f ms",
            (row.name as NSString).utf8String!,
            row.requests,
            (kb(row.bytes) as NSString).utf8String!,
            row.firstTileMillis,
            row.allTilesMillis
        ))
    }

    let report = Report(
        profile: options.profile,
        photos: photos.count,
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        codecs: codecRows,
        library: libraryBytes,
        scenarios: scenarios,
        notes: notes
    )
    if let output = options.output {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        print("\nReport written to \(output)")
    }
    exit(0)
}

// Local-only path.
let report = Report(
    profile: options.profile,
    photos: photos.count,
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    codecs: codecRows,
    library: libraryBytes,
    scenarios: [],
    notes: notes
)
if let output = options.output {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: output))
    print("\nReport written to \(output)")
}

// MARK: - Helpers

final class TileCache {
    private var cache: [String: CGImage] = [:]

    func tile(url: URL, side: Int) -> CGImage? {
        let key = "\(url.path)|\(side)"
        if let cached = cache[key] { return cached }
        guard let tile = squareTile(url: url, side: side) else { return nil }
        cache[key] = tile
        return tile
    }
}
