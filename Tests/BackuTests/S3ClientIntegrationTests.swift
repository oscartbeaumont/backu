import XCTest

/// End-to-end client test against `Tools/MockS3`. Start it first:
///
///     python3 Tools/MockS3/mock_s3.py --data-dir /tmp/backu-s3
///
/// The test skips itself when nothing is listening.
final class S3ClientIntegrationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:9000")!
    private let bucket = "backu-test"

    private func makeClient() -> S3Client {
        S3Client(
            connection: S3Connection(endpoint: endpoint, region: "us-east-1", bucket: bucket, pathStyle: true),
            credentials: S3Credentials(accessKeyID: "testkey", secretAccessKey: "testsecret")
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
            to: destination,
            sizeHint: Int64(body.count)
        )
        let downloaded = try Data(contentsOf: destination)
        XCTAssertEqual(downloaded, body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try await client.deleteObject(key: key)
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
