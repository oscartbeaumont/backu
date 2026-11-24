import XCTest

/// End-to-end client test against `Tools/MockS3`. Start it first:
///
///     python3 Tools/MockS3/mock_s3.py --data-dir /tmp/backu-s3
///
/// The test skips itself when nothing is listening.
final class S3ClientIntegrationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9000")!
    private let bucket = "backu-test"

    private func makeClient(metrics: S3Metrics? = nil) -> S3Client {
        S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret"),
            metrics: metrics
        )
    }

    private func requireServer() async throws {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 1.5
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: config)
        do {
            _ = try await session.data(for: request)
        } catch {
            throw XCTSkip("Mock S3 is not running on \(endpoint) — start Tools/MockS3/mock_s3.py")
        }
    }

    func testPutGetListAndDelete() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/hello world ☃.txt"
        let body = Data("backu integration ✓".utf8)

        try await client.putObject(key: key, data: body, contentType: "text/plain")
        let fetched = try await client.getObject(key: key)
        XCTAssertEqual(fetched, body)

        let head = try await client.headObject(key: key)
        XCTAssertEqual(head?.size, Int64(body.count))
        XCTAssertEqual(head?.contentType, "text/plain")

        let page = try await client.listObjects(prefix: "Backu/Tests/")
        XCTAssertTrue(page.objects.contains { $0.key == key })

        try await client.deleteObject(key: key)
        let missing = try await client.headObject(key: key)
        XCTAssertNil(missing)
    }

    func testPagination() async throws {
        try await requireServer()
        let client = makeClient()
        let prefix = "Backu/Pagination-\(UUID().uuidString.prefix(6))/"
        for index in 0..<7 {
            try await client.putObject(key: prefix + "file-\(index).txt", data: Data("x".utf8))
        }
        let all = try await client.listAllObjects(prefix: prefix)
        XCTAssertEqual(all.count, 7)
        for object in all { try await client.deleteObject(key: object.key) }
    }

    func testVerifyChecksReadWriteAndList() async throws {
        try await requireServer()
        let client = makeClient()
        let report = try await client.verify(prefix: "Backu/Verify")
        XCTAssertTrue(report.canList)
        XCTAssertTrue(report.canWrite)
        XCTAssertTrue(report.canRead)
        XCTAssertLessThan(report.latency, 10)
    }

    func testBadSignatureIsRejected() async throws {
        try await requireServer()
        let client = S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "wrong-secret")
        )
        do {
            _ = try await client.listObjects(prefix: "")
            XCTFail("Expected a signature failure")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "SignatureDoesNotMatch")
        }
    }

    func testWrongBucketReportsFriendlyError() async throws {
        try await requireServer()
        let client = S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: "nope-does-not-exist", pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
        )
        do {
            _ = try await client.listObjects(prefix: "")
            XCTFail("Expected NoSuchBucket")
        } catch let error as S3Error {
            XCTAssertTrue(error.errorDescription?.contains("does not exist") == true)
        }
    }

    // MARK: - Multipart and ranges

    private func makeTemporaryFile(bytes: Int, fill: UInt8 = 0x5A) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(repeating: fill, count: 1024 * 1024)
        var remaining = bytes
        while remaining > 0 {
            try handle.write(contentsOf: chunk.prefix(min(remaining, chunk.count)))
            remaining -= min(remaining, chunk.count)
        }
        return url
    }

    func testMultipartClientLifecycleAndSignature() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/multipart-\(UUID().uuidString.prefix(8)).bin"
        let first = Data(repeating: 0x11, count: 5 * 1024 * 1024)
        let second = Data(repeating: 0x22, count: 4096)

        let upload = try await client.createMultipartUpload(key: key, contentType: "application/octet-stream")
        let partOne = try await client.uploadPart(upload: upload, partNumber: 1, data: first)
        let partTwo = try await client.uploadPart(upload: upload, partNumber: 2, data: second)
        XCTAssertEqual(partOne.size, Int64(first.count))
        XCTAssertEqual(partTwo.size, Int64(second.count))

        let listed = try await client.listParts(upload: upload)
        XCTAssertEqual(listed.map(\.number), [1, 2])
        XCTAssertEqual(Set(listed.map(\.etag)), Set([partOne.etag, partTwo.etag]))

        let etag = try await client.completeMultipartUpload(upload: upload, parts: [partOne, partTwo])
        XCTAssertTrue(etag.hasSuffix("-2\""), "unexpected multipart ETag \(etag)")

        let fetched = try await client.getObject(key: key)
        XCTAssertEqual(fetched, first + second)
        let head = try await client.headObject(key: key)
        XCTAssertEqual(head?.size, Int64(first.count + second.count))
        try await client.deleteObject(key: key)
    }

    func testMultipartUploaderStreamsAFile() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/uploader-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: 6 * 1024 * 1024 + 123)
        defer { try? FileManager.default.removeItem(at: source) }

        let progress = ProgressBox()
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 2,
            threshold: 0,
            progress: { fraction in progress.record(fraction) }
        )
        let hash = try await uploader.upload(
            fileURL: source,
            key: key,
            contentType: "application/octet-stream"
        )
        XCTAssertEqual(hash, try SigV4Signer.sha256Hex(contentsOfFile: source))
        XCTAssertGreaterThan(progress.value, 0.99)

        let fetched = try await client.getObject(key: key)
        XCTAssertEqual(Int64(fetched.count), 6 * 1024 * 1024 + 123)
        XCTAssertEqual(fetched.first, 0x5A)
        XCTAssertEqual(fetched.last, 0x5A)
        try await client.deleteObject(key: key)
    }

    func testAbortMultipartRemovesTheUpload() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/abort-\(UUID().uuidString.prefix(8)).bin"
        let upload = try await client.createMultipartUpload(key: key, contentType: "application/octet-stream")
        _ = try await client.uploadPart(
            upload: upload,
            partNumber: 1,
            data: Data(repeating: 1, count: 1024)
        )
        try await client.abortMultipartUpload(upload: upload)
        do {
            _ = try await client.listParts(upload: upload)
            XCTFail("Expected NoSuchUpload")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "NoSuchUpload")
        }
    }

    func testParallelRangeDownloadToFile() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/parallel-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: 40 * 1024 * 1024, fill: 0x33)
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await client.putFile(key: key, fileURL: source, contentType: "application/octet-stream")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let progress = ProgressBox()
        try await client.downloadObject(
            key: key,
            to: destination,
            sizeHint: 40 * 1024 * 1024,
            concurrency: 4,
            minimumRoundTripForParallel: 0,
            progress: { fraction in progress.record(fraction) }
        )
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(values.fileSize, 40 * 1024 * 1024)
        XCTAssertGreaterThan(progress.value, 0.99)
        XCTAssertEqual(try SigV4Signer.sha256Hex(contentsOfFile: destination),
                       try SigV4Signer.sha256Hex(contentsOfFile: source))
        try await client.deleteObject(key: key)
    }

    func testSizeHintStillProbesAndUsesRanges() async throws {
        try await requireServer()
        // 24 MiB is below the old 32 MiB threshold and the caller knows the
        // size, but the HEAD probe must still run so a real network can fan out.
        let bytes = 24 * 1024 * 1024
        let metrics = S3Metrics()
        let client = makeClient(metrics: metrics)
        let key = "Backu/Tests/hinted-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: bytes, fill: 0x21)
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await client.putFile(key: key, fileURL: source, contentType: "application/octet-stream")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-hinted-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        metrics.reset()
        try await client.downloadObject(
            key: key,
            to: destination,
            sizeHint: Int64(bytes),
            concurrency: 3,
            minimumRoundTripForParallel: 0,
            tuning: .inMemory
        )
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(values.fileSize, bytes)
        // One HEAD plus one request per range.
        XCTAssertEqual(metrics.snapshot().requests, 4)
        try await client.deleteObject(key: key)
    }

    func testRepeatedDownloadReusesCachedHeadMetadata() async throws {
        try await requireServer()
        let bytes = 24 * 1024 * 1024
        let metrics = S3Metrics()
        let cache = S3HeadCache()
        let client = S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret"),
            metrics: metrics,
            headCache: cache
        )
        let key = "Backu/Tests/headcache-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: bytes, fill: 0x19)
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await client.putFile(key: key, fileURL: source, contentType: "application/octet-stream")

        func download() async throws -> URL {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("backu-headcache-\(UUID().uuidString).bin")
            try await client.downloadObject(
                key: key,
                to: destination,
                sizeHint: Int64(bytes),
                concurrency: 3,
                minimumRoundTripForParallel: 0,
                tuning: .inMemory
            )
            return destination
        }

        metrics.reset()
        let first = try await download()
        defer { try? FileManager.default.removeItem(at: first) }
        XCTAssertEqual(metrics.snapshot().requests, 4, "HEAD + three ranges")
        XCTAssertEqual(try first.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes)

        // A second open within the TTL skips the metadata round trip entirely.
        metrics.reset()
        let second = try await download()
        defer { try? FileManager.default.removeItem(at: second) }
        XCTAssertEqual(metrics.snapshot().requests, 3, "cached HEAD + three ranges")
        XCTAssertEqual(try second.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes)

        // Writing the object invalidates the entry, so the next open probes.
        try await client.putObject(key: key, data: Data("small".utf8), contentType: "text/plain")
        metrics.reset()
        let third = try await download()
        XCTAssertEqual(try third.resourceValues(forKeys: [.fileSizeKey]).fileSize, 5)
        XCTAssertEqual(metrics.snapshot().requests, 2, "the PUT invalidated the cached HEAD: HEAD + one GET")
        try? FileManager.default.removeItem(at: third)

        try await client.deleteObject(key: key)
    }

    func testCachedHeadIsRevalidatedWhenAnotherDeviceReplacesTheObject() async throws {
        try await requireServer()
        let bytes = 24 * 1024 * 1024
        let cache = S3HeadCache()
        let reader = S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret"),
            headCache: cache
        )
        // A second "device" sharing the bucket but not the cache, so a write it
        // makes leaves the reader's cached HEAD stale, like a real overwrite
        // from another app instance.
        let writer = S3Client(
            connection: reader.connection,
            credentials: reader.credentials,
            headCache: nil
        )
        let key = "Backu/Tests/overwrite-\(UUID().uuidString.prefix(8)).bin"
        let first = try makeTemporaryFile(bytes: bytes, fill: 0x11)
        let second = try makeTemporaryFile(bytes: bytes, fill: 0x22)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        _ = try await writer.putFile(key: key, fileURL: first, contentType: "application/octet-stream")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-overwrite-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        func download() async throws -> Data {
            try await reader.downloadObject(
                key: key,
                to: destination,
                sizeHint: Int64(bytes),
                concurrency: 4,
                minimumRoundTripForParallel: 0,
                tuning: .inMemory
            )
            return try Data(contentsOf: destination)
        }

        let original = try await download()
        XCTAssertEqual(original.first, 0x11)
        XCTAssertNotNil(cache.value(server: reader.connection.transferTuningKey, key: key))

        _ = try await writer.putFile(key: key, fileURL: second, contentType: "application/octet-stream")

        // The cached size and ETag are now stale. The range GETs fail 412, the
        // downloader drops the entry, re-probes and returns the new bytes.
        let replaced = try await download()
        XCTAssertEqual(replaced.first, 0x22)
        XCTAssertEqual(replaced.last, 0x22)
        XCTAssertEqual(replaced.count, bytes)
        let refreshed = try await reader.headObject(key: key)?.etag
        XCTAssertEqual(
            cache.value(server: reader.connection.transferTuningKey, key: key)?.head.etag,
            refreshed
        )
        try await reader.deleteObject(key: key)
    }

    func testDownloadResumesFromAPartialFile() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/resume-\(UUID().uuidString.prefix(8)).bin"
        let body = Data(repeating: 0x77, count: 4 * 1024 * 1024)
        try await client.putObject(key: key, data: body, contentType: "application/octet-stream")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-resume-\(UUID().uuidString).bin")
        let partial = destination.appendingPathExtension("part")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
        }
        try body.prefix(1024 * 1024).write(to: partial)

        try await client.downloadObject(
            key: key,
            to: destination
        )
        let downloaded = try Data(contentsOf: destination)
        XCTAssertEqual(downloaded, body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try await client.deleteObject(key: key)
    }

    func testCancellingMultipartAbortsAndCleansUp() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/cancel-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: 6 * 1024 * 1024, fill: 0x55)
        defer { try? FileManager.default.removeItem(at: source) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let journal = MultipartUploadJournal(fileURL: staging.appendingPathComponent("journal.json"))
        let uploadID = IDBox()
        // File-backed on purpose: this exercises the staged part file that a
        // cancelled upload must clean up.
        let transport = MultipartTransport(fileBacked: true) { upload, _, payload, _, _, _ in
            uploadID.set(upload.uploadId)
            guard case let .file(url) = payload,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw S3Error.decoding("Part file missing before the transport ran")
            }
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            throw CancellationError()
        }
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            temporaryDirectory: staging,
            transport: transport,
            tuning: .inMemory,
            journal: journal
        )
        let task = Task {
            try await uploader.upload(fileURL: source, key: key, contentType: "application/octet-stream")
        }
        var waited = 0
        while uploadID.value == nil && waited < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        task.cancel()
        _ = await task.result

        let id = try XCTUnwrap(uploadID.value)
        do {
            _ = try await client.listParts(upload: S3MultipartUpload(key: key, uploadId: id))
            XCTFail("The multipart upload was not aborted")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "NoSuchUpload")
        }
        // A cancelled upload that was aborted leaves no journal record, and no
        // staged part files behind (the journal file lives outside the staging
        // tree the uploader owns).
        XCTAssertTrue(journal.records().isEmpty, "cancelled upload left a journal record")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0 != "journal.json" }
        XCTAssertTrue(leftovers.isEmpty, "Temporary part files left behind: \(leftovers)")
    }

    func testStaleMultipartUploadsAreAbortedAndForgotten() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/orphan-\(UUID().uuidString.prefix(8)).bin"
        let upload = try await client.createMultipartUpload(key: key, contentType: "application/octet-stream")
        _ = try await client.uploadPart(
            upload: upload,
            partNumber: 1,
            data: Data(repeating: 0x66, count: 64 * 1024)
        )

        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-orphans-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = MultipartUploadJournal(fileURL: journalURL)
        journal.begin(
            key: key,
            uploadId: upload.uploadId,
            serverKey: client.connection.transferTuningKey
        )
        // A record for a different server must not be touched by this client.
        journal.begin(key: "elsewhere", uploadId: "other-server-id", serverKey: "other.test/bucket")

        let aborted = await client.abortStaleMultipartUploads(journal: journal, olderThan: 0)
        XCTAssertEqual(aborted, 1)
        XCTAssertEqual(journal.records().map(\.uploadId), ["other-server-id"])

        do {
            _ = try await client.listParts(upload: upload)
            XCTFail("The stale upload survived recovery")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "NoSuchUpload")
        }
    }

    func testForcedPartFailureAbortsTheUploadAndClearsTheJournal() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/forced-\(UUID().uuidString.prefix(8)).bin"
        let source = try makeTemporaryFile(bytes: 12 * 1024 * 1024, fill: 0x5F)
        defer { try? FileManager.default.removeItem(at: source) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-forced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let journal = MultipartUploadJournal(fileURL: staging.appendingPathComponent("journal.json"))
        let seen = IDBox()
        // Part 1 succeeds against the real server, part 2 never leaves the
        // process. The uploader must abort the whole upload and forget it.
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            temporaryDirectory: staging,
            transport: .direct(client: client),
            tuning: .inMemory,
            journal: journal
        )
        // Wrap the direct transport so the failure is forced, not injected.
        var failing = uploader
        failing.transport = MultipartTransport(fileBacked: false) { upload, number, payload, hash, size, progress in
            seen.set(upload.uploadId)
            if number >= 2 {
                throw S3Error.transport(URLError(.networkConnectionLost))
            }
            return try await MultipartTransport.direct(client: client).uploadPart(
                upload,
                number,
                payload,
                hash,
                size,
                progress
            )
        }

        do {
            _ = try await failing.upload(fileURL: source, key: key, contentType: "application/octet-stream")
            XCTFail("The upload should have failed")
        } catch {
            // Expected.
        }

        let id = try XCTUnwrap(seen.value)
        XCTAssertTrue(journal.records().isEmpty, "failed upload left a journal record")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0 != "journal.json" }
        XCTAssertTrue(leftovers.isEmpty, "staged part files left behind: \(leftovers)")

        do {
            _ = try await client.listParts(upload: S3MultipartUpload(key: key, uploadId: id))
            XCTFail("The failed multipart upload was not aborted")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "NoSuchUpload")
        }
        let head = try await client.headObject(key: key)
        XCTAssertNil(head, "a failed upload must not leave an object behind")
    }

    func testBackgroundUploaderCarriesAPartETag() async throws {
        try await requireServer()
        let client = makeClient()
        let key = "Backu/Tests/background-part-\(UUID().uuidString.prefix(8)).bin"
        let partURL = try makeTemporaryFile(bytes: 5 * 1024 * 1024, fill: 0x44)
        defer { try? FileManager.default.removeItem(at: partURL) }

        let upload = try await client.createMultipartUpload(key: key, contentType: "application/octet-stream")
        let hash = try SigV4Signer.sha256Hex(contentsOfFile: partURL)
        let request = try client.signedUploadPartRequest(
            upload: upload,
            partNumber: 1,
            payloadHash: hash
        )
        let result = try await BackgroundUploader.shared.uploadResult(
            fileURL: partURL,
            request: request,
            allowsCellular: true,
            progress: { _ in }
        )
        XCTAssertEqual(result.status, 200)
        let etag = try XCTUnwrap(result.etag)
        let part = S3MultipartPart(number: 1, etag: etag, size: 5 * 1024 * 1024)
        _ = try await client.completeMultipartUpload(upload: upload, parts: [part])

        let fetched = try await client.getObject(key: key)
        XCTAssertEqual(fetched.count, 5 * 1024 * 1024)
        XCTAssertEqual(fetched.first, 0x44)
        try await client.deleteObject(key: key)
    }
}


private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double = 0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ fraction: Double) {
        lock.lock()
        stored = max(stored, fraction)
        lock.unlock()
    }
}

private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
