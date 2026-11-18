import Foundation

/// In-memory implementation of the journal's storage protocol, with injectable
/// failures. The journal is the part of the sync stack most likely to lose or
/// duplicate records, so its retry, crash and concurrent-compaction behaviour
/// is tested here without S3, a mock server, or the network.
actor InMemoryMetadataStore: MetadataObjectStore {
    enum Fault: Error {
        case injected
    }

    private var objects: [String: Data] = [:]
    private var etags: [String: String] = [:]
    private var etagCounter = 0

    private(set) var putLog: [(key: String, bytes: Int)] = []
    private(set) var getLog: [String] = []
    private(set) var listLog: [String] = []

    private var putFailures: [(pattern: String, remaining: Int)] = []
    private var storeThenFail: [(pattern: String, remaining: Int)] = []
    private var getFailures: [(pattern: String, remaining: Int)] = []
    private var listFailuresRemaining = 0
    private var concurrentPuts = 0
    /// Highest number of PUTs that were in flight at once. Lets a test prove the
    /// seed and flush paths actually overlap their uploads.
    private(set) var peakConcurrentPuts = 0

    var pageSize = 1000
    var supportsDelimiter = true

    // MARK: - Inspection

    func seed(_ key: String, _ data: Data) {
        objects[key] = data
        etagCounter += 1
        etags[key] = "etag-\(etagCounter)"
    }

    func data(for key: String) -> Data? { objects[key] }
    func keys() -> [String] { objects.keys.sorted() }
    func keys(under prefix: String) -> [String] { keys().filter { $0.hasPrefix(prefix) } }
    func objectCount(under prefix: String) -> Int { keys(under: prefix).count }
    func delete(_ key: String) { objects[key] = nil; etags[key] = nil }
    func resetLogs() { putLog.removeAll(); getLog.removeAll(); listLog.removeAll() }

    // MARK: - Fault injection

    func failPuts(matching pattern: String, count: Int = 1) {
        putFailures.append((pattern, count))
    }

    func failPutsAfterStoring(matching pattern: String, count: Int = 1) {
        storeThenFail.append((pattern, count))
    }

    func failGets(matching pattern: String, count: Int = 1) {
        getFailures.append((pattern, count))
    }

    func failLists(count: Int = 1) {
        listFailuresRemaining += count
    }

    func setPageSize(_ size: Int) { pageSize = max(1, size) }
    func setSupportsDelimiter(_ value: Bool) { supportsDelimiter = value }

    // MARK: - MetadataObjectStore

    func getObject(_ key: String, ifNoneMatch: String?) async throws -> MetadataGetResult {
        getLog.append(key)
        if consume(&getFailures, matching: key) { throw Fault.injected }
        guard let data = objects[key] else { return .missing }
        let etag = etags[key] ?? "etag"
        if let ifNoneMatch, ifNoneMatch == etag { return .notModified(etag: etag) }
        return .found(data: data, etag: etag)
    }

    func putObject(_ key: String, data: Data, contentType: String) async throws {
        concurrentPuts += 1
        peakConcurrentPuts = max(peakConcurrentPuts, concurrentPuts)
        defer { concurrentPuts -= 1 }
        // Give a sibling PUT a chance to be in flight, so the counter reflects
        // real overlap rather than actor serialisation.
        await Task.yield()
        putLog.append((key, data.count))
        if consume(&putFailures, matching: key) { throw Fault.injected }
        objects[key] = data
        etagCounter += 1
        etags[key] = "etag-\(etagCounter)"
        if consume(&storeThenFail, matching: key) { throw Fault.injected }
    }


    func listObjects(
        prefix: String,
        delimiter: String?,
        startAfter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) async throws -> MetadataListPage {
        listLog.append(prefix)
        if listFailuresRemaining > 0 {
            listFailuresRemaining -= 1
            throw Fault.injected
        }

        var keys = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        if let startAfter { keys = keys.filter { $0 > startAfter } }
        if let continuationToken { keys = keys.filter { $0 > continuationToken } }

        var commonPrefixes: [String] = []
        if delimiter != nil, supportsDelimiter {
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

        let limit = min(pageSize, maxKeys)
        let page = Array(keys.prefix(limit))
        let truncated = keys.count > page.count
        return MetadataListPage(
            keys: page,
            commonPrefixes: commonPrefixes.sorted(),
            nextToken: truncated ? page.last : nil,
            isTruncated: truncated
        )
    }

    // MARK: - Internals

    private func consume(_ list: inout [(pattern: String, remaining: Int)], matching key: String) -> Bool {
        guard let index = list.firstIndex(where: { key.contains($0.pattern) }) else { return false }
        list[index].remaining -= 1
        let fired = list[index].remaining <= 0
        if fired { list.remove(at: index) }
        return fired
    }
}
