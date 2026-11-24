import Foundation

// A focused benchmark for the sync path itself, as opposed to MetaBench's
// format/size comparison. It drives the real `MetadataService` against an
// in-memory `MetadataObjectStore`, so a run measures the journal's own work:
//
//   cold   – a device with no local state reads the 100k snapshot
//   warm   – a relaunch with a primed cache applies one changed photo
//   seed   – a pre-v2 bucket publishes its 100k-photo library
//
// Each scenario runs in its own process so `ru_maxrss` (peak RSS) belongs to
// that scenario only. `Tools/MetaBench/sync.sh` orchestrates the runs.
//
//   swiftc -O -o /tmp/backu-sync-bench <core sources> Tools/MetaBench/SyncBench/main.swift
//
// `--scenario prepare` writes the fixture (snapshot + head + one segment) that
// the measured runs load, keeping fixture generation out of their peak memory.

/// `MetadataService` only needs the device name when it writes a head; the app
/// target supplies this via `BackgroundUploader`, which is not part of the
/// benchmark's source set.
enum DeviceInfo {
    static var name: String { "MetaBench" }
}

private let defaultServerID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!

struct Options {
    var scenario = "cold"
    var photos = 100_000
    var directory = NSTemporaryDirectory() + "backu-sync-bench"
    /// Simulated network round trip per PUT, so the seed's parallelism shows up
    /// the way it would against a real bucket.
    var putLatencyMilliseconds = 15.0
    var serverID = defaultServerID

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
            case "--scenario": options.scenario = value()
            case "--photos": options.photos = max(1, Int(value()) ?? 100_000)
            case "--dir": options.directory = value()
            case "--put-latency-ms": options.putLatencyMilliseconds = Double(value()) ?? 0
            case "--server-id":
                if let id = UUID(uuidString: value()) { options.serverID = id }
            case "--help", "-h":
                print("--scenario prepare|cold|warm|seed [--photos N] [--dir PATH] [--put-latency-ms N]")
                exit(0)
            default:
                print("Unknown option \(name)")
                exit(2)
            }
            index += 1
        }
        return options
    }
}

// MARK: - Object store

/// Dictionary-backed store with an optional simulated round trip per PUT.
final class BenchStore: MetadataObjectStore, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var etags: [String: String] = [:]
    private var counter = 0
    private let putLatency: TimeInterval
    private var puts = 0

    init(putLatency: TimeInterval = 0) {
        self.putLatency = putLatency
    }

    var putCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return puts
    }

    func seed(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        objects[key] = data
        counter += 1
        etags[key] = "etag-\(counter)"
    }

    func objectCount(under prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.keys.filter { $0.hasPrefix(prefix) }.count
    }

    func bytes(under prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.reduce(0) { $0 + ($1.key.hasPrefix(prefix) ? $1.value.count : 0) }
    }

    func getObject(_ key: String, ifNoneMatch: String?) async throws -> MetadataGetResult {
        lock.lock()
        defer { lock.unlock() }
        guard let data = objects[key] else { return .missing }
        let etag = etags[key] ?? "etag"
        if let ifNoneMatch, ifNoneMatch == etag { return .notModified(etag: etag) }
        return .found(data: data, etag: etag)
    }

    func putObject(_ key: String, data: Data, contentType: String) async throws {
        if putLatency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(putLatency * 1_000_000_000))
        }
        lock.lock()
        defer { lock.unlock() }
        puts += 1
        objects[key] = data
        counter += 1
        etags[key] = "etag-\(counter)"
    }

    func deleteObject(_ key: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        objects.removeValue(forKey: key)
        etags.removeValue(forKey: key)
    }

    func listObjects(
        prefix: String,
        delimiter: String?,
        startAfter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) async throws -> MetadataListPage {
        lock.lock()
        defer { lock.unlock() }
        var keys = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        if let startAfter { keys = keys.filter { $0 > startAfter } }
        if let continuationToken { keys = keys.filter { $0 > continuationToken } }

        var commonPrefixes: [String] = []
        if delimiter != nil {
            var visible: [String] = []
            var seen = Set<String>()
            for key in keys {
                let rest = key.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/") {
                    let rolled = prefix + rest[..<slash] + "/"
                    if seen.insert(rolled).inserted { commonPrefixes.append(rolled) }
                } else {
                    visible.append(key)
                }
            }
            keys = visible
        }
        let limit = min(1000, maxKeys)
        let page = Array(keys.prefix(limit))
        let truncated = keys.count > page.count
        return MetadataListPage(
            keys: page,
            commonPrefixes: commonPrefixes.sorted(),
            nextToken: truncated ? page.last : nil,
            isTruncated: truncated
        )
    }

    #if !BACKU_BENCH_LEGACY_STORE
    /// Models S3: the body goes to disk without being decoded into a second
    /// buffer. Only the optimised tree calls it; the script defines
    /// `BACKU_BENCH_LEGACY_STORE` when benchmarking the old code.
    func downloadObject(_ key: String, to url: URL) async throws -> MetadataDownloadResult {
        lock.lock()
        let data = objects[key]
        let etag = etags[key]
        lock.unlock()
        guard let data else { return .missing }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return .downloaded(etag: etag)
    }
    #endif
}

// MARK: - Fixture

struct Fixture {
    var snapshotKey: String
    var headData: Data
    var snapshotData: Data
    var segmentKey: String
    var segmentData: Data
    var photoCount: Int
}

func makePhoto(_ index: Int, serverID: UUID) -> PhotoItem {
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
    let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 21_600)
    let tags = index % 11 == 0 ? ["beach", "family"] : (index % 7 == 0 ? ["work"] : [])
    return PhotoItem(
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
}

func prepare(_ options: Options) throws -> Fixture {
    let directory = URL(fileURLWithPath: options.directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var state = MergedMetadata()
    for index in 0..<options.photos {
        let photo = makePhoto(index, serverID: options.serverID)
        state.apply(
            MetaRecord(
                op: .photoUpsert,
                id: photo.id,
                hlc: Int64(index + 1),
                by: "writer-a",
                photo: SharedPhoto(photo: photo, serverID: options.serverID),
                tagsAdd: photo.tags.isEmpty ? nil : photo.tags,
                facesSet: photo.faces.isEmpty ? nil : photo.faces.map(SharedFace.init)
            )
        )
    }
    let raw = state.encodeSnapshot(generation: 1, watermark: ["writer-a": 0])
    let snapshotData = try Gzip.compress(raw)
    let snapshotKey = MetadataLayout.snapshotKey(
        generation: 1,
        hlc: 1,
        digest: SigV4Signer.sha256Hex(snapshotData)
    )
    try snapshotData.write(to: directory.appendingPathComponent("snapshot.jsonl.gz"))

    let head = MetadataHead(
        generation: 1,
        snapshot: snapshotKey,
        watermark: ["writer-a": 0],
        updatedAt: Date(),
        device: "MetaBench"
    )
    let headData = try JSONFile.encoder().encode(head)
    try headData.write(to: directory.appendingPathComponent("head.json"))

    // One changed photo in a new segment: the warm-sync case.
    var edited = makePhoto(42, serverID: options.serverID)
    edited.isFavorite.toggle()
    edited.tags.append("warm-edit")
    let record = MetaRecord(
        op: .photoPatch,
        id: edited.id,
        hlc: Int64(options.photos) + 1,
        by: "writer-a",
        photo: SharedPhoto(photo: edited, serverID: options.serverID),
        changed: ["isFavorite"],
        tagsAdd: ["warm-edit"]
    )
    let segmentData = try Gzip.compress(try MetadataSegmentCodec.encode([record]))
    let segmentKey = MetadataLayout.segmentKey(
        writer: "writer-a",
        sequence: 1,
        hlc: record.hlc,
        digest: SigV4Signer.sha256Hex(segmentData)
    )
    try segmentData.write(to: directory.appendingPathComponent("segment.jsonl.gz"))

    return Fixture(
        snapshotKey: snapshotKey,
        headData: headData,
        snapshotData: snapshotData,
        segmentKey: segmentKey,
        segmentData: segmentData,
        photoCount: options.photos
    )
}

func loadFixture(_ options: Options) throws -> Fixture {
    let directory = URL(fileURLWithPath: options.directory, isDirectory: true)
    let snapshotData = try Data(contentsOf: directory.appendingPathComponent("snapshot.jsonl.gz"))
    let headData = try Data(contentsOf: directory.appendingPathComponent("head.json"))
    let segmentData = try Data(contentsOf: directory.appendingPathComponent("segment.jsonl.gz"))
    let head = try JSONFile.decoder.decode(MetadataHead.self, from: headData)
    let snapshotKey = head.snapshot ?? MetadataLayout.snapshotKey(
        generation: 1,
        hlc: 1,
        digest: SigV4Signer.sha256Hex(snapshotData)
    )
    // The fixture's patch record is always the one prepared at `photos` + 1.
    let segmentKey = MetadataLayout.segmentKey(
        writer: "writer-a",
        sequence: 1,
        hlc: Int64(options.photos) + 1,
        digest: SigV4Signer.sha256Hex(segmentData)
    )
    return Fixture(
        snapshotKey: snapshotKey,
        headData: headData,
        snapshotData: snapshotData,
        segmentKey: segmentKey,
        segmentData: segmentData,
        photoCount: options.photos
    )
}

// MARK: - Measurement

func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1024 / 1024
}

func clearLocalState(_ serverID: UUID) {
    try? FileManager.default.removeItem(at: AppPaths.metadataStateFile(serverID))
    try? FileManager.default.removeItem(at: AppPaths.metadataCacheFile(serverID))
    try? FileManager.default.removeItem(at: AppPaths.metadataOutboxFile(serverID))
}

func report(
    scenario: String,
    photos: Int,
    seconds: Double,
    extra: [String: Any] = [:]
) {
    let payload: [String: Any] = [
        "scenario": scenario,
        "photos": photos,
        "seconds": seconds,
        "peakRSSMB": (peakRSSMegabytes() * 10).rounded() / 10
    ].merging(extra) { _, new in new }
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data ?? Data("{}".utf8), as: UTF8.self))
}

let options = Options.parse(CommandLine.arguments)

switch options.scenario {
case "prepare":
    let fixture = try prepare(options)
    print("fixture: \(fixture.photoCount) photos, snapshot \(fixture.snapshotData.count / 1024) KB")

case "cold":
    let fixture = try loadFixture(options)
    clearLocalState(options.serverID)
    let store = BenchStore()
    store.seed(fixture.snapshotKey, fixture.snapshotData)
    store.seed(MetadataLayout.headKey, fixture.headData)

    let service = MetadataService(serverID: options.serverID, writerID: "bench")
    let started = DispatchTime.now().uptimeNanoseconds
    let outcome = try await service.sync(store: store)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    report(
        scenario: "cold",
        photos: outcome.photos.count,
        seconds: seconds,
        extra: ["full": outcome.photos.count == options.photos]
    )

case "warm":
    // `prime` already ran: the state and cache files exist on disk, exactly as
    // after a relaunch. Only the one-record segment is new.
    let fixture = try loadFixture(options)
    let store = BenchStore()
    store.seed(fixture.snapshotKey, fixture.snapshotData)
    store.seed(MetadataLayout.headKey, fixture.headData)
    store.seed(fixture.segmentKey, fixture.segmentData)

    let service = MetadataService(serverID: options.serverID, writerID: "bench")
    let started = DispatchTime.now().uptimeNanoseconds
    let outcome = try await service.sync(store: store)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    // The old path writes a 13 MB cache on a background queue; give it time to
    // show up in the peak before reporting.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    report(
        scenario: "warm",
        photos: outcome.photos.count,
        seconds: seconds,
        extra: ["changed": outcome.changed, "full": outcome.photos.count == options.photos]
    )

case "prime":
    // Loads the snapshot once so `warm` can start from a primed cache.
    let fixture = try loadFixture(options)
    clearLocalState(options.serverID)
    let store = BenchStore()
    store.seed(fixture.snapshotKey, fixture.snapshotData)
    store.seed(MetadataLayout.headKey, fixture.headData)
    let service = MetadataService(serverID: options.serverID, writerID: "bench")
    _ = try await service.sync(store: store)
    try? await Task.sleep(nanoseconds: 8_000_000_000)
    print("primed \(options.serverID)")

case "seed":
    let store = BenchStore(putLatency: options.putLatencyMilliseconds / 1_000)
    clearLocalState(options.serverID)
    let catalog = CatalogStore(loadFromDisk: false)
    let photos = (0..<options.photos).map { makePhoto($0, serverID: options.serverID) }
    catalog.mergeScanned(photos)

    let service = MetadataService(serverID: options.serverID, writerID: "bench")
    _ = try await service.sync(store: store)
    let started = DispatchTime.now().uptimeNanoseconds
    await service.seedIfNeeded(catalog: catalog, store: store)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    let segments = store.objectCount(under: MetadataLayout.logPrefix)
    let bytes = store.bytes(under: MetadataLayout.logPrefix)
    report(
        scenario: "seed",
        photos: options.photos,
        seconds: seconds,
        extra: [
            "segments": segments,
            "bytes": bytes,
            "puts": store.putCount,
            "seeded": service.replication.seeded
        ]
    )

default:
    print("Unknown scenario \(options.scenario)")
    exit(2)
}
