import XCTest

/// Covers the transfer-layer overhead work added in pass 3: the HEAD cache and
/// the multipart upload journal. Both are pure enough to test without a server.
final class TransferOverheadTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024

    // MARK: - HEAD cache

    private func head(size: Int64, etag: String = "\"abc\"") -> S3ObjectHead {
        S3ObjectHead(
            key: "Photos/a.jpg",
            size: size,
            etag: etag,
            contentType: "image/jpeg",
            acceptRanges: true
        )
    }

    func testHeadCacheServesRepeatedOpensThenExpires() {
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_000)
        }
        let clock = Clock()
        let cache = S3HeadCache(ttl: 60, limit: 8, now: { clock.now })
        let server = "example.test/bucket"

        XCTAssertNil(cache.value(server: server, key: "Photos/a.jpg"))
        cache.store(head(size: 42 * mib), latency: 0.04, server: server, key: "Photos/a.jpg")

        let hit = cache.value(server: server, key: "Photos/a.jpg")
        XCTAssertEqual(hit?.head.size, 42 * mib)
        XCTAssertEqual(hit?.latency ?? 0, 0.04, accuracy: 0.0001)

        // Another key on the same server is independent.
        XCTAssertNil(cache.value(server: server, key: "Photos/b.jpg"))
        // The same key on another server is independent.
        XCTAssertNil(cache.value(server: "other.test/bucket", key: "Photos/a.jpg"))

        clock.now = clock.now.addingTimeInterval(61)
        XCTAssertNil(cache.value(server: server, key: "Photos/a.jpg"), "entries expire")
        XCTAssertEqual(cache.count, 0, "an expired entry is dropped on read")
    }

    func testHeadCacheInvalidationAndLimit() {
        let cache = S3HeadCache(ttl: 60, limit: 4)
        for index in 0..<4 {
            cache.store(head(size: Int64(index)), latency: 0.01, server: "s", key: "k\(index)")
        }
        XCTAssertEqual(cache.count, 4)
        // A fifth entry evicts oldest-but-live entries instead of growing.
        cache.store(head(size: 99), latency: 0.01, server: "s", key: "k4")
        XCTAssertLessThanOrEqual(cache.count, 4)

        cache.store(head(size: 7), latency: 0.01, server: "s", key: "target")
        cache.invalidate(server: "s", key: "target")
        XCTAssertNil(cache.value(server: "s", key: "target"))

        cache.invalidateAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testDisabledHeadCacheNeverServesAValue() {
        let cache = S3HeadCache.disabled()
        cache.store(head(size: 1), latency: 0.01, server: "s", key: "k")
        XCTAssertNil(cache.value(server: "s", key: "k"))
    }

    // MARK: - Multipart upload journal

    private func makeJournal() throws -> (MultipartUploadJournal, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-journal-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (MultipartUploadJournal(fileURL: url), url)
    }

    func testJournalRoundTripsAndForgetsFinishedUploads() throws {
        let (journal, url) = try makeJournal()
        journal.begin(key: "Photos/a.jpg", uploadId: "upload-1", serverKey: "s3.test/bucket")
        journal.begin(key: "Photos/b.jpg", uploadId: "upload-2", serverKey: "s3.test/bucket")

        // A fresh instance reads what the previous one wrote, which is what a
        // relaunch does.
        let reloaded = MultipartUploadJournal(fileURL: url)
        XCTAssertEqual(reloaded.records().map(\.uploadId).sorted(), ["upload-1", "upload-2"])
        XCTAssertEqual(reloaded.records().first(where: { $0.uploadId == "upload-1" })?.key, "Photos/a.jpg")

        reloaded.finish(uploadId: "upload-1")
        XCTAssertEqual(reloaded.records().map(\.uploadId), ["upload-2"])
        reloaded.finish(uploadId: "does-not-exist")
        XCTAssertEqual(reloaded.records().count, 1)
    }

    func testJournalOnlyReportsStaleUploadsForTheSameServer() throws {
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 10_000_000)
        }
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-journal-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let journal = MultipartUploadJournal(fileURL: url, now: { clock.now })

        journal.begin(key: "old", uploadId: "old-id", serverKey: "server-a")
        clock.now = clock.now.addingTimeInterval(2 * 24 * 60 * 60)
        journal.begin(key: "new", uploadId: "new-id", serverKey: "server-a")
        journal.begin(key: "other", uploadId: "other-id", serverKey: "server-b")

        let stale = journal.staleRecords(serverKey: "server-a")
        XCTAssertEqual(stale.map(\.uploadId), ["old-id"])
        XCTAssertTrue(journal.staleRecords(serverKey: "server-b").isEmpty)
        XCTAssertEqual(journal.staleRecords(serverKey: "server-a", olderThan: 0).count, 2)
        XCTAssertTrue(journal.staleRecords(serverKey: "server-c").isEmpty)
    }

    func testJournalToleratesACorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-journal-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let journal = MultipartUploadJournal(fileURL: url)
        XCTAssertTrue(journal.records().isEmpty)
        journal.begin(key: "k", uploadId: "u", serverKey: "s")
        XCTAssertEqual(journal.records().count, 1, "a corrupt file is replaced, not fatal")
    }
}
