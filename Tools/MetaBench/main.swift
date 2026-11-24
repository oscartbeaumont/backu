import Foundation

// Metadata log benchmark.
//
// Compares the single-document index (v1) with the per-writer segmented log
// (v2) for a large library: write amplification per edit, cold-start bytes for
// a new device, steady-state catch-up, and the one-time migration.
//
//   swiftc -O -o /tmp/backu-meta-bench \
//     Sources/Core/Models/StorageProvider.swift Sources/Core/Models/ServerConfig.swift \
//     Sources/Core/Models/PhotoItem.swift Sources/Core/Models/Person.swift \
//     Sources/Core/S3/*.swift Sources/Core/Storage/AppPaths.swift \
//     Sources/Core/Sync/Sidecar.swift Sources/Core/Metadata/*.swift \
//     Tools/MetaBench/main.swift
//
// Tools/MetaBench/run.sh builds it and writes a JSON report.

struct Options {
    var photos = 100_000
    var edits = 100
    var endpoint = URL(string: "http://127.0.0.1:9500")!
    var bucket = "backu-test"
    var accessKey = "testkey"
    var secret = "testsecret"
    var region = "us-east-1"
    var network = true
    var seed = false
    var seedPrefix = "MetaSeed"
    var output: String?

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
            case "--photos": options.photos = max(1, Int(value()) ?? 100_000)
            case "--edits": options.edits = max(1, Int(value()) ?? 100)
            case "--endpoint": if let url = URL(string: value()) { options.endpoint = url }
            case "--bucket": options.bucket = value()
            case "--access-key": options.accessKey = value()
            case "--secret": options.secret = value()
            case "--region": options.region = value()
            case "--no-network": options.network = false
            case "--seed": options.seed = true
            case "--seed-prefix": options.seedPrefix = value()
            case "--output": options.output = value()
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
    Usage: backu-meta-bench [options]

      --photos N       library size (default 100000)
      --edits N        edits to measure (default 100)
      --endpoint URL   mock S3 (default http://127.0.0.1:9500)
      --no-network     skip the upload/GET timing
      --seed           publish a snapshot + head for an app smoke test
      --seed-prefix P  bucket folder for --seed (default MetaSeed)
      --output PATH    write a JSON report
    """
}

struct Report: Codable {
    var photos: Int
    var edits: Int
    var v1CompactBytes: Int
    var v1PrettyBytes: Int
    var v1EncodeMilliseconds: Double
    var v2SnapshotBytes: Int
    var v2SnapshotMilliseconds: Double
    var v2SegmentBytes: Int
    var v2SegmentRawBytes: Int
    var v2EditRecordBytes: Double
    var v2SeedBytes: Int
    var v2SeedSegments: Int
    var v2HeadBytes: Int
    var v1WritesPerEdit: Int
    var v2WritesPerEdit: Int
    var v1BytesPerEdit: Int
    var v2BytesPerEdit: Int
    var notes: [String]
    var uploads: [String: Double]
    var fetches: [String: Double]
}

func kb(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        return String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
    }
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
    return String(format: "%.1f KB", Double(bytes) / 1024)
}

func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

let options = Options.parse(CommandLine.arguments)
let serverID = UUID()
let people = [
    Person(name: "Ada"),
    Person(name: "Grace")
]

print("→ Generating \(options.photos) photo records")
let calendar = Calendar(identifier: .gregorian)
var photos: [PhotoItem] = []
photos.reserveCapacity(options.photos)
for index in 0..<options.photos {
    var metadata = PhotoMetadata()
    metadata.cameraMake = index % 3 == 0 ? "Apple" : "Canon"
    metadata.cameraModel = index % 3 == 0 ? "iPhone 17 Pro" : "EOS R5"
    metadata.lensModel = index % 3 == 0 ? "Main Camera" : "RF 24-70mm"
    metadata.iso = 100 + index % 800
    metadata.fNumber = 1.8 + Double(index % 8) / 10
    metadata.latitude = 51.5 + Double(index % 100) / 10_000
    metadata.longitude = -0.12 + Double(index % 100) / 10_000
    metadata.placeName = "London"
    metadata.focalLength = 24 + Double(index % 80)
    metadata.uti = "public.jpeg"
    metadata.fileExtension = "jpg"
    let date = calendar.date(byAdding: .hour, value: -index * 6, to: Date()) ?? Date()
    let tags = index % 11 == 0 ? ["beach", "family"] : (index % 7 == 0 ? ["work"] : [])
    photos.append(
        PhotoItem(
            id: "asset:\(index)",
            localIdentifier: nil,
            filename: "IMG_\(1000 + index).jpg",
            takenAt: date,
            addedAt: date,
            modifiedAt: date,
            isFavorite: index % 17 == 0,
            pixelWidth: 4032,
            pixelHeight: 3024,
            tags: tags,
            metadata: metadata,
            faces: index % 5 == 0
                ? [
                    PhotoFace(
                        personID: people[index % people.count].id,
                        rect: NormRect(x: 0.2, y: 0.3, width: 0.1, height: 0.12)
                    )
                ]
                : [],
            copies: [
                PhotoCopy(
                    serverID: serverID,
                    objectKey: "Backu/Photos/2025/06/IMG_\(1000 + index).jpg",
                    sidecarKey: "Backu/Photos/2025/06/IMG_\(1000 + index).jpg.json",
                    thumbnailKey: "Backu/.backu/thumbs/\(index).jpg",
                    uploadedAt: date,
                    byteCount: 3_500_000,
                    etag: "etag-\(index)",
                    sha256: "sha-\(index)",
                    atlasGroup: "group-\(index / 36)",
                    atlasCell: index % 36
                )
            ],
            sha256: "sha-\(index)",
            analyzedAt: date,
            remoteThumbnailKey: "Backu/.backu/thumbs/\(index).jpg",
            serverID: serverID
        )
    )
}

// MARK: - v1: one document, rewritten

print("→ Measuring the v1 index")
let (v1Pretty, v1EncodeMilliseconds) = try measure {
    try JSONFile.encoder(pretty: true).encode(
        RemoteIndexDocument.make(
            photos: photos,
            people: people,
            serverID: serverID,
            device: "benchmark"
        )
    )
}
let v1Compact = try JSONFile.encoder(pretty: false).encode(
    RemoteIndexDocument.make(
        photos: photos,
        people: people,
        serverID: serverID,
        device: "benchmark"
    )
)

// MARK: - v2: append-only segments

print("→ Building the v2 snapshot")
var state = MergedMetadata()
let (_, seedMilliseconds) = try measure {
    for (index, photo) in photos.enumerated() {
        state.apply(
            MetaRecord(
                op: .photoUpsert,
                id: photo.id,
                hlc: Int64(index + 1),
                by: "writer-a",
                photo: SharedPhoto(photo: photo, serverID: serverID),
                tagsAdd: photo.tags.isEmpty ? nil : photo.tags,
                facesSet: photo.faces.isEmpty ? nil : photo.faces.map(SharedFace.init)
            )
        )
    }
}

let snapshotRaw = state.encodeSnapshot(generation: 1, watermark: ["writer-a": 0])
let (snapshotCompressed, snapshotGzipMilliseconds) = try measure { try Gzip.compress(snapshotRaw) }

var editRecords: [MetaRecord] = []
for index in 0..<min(options.edits, photos.count) {
    var edited = photos[index]
    edited.isFavorite.toggle()
    edited.tags.append("edited-\(index)")
    edited.metadata.placeName = "Bristol"
    editRecords.append(
        MetaRecord(
            op: .photoPatch,
            id: edited.id,
            hlc: Int64(options.photos + index + 1),
            by: "writer-a",
            photo: SharedPhoto(photo: edited, serverID: serverID),
            changed: ["isFavorite", "metadata"],
            tagsAdd: ["edited-\(index)"]
        )
    )
}
let segmentRaw = try MetadataSegmentCodec.encode(editRecords)
let segmentCompressed = try Gzip.compress(segmentRaw)
let actualEdits = editRecords.count

// One segment per 500 records is the writer's chunk size.
let seedRecords = photos.enumerated().map { index, photo in
    MetaRecord(
        op: .photoUpsert,
        id: photo.id,
        hlc: Int64(index + 1),
        by: "writer-a",
        photo: SharedPhoto(photo: photo, serverID: serverID),
        tagsAdd: photo.tags.isEmpty ? nil : photo.tags,
        facesSet: photo.faces.isEmpty ? nil : photo.faces.map(SharedFace.init)
    )
}
var seedBytes = 0
var seedSegments = 0
var cursor = 0
while cursor < seedRecords.count {
    let chunk = Array(seedRecords[cursor..<min(cursor + 500, seedRecords.count)])
    let raw = try MetadataSegmentCodec.encode(chunk)
    seedBytes += try Gzip.compress(raw).count
    seedSegments += 1
    cursor += 500
}

let head = MetadataHead(
    generation: 1,
    snapshot: MetadataLayout.snapshotKey(generation: 1, hlc: 1, digest: "x"),
    watermark: ["writer-a": 0],
    updatedAt: Date(),
    device: "benchmark"
)
let headBytes = try JSONFile.encoder().encode(head).count

let v2EditRecordBytes = Double(segmentCompressed.count) / Double(max(1, editRecords.count))

// MARK: - Network timing

var uploads: [String: Double] = [:]
var fetches: [String: Double] = [:]
var notes: [String] = []
var networkFailed = false
let networkKeys: Set<String> = ["v1-index.json", "v2-snapshot.jsonl.gz", "v2-segment.jsonl.gz"]
notes.append(String(format: "v2 state build + merge: %.0f ms", seedMilliseconds))
notes.append(String(format: "v2 snapshot gzip: %.0f ms", snapshotGzipMilliseconds))

if options.network {
    let connection = S3Connection(
        endpoint: options.endpoint,
        region: options.region,
        bucket: options.bucket,
        pathStyle: true
    )
    let client = S3Client(
        connection: connection,
        credentials: S3Credentials(accessKeyID: options.accessKey, secretAccessKey: options.secret)
    )
    let prefix = "MetaBench-\(UUID().uuidString.prefix(8))"

    func put(_ key: String, _ data: Data) async {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await client.putObject(key: "\(prefix)/\(key)", data: data, contentType: "application/octet-stream")
            uploads[key] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        } catch {
            networkFailed = true
            notes.append("upload \(key) failed: \(error.localizedDescription)")
        }
    }

    func get(_ key: String) async {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await client.getObject(key: "\(prefix)/\(key)")
            fetches[key] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        } catch {
            networkFailed = true
            notes.append("fetch \(key) failed: \(error.localizedDescription)")
        }
    }

    print("→ Network timing against \(options.endpoint)")
    await put("v1-index.json", v1Compact)
    await put("v2-snapshot.jsonl.gz", snapshotCompressed)
    await put("v2-segment.jsonl.gz", segmentCompressed)
    await get("v1-index.json")
    await get("v2-snapshot.jsonl.gz")
    await get("v2-segment.jsonl.gz")

    if options.seed {
        // A bucket a fresh device can open: one snapshot, one head, one
        // post-snapshot segment. Used by the simulator smoke test.
        let root = options.seedPrefix
        // head.snapshot is relative to the store's folder; the S3 adapter (and
        // the real app) applies the prefix exactly once.
        let relativeSnapshot = MetadataLayout.snapshotKey(
            generation: 1,
            hlc: 1,
            digest: SigV4Signer.sha256Hex(snapshotCompressed)
        )
        let snapshotKey = S3Client.join(root, relativeSnapshot)
        let segmentKey = S3Client.join(
            root,
            MetadataLayout.segmentKey(
                writer: "writer-edit",
                sequence: 0,
                hlc: editRecords.map(\.hlc).max() ?? 1,
                digest: SigV4Signer.sha256Hex(segmentCompressed)
            )
        )
        let seededHead = MetadataHead(
            generation: 1,
            snapshot: relativeSnapshot,
            watermark: ["writer-a": 0],
            updatedAt: Date(),
            device: "MetaBench"
        )
        do {
            try await client.putObject(key: snapshotKey, data: snapshotCompressed, contentType: "application/gzip")
            try await client.putObject(key: segmentKey, data: segmentCompressed, contentType: "application/gzip")
            try await client.putObject(
                key: S3Client.join(root, MetadataLayout.headKey),
                data: try JSONFile.encoder().encode(seededHead),
                contentType: "application/json"
            )
            print("→ Seeded \(root) with a snapshot and one segment")
        } catch {
            networkFailed = true
            notes.append("seed failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Report

let report = Report(
    photos: options.photos,
    edits: actualEdits,
    v1CompactBytes: v1Compact.count,
    v1PrettyBytes: v1Pretty.count,
    v1EncodeMilliseconds: v1EncodeMilliseconds,
    v2SnapshotBytes: snapshotCompressed.count,
    v2SnapshotMilliseconds: snapshotGzipMilliseconds,
    v2SegmentBytes: segmentCompressed.count,
    v2SegmentRawBytes: segmentRaw.count,
    v2EditRecordBytes: v2EditRecordBytes,
    v2SeedBytes: seedBytes,
    v2SeedSegments: seedSegments,
    v2HeadBytes: headBytes,
    v1WritesPerEdit: 1,
    v2WritesPerEdit: 1,
    v1BytesPerEdit: v1Compact.count,
    v2BytesPerEdit: segmentCompressed.count,
    notes: notes,
    uploads: uploads,
    fetches: fetches
)

print("")
print("  library                 \(options.photos) photos")
print("  v1 index (compact)      \(kb(v1Compact.count))   \(String(format: "%.0f", v1EncodeMilliseconds)) ms encode")
print("  v1 index (pretty)       \(kb(v1Pretty.count))")
print("  v2 snapshot (gzip)      \(kb(snapshotCompressed.count))   \(String(format: "%.0f", snapshotGzipMilliseconds)) ms gzip")
print("  v2 seed (migration)     \(kb(seedBytes)) in \(seedSegments) segments")
print("  v2 \(actualEdits) edits segment   \(kb(segmentCompressed.count))  (\(String(format: "%.0f", v2EditRecordBytes)) B/edit)")
print("  v2 head                 \(kb(headBytes))")
print("")
print("  one editing session      v1 \(kb(v1Compact.count)) / 1 PUT   →   v2 \(kb(segmentCompressed.count)) / 1 PUT")
print("  new device, warm cache    v1 \(kb(v1Compact.count))          →   v2 \(kb(headBytes)) (304) + \(kb(segmentCompressed.count))")
print("  new device, from scratch  v1 \(kb(v1Compact.count))          →   v2 \(kb(headBytes + snapshotCompressed.count + segmentCompressed.count))")
if !uploads.isEmpty {
    print("")
    for (key, value) in uploads.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  PUT %-22s %8.1f ms", (key as NSString).utf8String!, value))
    }
    for (key, value) in fetches.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  GET %-22s %8.1f ms", (key as NSString).utf8String!, value))
    }
}
if let output = options.output {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: output))
    print("\nReport written to \(output)")
}
if options.network && (
    networkFailed || Set(uploads.keys) != networkKeys || Set(fetches.keys) != networkKeys
) {
    FileHandle.standardError.write(Data("Network measurements failed; report is incomplete.\n".utf8))
    exit(1)
}
