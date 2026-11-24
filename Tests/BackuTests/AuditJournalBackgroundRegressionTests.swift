import Foundation
import Network
import XCTest
#if canImport(Darwin)
import Darwin
#endif

/// Focused regressions for journal reconciliation and background upload identity. The S3
/// transport is intercepted in-process or by a loopback-only stub; no external
/// endpoint or credential is used.
///
/// CatalogStore and BackupEngine resolve Application Support at process launch.
/// Run with CFFIXED_USER_HOME, BACKU_AUDIT_ISOLATED_HOME=1, and
/// BACKU_FOREGROUND_UPLOADS=1 (or pass `-BackuAuditHome <scratch-directory>`
/// to the test bundle). The guard below skips rather than touching real data.
@MainActor
final class AuditJournalBackgroundRegressionTests: XCTestCase {
    private static let auditBucket = "audit-bucket"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-BackuAuditHome"), index + 1 < arguments.count {
            setenv("CFFIXED_USER_HOME", arguments[index + 1], 1)
            setenv("BACKU_AUDIT_ISOLATED_HOME", "1", 1)
        }
        let environment = ProcessInfo.processInfo.environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let home = environment["CFFIXED_USER_HOME"],
              !home.isEmpty,
              environment["BACKU_AUDIT_ISOLATED_HOME"] == "1",
              let support,
              support.path.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("Isolation missing: home=\(environment["CFFIXED_USER_HOME"] as Any), marker=\(environment["BACKU_AUDIT_ISOLATED_HOME"] as Any), support=\(support?.path as Any)")
        }
        AuditJournalBackgroundURLProtocol.setHandler(nil)
    }

    override func tearDownWithError() throws {
        AuditJournalBackgroundURLProtocol.setHandler(nil)
        try super.tearDownWithError()
    }

    func testReconcilerRejectsObjectSizeMismatch() async throws {
        let directory = try temporaryDirectory()
        let server = makeServer()
        let photo = makePhoto(id: "asset:reconcile-size")
        let objectKey = BackupEngine.objectKey(for: photo, in: server)
        let sidecarKey = objectKey + ".json"
        AuditJournalBackgroundURLProtocol.setHandler { request in
            switch (request.httpMethod, Self.objectKey(for: request)) {
            case ("HEAD", objectKey):
                return (200, Data(), ["Content-Length": "3", "ETag": "\"old-object\""])
            case ("GET", sidecarKey):
                return (404, Data(), [:])
            case ("PUT", sidecarKey):
                return (200, Data(), ["ETag": "\"new-sidecar\""])
            default:
                return (404, Data(), [:])
            }
        }
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned([photo], removingMissing: false)
        let journal = UploadJournal(fileURL: directory.appendingPathComponent("journal.json"))
        journal.begin(
            UploadRecord(
                photoID: photo.id,
                serverID: server.id,
                objectKey: objectKey,
                sidecarKey: sidecarKey,
                byteCount: 10,
                sha256: nil,
                startedAt: Date()
            )
        )

        let recovered = await UploadReconciler.reconcile(
            server: server,
            client: client,
            catalog: catalog,
            journal: journal
        )

        XCTAssertEqual(recovered, 0, "A differently sized object is not the transfer described by the journal")
        XCTAssertNil(catalog.photo(id: photo.id)?.copy(on: server.id))
        XCTAssertEqual(journal.pending(serverID: server.id).count, 1)
    }

    func testReconcilerRejectsSidecarHashMismatch() async throws {
        let directory = try temporaryDirectory()
        let server = makeServer()
        let photo = makePhoto(id: "asset:reconcile-hash", sha256: "expected-new-hash")
        let objectKey = BackupEngine.objectKey(for: photo, in: server)
        let sidecarKey = objectKey + ".json"
        let oldSidecar = try SidecarDocument.make(
            photo: photo,
            people: [:],
            device: "audit",
            sha256: "stale-old-hash"
        ).data()
        AuditJournalBackgroundURLProtocol.setHandler { request in
            switch (request.httpMethod, Self.objectKey(for: request)) {
            case ("HEAD", objectKey):
                return (200, Data(), ["Content-Length": "10", "ETag": "\"old-object\""])
            case ("GET", sidecarKey):
                return (200, oldSidecar, ["Content-Type": "application/json"])
            default:
                return (404, Data(), [:])
            }
        }
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned([photo], removingMissing: false)
        let journal = UploadJournal(fileURL: directory.appendingPathComponent("journal.json"))
        journal.begin(
            UploadRecord(
                photoID: photo.id,
                serverID: server.id,
                objectKey: objectKey,
                sidecarKey: sidecarKey,
                byteCount: 10,
                sha256: "expected-new-hash",
                startedAt: Date()
            )
        )

        let recovered = await UploadReconciler.reconcile(
            server: server,
            client: client,
            catalog: catalog,
            journal: journal
        )

        XCTAssertEqual(recovered, 0, "A sidecar for different bytes must not complete the journaled transfer")
        XCTAssertNil(catalog.photo(id: photo.id)?.copy(on: server.id))
        XCTAssertEqual(catalog.photo(id: photo.id)?.sha256, "expected-new-hash")
        XCTAssertEqual(journal.pending(serverID: server.id).count, 1)
    }

    func testReconcilerKeepsJournalEntryWhenObjectIsNotVisibleYet() async throws {
        let directory = try temporaryDirectory()
        let server = makeServer()
        let photo = makePhoto(id: "asset:reconcile-in-flight")
        let objectKey = BackupEngine.objectKey(for: photo, in: server)
        AuditJournalBackgroundURLProtocol.setHandler { _ in (404, Data(), [:]) }
        let client = makeClient(server: server)
        defer { client.session.invalidateAndCancel() }
        let catalog = CatalogStore(loadFromDisk: false)
        catalog.mergeScanned([photo], removingMissing: false)
        let journal = UploadJournal(fileURL: directory.appendingPathComponent("journal.json"))
        journal.begin(
            UploadRecord(
                photoID: photo.id,
                serverID: server.id,
                objectKey: objectKey,
                sidecarKey: objectKey + ".json",
                byteCount: 10,
                sha256: nil,
                startedAt: Date()
            )
        )

        let recovered = await UploadReconciler.reconcile(
            server: server,
            client: client,
            catalog: catalog,
            journal: journal
        )

        XCTAssertEqual(recovered, 0)
        XCTAssertNil(catalog.photo(id: photo.id)?.copy(on: server.id))
        XCTAssertEqual(
            journal.pending(serverID: server.id).count,
            1,
            "A 404 during an in-flight background upload is not proof that the transfer failed"
        )
    }

    func testBackgroundUploaderDoesNotMatchPreviousProcessJobID() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("upload.bin")
        try Data("new upload".utf8).write(to: file)
        let newStarted = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        AuditJournalBackgroundURLProtocol.setHandler { request in
            if request.value(forHTTPHeaderField: "X-Audit-Generation") == "old" {
                return (200, Data(), [:])
            }
            newStarted.signal()
            _ = releaseNew.wait(timeout: .now() + 10)
            return (503, Data(), [:])
        }

        let listener = try NWListener(using: .tcp, on: .any)
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        let listenerQueue = DispatchQueue(label: "backu.audit.loopback")
        listener.newConnectionHandler = { connection in
            connection.start(queue: listenerQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if !(data?.isEmpty ?? true) { newStarted.signal() }
                _ = releaseNew.wait(timeout: .now() + 10)
                let response = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        let isListenerReady = await Task.detached { listenerReady.wait(timeout: .now() + 5) }.value
        guard isListenerReady == .success else {
            XCTFail("The loopback listener did not become ready")
            return
        }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let oldConfiguration = URLSessionConfiguration.ephemeral
        oldConfiguration.protocolClasses = [AuditJournalBackgroundURLProtocol.self]
        let oldSession = URLSession(configuration: oldConfiguration)
        defer { oldSession.invalidateAndCancel() }
        var oldRequest = URLRequest(url: URL(string: "http://audit.invalid/old.jpg")!)
        oldRequest.httpMethod = "PUT"
        oldRequest.setValue("old", forHTTPHeaderField: "X-Audit-Generation")
        var oldTask: URLSessionUploadTask?
        let oldResponse: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
            let task = oldSession.uploadTask(with: oldRequest, fromFile: file) { _, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = response as? HTTPURLResponse {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.taskDescription = "job-1"
            oldTask = task
            task.resume()
        }
        XCTAssertEqual(oldResponse.statusCode, 200)

        let uploader = BackgroundUploader()
        var newRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/new.jpg")!)
        newRequest.httpMethod = "PUT"
        newRequest.setValue("new", forHTTPHeaderField: "X-Audit-Generation")
        let newResult = Task.detached {
            try await uploader.uploadResult(
                fileURL: file,
                request: newRequest,
                allowsCellular: true,
                progress: { _ in }
            )
        }
        let didNewUploadStart = await Task.detached { newStarted.wait(timeout: .now() + 5) }.value
        guard didNewUploadStart == .success else {
            releaseNew.signal()
            newResult.cancel()
            uploader.cancelAll()
            _ = await newResult.result
            XCTFail("The new upload never reached the loopback stub")
            return
        }

        // A recreated background task from the prior process still has the old
        // process-local description. It must not consume the new continuation.
        uploader.urlSession(oldSession, task: try XCTUnwrap(oldTask), didCompleteWithError: nil)
        releaseNew.signal()

        do {
            let result = try await newResult.value
            XCTFail("The old task completed the new upload with status \(result.status)")
        } catch let error as BackgroundUploader.HTTPStatusError {
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        uploader.cancelAll()
    }

    // MARK: - Fixtures

    private func makeServer() -> ServerConfig {
        ServerConfig(
            name: "Audit",
            provider: .custom,
            endpoint: "http://audit.invalid",
            region: "us-east-1",
            bucket: Self.auditBucket,
            accessKeyID: "audit-key",
            prefix: "Backu",
            pathStyle: true
        )
    }

    private func makeClient(server: ServerConfig) -> S3Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditJournalBackgroundURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return S3Client(
            connection: server.connection,
            credentials: S3Credentials(accessKeyID: "audit-key", secretAccessKey: "audit-secret"),
            session: session,
            headCache: nil
        )
    }

    private func makePhoto(id: String, filename: String = "IMG_0001.jpg", sha256: String? = nil) -> PhotoItem {
        PhotoItem(
            id: id,
            localIdentifier: String(id.dropFirst("asset:".count)),
            filename: filename,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 1,
            pixelHeight: 1,
            sha256: sha256
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    nonisolated private static func objectKey(for request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        let prefix = "/audit-bucket/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : String(path.dropFirst())
    }
}

private final class AuditJournalBackgroundURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (status: Int, data: Data, headers: [String: String])

    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ newValue: Handler?) {
        lock.lock()
        handler = newValue
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: Handler?
        Self.lock.lock()
        handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: result.status,
                httpVersion: nil,
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                client?.urlProtocol(self, didLoad: result.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
