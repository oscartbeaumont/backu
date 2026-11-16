import Foundation

/// A short-lived cache of HEAD results, keyed by server endpoint + bucket + key.
///
/// A viewer open, a retry after a 412 and every benchmark iteration used to pay
/// a round trip for the same metadata. Object bytes still come from a GET, and
/// every range is pinned with `If-Match`, so a stale entry can never mix two
/// object versions: if the object changed, the GET fails with 412, the entry is
/// dropped and the download re-probes. Writes and deletes through `S3Client`
/// invalidate the key immediately.
final class S3HeadCache: @unchecked Sendable {
    struct Entry: Sendable {
        var head: S3ObjectHead
        /// Round trip observed when the HEAD was served. Reused as the latency
        /// estimate so a cache hit still knows whether ranges are worth it.
        var latency: TimeInterval
        var storedAt: Date
    }

    static let shared = S3HeadCache()

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let limit: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 60, limit: Int = 256, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = max(0, ttl)
        self.limit = max(0, limit)
        self.now = now
    }

    /// `ttl: 0` never returns a hit; convenient for tests and for callers that
    /// need a guaranteed-fresh probe.
    static func disabled() -> S3HeadCache {
        S3HeadCache(ttl: 0, limit: 0)
    }

    func value(server: String, key: String) -> Entry? {
        guard ttl > 0, limit > 0 else { return nil }
        let cacheKey = Self.cacheKey(server: server, key: key)
        lock.lock()
        let entry = entries[cacheKey]
        if let entry, entry.storedAt.addingTimeInterval(ttl) <= now() {
            entries.removeValue(forKey: cacheKey)
            lock.unlock()
            return nil
        }
        lock.unlock()
        return entry
    }

    func store(_ head: S3ObjectHead, latency: TimeInterval, server: String, key: String) {
        guard ttl > 0, limit > 0 else { return }
        let cacheKey = Self.cacheKey(server: server, key: key)
        lock.lock()
        if entries.count >= limit, entries[cacheKey] == nil {
            pruneLocked()
        }
        entries[cacheKey] = Entry(head: head, latency: max(0, latency), storedAt: now())
        lock.unlock()
    }

    func invalidate(server: String, key: String) {
        let cacheKey = Self.cacheKey(server: server, key: key)
        lock.lock()
        entries.removeValue(forKey: cacheKey)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Test seam.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func pruneLocked() {
        let deadline = now()
        entries = entries.filter { $0.value.storedAt.addingTimeInterval(ttl) > deadline }
        guard entries.count >= limit else { return }
        // Still full of live entries: drop the oldest quarter. Metadata is a
        // few hundred bytes per key, so this is housekeeping, not a policy.
        let overflow = max(1, entries.count - limit + limit / 4)
        let oldest = entries
            .sorted { $0.value.storedAt < $1.value.storedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldest { entries.removeValue(forKey: key) }
    }

    private static func cacheKey(server: String, key: String) -> String {
        "\(server)\u{1F}\(key)"
    }
}

extension S3Client {
    /// A HEAD that may be served from `headCache`. Returns the round trip of a
    /// real request, or the recorded round trip of the cached one.
    func headObjectForDownload(key: String, useCache: Bool) async throws -> (S3ObjectHead?, TimeInterval) {
        let server = connection.transferTuningKey
        if useCache, let cached = headCache?.value(server: server, key: key) {
            return (cached.head, cached.latency)
        }
        let started = Date()
        let head = try await headObject(key: key)
        let latency = Date().timeIntervalSince(started)
        // A zero-length object is never cached: a stale "empty" answer would
        // write an empty file instead of downloading the bytes that just
        // arrived. Every other size is pinned by If-Match on the GET.
        if let head, head.size > 0 {
            headCache?.store(head, latency: latency, server: server, key: key)
        }
        return (head, latency)
    }

    func invalidateCachedHead(key: String) {
        headCache?.invalidate(server: connection.transferTuningKey, key: key)
    }
}
