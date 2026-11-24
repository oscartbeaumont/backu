import Foundation
import XCTest

final class AuditS3RegressionTests: XCTestCase {
    private var sessions: [URLSession] = []

    override func tearDown() {
        for session in sessions { session.invalidateAndCancel() }
        sessions.removeAll()
        AuditStubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(
        headCache: S3HeadCache? = .disabled(),
        handler: @escaping @Sendable (URLRequest) throws -> AuditStubURLProtocol.Result
    ) -> S3Client {
        AuditStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditStubURLProtocol.self]
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        return S3Client(
            connection: S3Connection(
                endpoint: URL(string: "http://s3.audit.test")!,
                region: "us-east-1",
                bucket: "audit-bucket",
                pathStyle: true
            ),
            credentials: S3Credentials(accessKeyID: "audit-key", secretAccessKey: "audit-secret"),
            session: session,
            headCache: headCache
        )
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-s3-\(UUID().uuidString).bin")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryDestination() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-s3-\(UUID().uuidString).bin")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
        }
        return url
    }

    func testIPv6HostHeaderKeepsAddressBrackets() throws {
        let withPort = try XCTUnwrap(URL(string: "http://[::1]:9000/audit-bucket/key"))
        let defaultPort = try XCTUnwrap(URL(string: "https://[2001:db8::1]/audit-bucket/key"))

        XCTAssertEqual(SigV4Signer.hostHeader(for: withPort), "[::1]:9000")
        XCTAssertEqual(SigV4Signer.hostHeader(for: defaultPort), "[2001:db8::1]")
    }

    func testListParserPreservesSignificantWhitespaceInKeysAndPrefixes() async throws {
        let key = "  Backu/ leading and trailing .jpg  "
        let commonPrefix = "  Backu/folder  "
        let xml = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>\(key)</Key>
            <LastModified>2026-11-24T00:00:00.000Z</LastModified>
            <ETag>"abc"</ETag>
            <Size>3</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <CommonPrefixes><Prefix>\(commonPrefix)</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
        }

        let page = try await client.listObjects(prefix: "Backu/", delimiter: "/")
        XCTAssertEqual(page.objects.map(\.key), [key])
        XCTAssertEqual(page.commonPrefixes, [commonPrefix])
    }

    func testListAllObjectsHonorsItsLimit() async throws {
        let xml = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>next-page</NextContinuationToken>
          <Contents><Key>a</Key><Size>1</Size></Contents>
          <Contents><Key>b</Key><Size>1</Size></Contents>
          <Contents><Key>c</Key><Size>1</Size></Contents>
        </ListBucketResult>
        """
        let client = makeClient { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "max-keys" })?.value, "2")
            return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
        }

        do {
            _ = try await client.listAllObjects(prefix: "", limit: 2)
            XCTFail("A bounded listing must report truncation instead of returning a partial library")
        } catch let S3Error.listTruncated(limit) {
            XCTAssertEqual(limit, 2)
        } catch {
            XCTFail("Unexpected listing error: \(error)")
        }
    }

    func testFullLengthPartialIsNotPromotedWithoutETagValidation() async throws {
        let remote = Data("current remote object contents".utf8)
        let gets = AuditCounter()
        let client = makeClient { request in
            if request.httpMethod == "HEAD" {
                return AuditStubURLProtocol.Result.result(
                    status: 200,
                    headers: ["Content-Length": String(remote.count), "ETag": "\"current-etag\""],
                    body: Data()
                )
            }
            gets.increment()
            return AuditStubURLProtocol.Result.result(
                status: 200,
                headers: ["Content-Length": String(remote.count), "ETag": "\"current-etag\""],
                body: remote
            )
        }
        let destination = temporaryDestination()
        let partial = destination.appendingPathExtension("part")
        try Data(repeating: 0x58, count: remote.count).write(to: partial)

        try await client.downloadObject(key: "Backu/photo.jpg", to: destination, tuning: .inMemory)

        let downloaded = try Data(contentsOf: destination)
        XCTAssertEqual(String(decoding: downloaded, as: UTF8.self), String(decoding: remote, as: UTF8.self))
        XCTAssertEqual(gets.value, 1, "a complete-looking partial must be validated by fetching the object")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testFailedHeadRevalidationPreservesAnExistingDestination() async throws {
        let heads = AuditCounter()
        let client = makeClient { request in
            if request.httpMethod == "HEAD" {
                let count = heads.incrementAndValue()
                if count == 1 {
                    return AuditStubURLProtocol.Result.result(
                        status: 200,
                        headers: ["Content-Length": "3", "ETag": "\"new-etag\""],
                        body: Data()
                    )
                }
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return AuditStubURLProtocol.Result.result(
                status: 412,
                body: Data("<Error><Code>PreconditionFailed</Code></Error>".utf8),
                contentType: "application/xml"
            )
        }
        let destination = temporaryDestination()
        let previous = Data("old".utf8)
        try previous.write(to: destination)

        do {
            try await client.downloadObject(key: "Backu/photo.jpg", to: destination, tuning: .inMemory)
            XCTFail("Expected revalidation to fail after the object disappeared")
        } catch {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testStaleSmallObjectSizeHintDoesNotRejectTheCurrentObject() async throws {
        let remote = Data("actual".utf8)
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return AuditStubURLProtocol.Result.result(
                status: 200,
                headers: ["Content-Length": String(remote.count)],
                body: remote
            )
        }
        let destination = temporaryDestination()

        try await client.downloadObject(
            key: "Backu/photo.jpg",
            to: destination,
            sizeHint: Int64(remote.count - 1),
            tuning: .inMemory
        )

        XCTAssertEqual(try Data(contentsOf: destination), remote)
    }

    func testCompleteMultipartRejectsAnErrorDocumentReturnedWithHTTP200() async throws {
        let xml = """
        <Error xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Code>InternalError</Code>
          <Message>The multipart upload was not completed.</Message>
          <RequestId>audit-request</RequestId>
        </Error>
        """
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
        }

        do {
            let etag = try await client.completeMultipartUpload(
                upload: S3MultipartUpload(key: "Backu/large.bin", uploadId: "upload-1"),
                parts: []
            )
            XCTFail("Expected the embedded S3 error to fail completion; got ETag \(etag.debugDescription)")
        } catch let error as S3Error {
            guard case let .http(status, code, _, _) = error else {
                return XCTFail("Expected an S3 HTTP error, got \(error)")
            }
            XCTAssertEqual(status, 200)
            XCTAssertEqual(code, "InternalError")
        }
    }

    func testSuccessfulGetReturnsErrorShapedXMLObject() async throws {
        let xml = "<Error><Code>InternalError</Code><Message>object payload</Message></Error>"
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
        }

        let data = try await client.getObject(key: "Backu/error-shaped.xml")

        XCTAssertEqual(data, Data(xml.utf8))
    }

    func testMultipartTransportRecoveryDoesNotAcceptSameSizedOldObject() async throws {
        let sourceData = Data(repeating: 0xAB, count: 5 * 1024 * 1024 + 1)
        let source = try temporaryFile(sourceData)
        let destination = temporaryDestination()
        let journalURL = destination.appendingPathExtension("json")
        addTeardownBlock { try? FileManager.default.removeItem(at: journalURL) }
        let journal = MultipartUploadJournal(fileURL: journalURL)
        let completeAttempts = AuditCounter()
        let oldETag = "\"old-object-etag\""
        let client = makeClient { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploads" }) {
                let xml = """
                <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                  <Bucket>audit-bucket</Bucket><Key>Backu/large.bin</Key><UploadId>upload-1</UploadId>
                </InitiateMultipartUploadResult>
                """
                return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
            }
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploadId" }) {
                completeAttempts.increment()
                throw URLError(.networkConnectionLost)
            }
            if request.httpMethod == "HEAD" {
                return AuditStubURLProtocol.Result.result(
                    status: 200,
                    headers: [
                        "Content-Length": String(sourceData.count),
                        "ETag": oldETag,
                        "Accept-Ranges": "bytes"
                    ],
                    body: Data()
                )
            }
            if request.httpMethod == "DELETE" {
                return AuditStubURLProtocol.Result.result(status: 204, body: Data())
            }
            throw URLError(.badServerResponse)
        }
        let transport = MultipartTransport(fileBacked: false) { _, number, _, _, size, progress in
            progress.report(1)
            return S3MultipartPart(number: number, etag: "\"part-\(number)\"", size: size)
        }
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            transport: transport,
            tuning: .inMemory,
            journal: journal
        )

        var reportedSuccess = false
        do {
            _ = try await uploader.upload(fileURL: source, key: "Backu/large.bin", contentType: "application/octet-stream")
            reportedSuccess = true
        } catch {
            // An uncertain completion must fail unless the new object can be identified.
        }

        XCTAssertEqual(completeAttempts.value, 5)
        XCTAssertFalse(reportedSuccess, "a same-sized pre-existing object must not prove that CompleteMultipartUpload committed")
        XCTAssertTrue(journal.records().isEmpty, "the follow-up abort should clean up the uncommitted upload")
    }

    func testCommittedMultipartUploadIsRecoveredWhenRetryGetsNoSuchUpload() async throws {
        let sourceData = Data(repeating: 0xCD, count: 5 * 1024 * 1024 + 1)
        let source = try temporaryFile(sourceData)
        let destination = temporaryDestination()
        let journalURL = destination.appendingPathExtension("json")
        addTeardownBlock { try? FileManager.default.removeItem(at: journalURL) }
        let journal = MultipartUploadJournal(fileURL: journalURL)
        let completeAttempts = AuditCounter()
        let committed = AuditFlag()
        let client = makeClient { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploads" }) {
                let xml = """
                <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                  <Bucket>audit-bucket</Bucket><Key>Backu/large.bin</Key><UploadId>upload-1</UploadId>
                </InitiateMultipartUploadResult>
                """
                return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
            }
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploadId" }) {
                let attempt = completeAttempts.incrementAndValue()
                if attempt == 1 {
                    // The service committed the object but its response was a retryable 503.
                    committed.set(true)
                    let xml = "<Error><Code>ServiceUnavailable</Code><Message>retry</Message></Error>"
                    return AuditStubURLProtocol.Result.result(
                        status: 503,
                        body: Data(xml.utf8),
                        contentType: "application/xml"
                    )
                }
                let xml = "<Error><Code>NoSuchUpload</Code><Message>already completed</Message></Error>"
                return AuditStubURLProtocol.Result.result(
                    status: 404,
                    body: Data(xml.utf8),
                    contentType: "application/xml"
                )
            }
            if request.httpMethod == "HEAD" {
                if committed.value {
                    return AuditStubURLProtocol.Result.result(
                        status: 200,
                        headers: [
                            "Content-Length": String(sourceData.count),
                            "ETag": "\"committed-etag\"",
                            "Accept-Ranges": "bytes"
                        ],
                        body: Data()
                    )
                }
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            if request.httpMethod == "DELETE" {
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            throw URLError(.badServerResponse)
        }
        let transport = MultipartTransport(fileBacked: false) { _, number, _, _, size, progress in
            progress.report(1)
            return S3MultipartPart(number: number, etag: "\"part-\(number)\"", size: size)
        }
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            transport: transport,
            tuning: .inMemory,
            journal: journal
        )

        var reportedSuccess = false
        do {
            _ = try await uploader.upload(fileURL: source, key: "Backu/large.bin", contentType: "application/octet-stream")
            reportedSuccess = true
        } catch {
            // A committed object should be reconciled after the retry receives NoSuchUpload.
        }

        XCTAssertEqual(completeAttempts.value, 2)
        XCTAssertTrue(committed.value)
        XCTAssertTrue(reportedSuccess, "NoSuchUpload after a retryable complete response must be reconciled against the committed object")
        XCTAssertTrue(journal.records().isEmpty)
    }

    func testMultipartRetryRecoveryRejectsSameSizedOldObjectAndKeepsJournal() async throws {
        let sourceData = Data(repeating: 0xAB, count: 5 * 1024 * 1024 + 1)
        let source = try temporaryFile(sourceData)
        let destination = temporaryDestination()
        let journalURL = destination.appendingPathExtension("json")
        addTeardownBlock { try? FileManager.default.removeItem(at: journalURL) }
        let journal = MultipartUploadJournal(fileURL: journalURL)
        let completeAttempts = AuditCounter()
        let heads = AuditCounter()
        let deletes = AuditCounter()
        let oldETag = #""old-object-etag""#
        let client = makeClient { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploads" }) {
                let xml = """
                <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                  <Bucket>audit-bucket</Bucket><Key>Backu/large.bin</Key><UploadId>upload-1</UploadId>
                </InitiateMultipartUploadResult>
                """
                return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
            }
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploadId" }) {
                let attempt = completeAttempts.incrementAndValue()
                if attempt == 1 {
                    let xml = "<Error><Code>ServiceUnavailable</Code><Message>retry</Message></Error>"
                    return AuditStubURLProtocol.Result.result(
                        status: 503,
                        body: Data(xml.utf8),
                        contentType: "application/xml"
                    )
                }
                let xml = "<Error><Code>NoSuchUpload</Code><Message>already completed</Message></Error>"
                return AuditStubURLProtocol.Result.result(
                    status: 404,
                    body: Data(xml.utf8),
                    contentType: "application/xml"
                )
            }
            if request.httpMethod == "HEAD" {
                heads.increment()
                return AuditStubURLProtocol.Result.result(
                    status: 200,
                    headers: [
                        "Content-Length": String(sourceData.count),
                        "ETag": oldETag,
                        "Accept-Ranges": "bytes"
                    ],
                    body: Data()
                )
            }
            if request.httpMethod == "DELETE" {
                deletes.increment()
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            throw URLError(.badServerResponse)
        }
        let transport = MultipartTransport(fileBacked: false) { _, number, _, _, size, progress in
            progress.report(1)
            return S3MultipartPart(number: number, etag: "part-\(number)", size: size)
        }
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            transport: transport,
            tuning: .inMemory,
            journal: journal
        )

        var reportedSuccess = false
        do {
            _ = try await uploader.upload(fileURL: source, key: "Backu/large.bin", contentType: "application/octet-stream")
            reportedSuccess = true
        } catch {
            // Expected: the old object's identity did not change.
        }

        XCTAssertEqual(completeAttempts.value, 2)
        XCTAssertEqual(heads.value, 2)
        XCTAssertFalse(reportedSuccess, "an unchanged same-sized object must not prove completion")
        XCTAssertEqual(journal.records().map(\.uploadId), ["upload-1"])
        XCTAssertEqual(deletes.value, 0, "an unresolved completion must not be treated as a confirmed abort")
    }

    func testMultipartTransportRetryReconcilesCommittedObjectAfterNoSuchUpload() async throws {
        let sourceData = Data(repeating: 0xCD, count: 5 * 1024 * 1024 + 1)
        let source = try temporaryFile(sourceData)
        let destination = temporaryDestination()
        let journalURL = destination.appendingPathExtension("json")
        addTeardownBlock { try? FileManager.default.removeItem(at: journalURL) }
        let journal = MultipartUploadJournal(fileURL: journalURL)
        let completeAttempts = AuditCounter()
        let heads = AuditCounter()
        let deletes = AuditCounter()
        let committed = AuditFlag()
        let client = makeClient { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploads" }) {
                let xml = """
                <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                  <Bucket>audit-bucket</Bucket><Key>Backu/large.bin</Key><UploadId>upload-1</UploadId>
                </InitiateMultipartUploadResult>
                """
                return AuditStubURLProtocol.Result.result(status: 200, body: Data(xml.utf8), contentType: "application/xml")
            }
            if request.httpMethod == "POST", query.contains(where: { $0.name == "uploadId" }) {
                let attempt = completeAttempts.incrementAndValue()
                if attempt == 1 {
                    committed.set(true)
                    throw URLError(.networkConnectionLost)
                }
                let xml = "<Error><Code>NoSuchUpload</Code><Message>already completed</Message></Error>"
                return AuditStubURLProtocol.Result.result(
                    status: 404,
                    body: Data(xml.utf8),
                    contentType: "application/xml"
                )
            }
            if request.httpMethod == "HEAD" {
                heads.increment()
                if committed.value {
                    return AuditStubURLProtocol.Result.result(
                        status: 200,
                        headers: [
                            "Content-Length": String(sourceData.count),
                            "ETag": #""committed-etag""#,
                            "Accept-Ranges": "bytes"
                        ],
                        body: Data()
                    )
                }
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            if request.httpMethod == "DELETE" {
                deletes.increment()
                return AuditStubURLProtocol.Result.result(status: 404, body: Data())
            }
            throw URLError(.badServerResponse)
        }
        let transport = MultipartTransport(fileBacked: false) { _, number, _, _, size, progress in
            progress.report(1)
            return S3MultipartPart(number: number, etag: "part-\(number)", size: size)
        }
        let uploader = MultipartUploader(
            client: client,
            partSize: 5 * 1024 * 1024,
            concurrency: 1,
            threshold: 0,
            transport: transport,
            tuning: .inMemory,
            journal: journal
        )

        var reportedSuccess = false
        do {
            _ = try await uploader.upload(fileURL: source, key: "Backu/large.bin", contentType: "application/octet-stream")
            reportedSuccess = true
        } catch {
            // Expected only if the committed object cannot be identified.
        }

        XCTAssertEqual(completeAttempts.value, 2)
        XCTAssertEqual(heads.value, 2)
        XCTAssertTrue(committed.value)
        XCTAssertTrue(reportedSuccess, "a transport retry followed by NoSuchUpload must reconcile a newly appeared object")
        XCTAssertTrue(journal.records().isEmpty)
        XCTAssertEqual(deletes.value, 0)
    }

    func testSinglePutThroughMultipartUploaderInvalidatesCachedHead() async throws {
        let source = try temporaryFile(Data("new".utf8))
        let cache = S3HeadCache()
        let client = makeClient(headCache: cache) { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            return AuditStubURLProtocol.Result.result(status: 200, headers: ["ETag": "\"new-etag\""], body: Data())
        }
        let key = "Backu/photo.jpg"
        cache.store(
            S3ObjectHead(key: key, size: 99, etag: "\"old-etag\"", contentType: "text/plain", acceptRanges: true),
            latency: 0.01,
            server: client.connection.transferTuningKey,
            key: key
        )
        let uploader = MultipartUploader(
            client: client,
            threshold: 1_024 * 1_024,
            tuning: .inMemory,
            journal: nil
        )

        _ = try await uploader.upload(fileURL: source, key: key, contentType: "text/plain")

        XCTAssertNil(
            cache.value(server: client.connection.transferTuningKey, key: key),
            "a successful single PUT must invalidate an older cached HEAD"
        )
    }
}

private final class AuditCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    func incrementAndValue() -> Int {
        lock.lock()
        stored += 1
        defer { lock.unlock() }
        return stored
    }
}

private final class AuditFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class AuditStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Result: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func result(status: Int, headers: [String: String] = [:], body: Data, contentType: String? = nil) -> Result {
            var fields = headers
            if fields["Content-Length"] == nil {
                fields["Content-Length"] = String(body.count)
            }
            if let contentType, fields["Content-Type"] == nil {
                fields["Content-Type"] = contentType
            }
            return Result(status: status, headers: fields, body: body)
        }
    }

    private static let lock = NSLock()
    static var handler: (@Sendable (URLRequest) throws -> Result)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    private static var storedHandler: (@Sendable (URLRequest) throws -> Result)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
            )
            guard let response else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD", !result.body.isEmpty {
                client?.urlProtocol(self, didLoad: result.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
