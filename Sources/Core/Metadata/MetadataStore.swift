import Foundation

/// The three outcomes a metadata read can have. Keeping 304 and 404 distinct is
/// what lets a sync skip a body without mistaking a missing head for "no
/// change".
enum MetadataGetResult: Sendable {
    case notModified(etag: String?)
    case found(data: Data, etag: String?)
    case missing
}

struct MetadataListPage: Sendable {
    var keys: [String] = []
    var commonPrefixes: [String] = []
    var nextToken: String?
    var isTruncated: Bool = false
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
    func listObjects(
        prefix: String,
        delimiter: String?,
        startAfter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) async throws -> MetadataListPage
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
            keys: page.objects.map { relative($0.key) },
            commonPrefixes: page.commonPrefixes.map { value in
                let trimmed = relative(value.hasSuffix("/") ? String(value.dropLast()) : value)
                return trimmed + "/"
            },
            nextToken: page.nextToken,
            isTruncated: page.isTruncated
        )
    }
}
