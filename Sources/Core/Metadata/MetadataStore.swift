import Foundation

/// The three outcomes a metadata read can have. Keeping 304 and 404 distinct is
/// what lets a sync skip a body without mistaking a missing head for "no
/// change".
enum MetadataGetResult: Sendable {
    case notModified(etag: String?)
    case found(data: Data, etag: String?)
    case missing
}

struct MetadataListEntry: Sendable {
    var key: String
    var size: Int64
    var lastModified: Date?
}

struct MetadataListPage: Sendable {
    var entries: [MetadataListEntry] = []
    var commonPrefixes: [String] = []
    var nextToken: String?
    var isTruncated: Bool = false

    var keys: [String] { entries.map(\.key) }

    init(
        entries: [MetadataListEntry] = [],
        commonPrefixes: [String] = [],
        nextToken: String? = nil,
        isTruncated: Bool = false
    ) {
        self.entries = entries
        self.commonPrefixes = commonPrefixes
        self.nextToken = nextToken
        self.isTruncated = isTruncated
    }

    init(
        keys: [String],
        commonPrefixes: [String] = [],
        nextToken: String? = nil,
        isTruncated: Bool = false
    ) {
        self.init(
            entries: keys.map { MetadataListEntry(key: $0, size: 0, lastModified: nil) },
            commonPrefixes: commonPrefixes,
            nextToken: nextToken,
            isTruncated: isTruncated
        )
    }
}

/// The outcome of a file-backed download. The body is on disk, not in memory.
enum MetadataDownloadResult: Sendable {
    case downloaded(etag: String?)
    case notModified(etag: String?)
    case missing
}

/// Everything the metadata journal needs from an object store. S3 is one
/// implementation; the tests use an in-memory store with fault injection so
/// retry, crash and concurrent-compaction paths can be exercised without a
/// network or a mock server.
///
/// Keys are relative to the store's folder (`backu` prefix). Implementations
/// scope them; the journal never sees a bucket prefix.
protocol MetadataObjectStore: Sendable {
    func getObject(_ key: String, ifNoneMatch: String?) async throws -> MetadataGetResult
    func putObject(_ key: String, data: Data, contentType: String) async throws
    func deleteObject(_ key: String) async throws
    func listObjects(
        prefix: String,
        delimiter: String?,
        startAfter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) async throws -> MetadataListPage

    /// Streams an object straight to a file. Only the snapshot uses it, and only
    /// on cold start: a 13 MB compressed / 60 MB expanded JSONL body is the one
    /// place where buffering costs real peak memory on a phone.
    ///
    /// The default implementation buffers, which is the right trade for the
    /// in-memory test store. `S3MetadataStore` overrides it with a streaming
    /// download.
    func downloadObject(_ key: String, to url: URL) async throws -> MetadataDownloadResult
}

extension MetadataObjectStore {
    func downloadObject(_ key: String, to url: URL) async throws -> MetadataDownloadResult {
        switch try await getObject(key, ifNoneMatch: nil) {
        case let .found(data, etag):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return .downloaded(etag: etag)
        case let .notModified(etag):
            return .notModified(etag: etag)
        case .missing:
            return .missing
        }
    }
}

/// Adapts `S3Client` to the journal's vocabulary. Each call is one S3 request;
/// no hidden HEAD or retry layer, so the journal's request accounting is real.
struct S3MetadataStore: MetadataObjectStore {
    let client: S3Client
    let prefix: String

    init(client: S3Client, prefix: String) {
        self.client = client
        self.prefix = prefix
    }

    func getObject(_ key: String, ifNoneMatch: String?) async throws -> MetadataGetResult {
        let (data, etag) = try await client.getObjectIfChanged(
            key: S3Client.join(prefix, key),
            etag: ifNoneMatch
        )
        if let data { return .found(data: data, etag: etag) }
        if let etag { return .notModified(etag: etag) }
        return .missing
    }

    func putObject(_ key: String, data: Data, contentType: String) async throws {
        try await client.putObject(
            key: S3Client.join(prefix, key),
            data: data,
            contentType: contentType
        )
    }

    func deleteObject(_ key: String) async throws {
        try await client.deleteObject(key: S3Client.join(prefix, key))
    }

    /// Streams the body through URLSession to disk. The metadata snapshot is
    /// the one object big enough that buffering it doubles cold-start memory.
    func downloadObject(_ key: String, to url: URL) async throws -> MetadataDownloadResult {
        do {
            // The snapshot is the one large object in the journal. The regular
            // downloader probes latency and fans out into parallel byte ranges
            // above 8 MB, which is what makes a 13 MB cold start usable on a
            // high-RTT link. It streams to disk throughout.
            try await client.downloadObject(key: S3Client.join(prefix, key), to: url)
            return .downloaded(etag: nil)
        } catch let error as S3Error {
            if case let .http(status, _, _, _) = error, status == 404 { return .missing }
            throw error
        }
    }

    func listObjects(
        prefix listingPrefix: String,
        delimiter: String?,
        startAfter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) async throws -> MetadataListPage {
        let page = try await client.listObjects(
            prefix: S3Client.join(prefix, listingPrefix),
            continuationToken: continuationToken,
            maxKeys: maxKeys,
            delimiter: delimiter,
            startAfter: startAfter.map { S3Client.join(prefix, $0) }
        )
        // Strip the folder prefix so the journal reasons in its own namespace.
        func relative(_ key: String) -> String {
            guard !prefix.isEmpty else { return key }
            let join = prefix + "/"
            return key.hasPrefix(join) ? String(key.dropFirst(join.count)) : key
        }
        return MetadataListPage(
            entries: page.objects.map {
                MetadataListEntry(
                    key: relative($0.key),
                    size: $0.size,
                    lastModified: $0.lastModified
                )
            },
            commonPrefixes: page.commonPrefixes.map { value in
                let trimmed = relative(value.hasSuffix("/") ? String(value.dropLast()) : value)
                return trimmed + "/"
            },
            nextToken: page.nextToken,
            isTruncated: page.isTruncated
        )
    }
}
