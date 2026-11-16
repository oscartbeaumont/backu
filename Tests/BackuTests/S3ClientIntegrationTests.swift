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
}
