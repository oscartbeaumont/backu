import Network
import XCTest

/// Focused UI regressions for issues #28 and #30.
final class BackupIssueUIRegressionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(bootstrap: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKU_RESET"] = "1"
        app.launchEnvironment["BACKU_BOOTSTRAP"] = bootstrap
        app.launch()
        return app
    }

    func testIssue30CompletedOnboardingWithoutServerDoesNotReopenOnboarding() {
        let app = launch(bootstrap: """
        {"settings":{"hasCompletedOnboarding":true,"faceRecognitionEnabled":false,"autoBackupEnabled":false}}
        """)

        let onboarding = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Allow Photo Access", "Add Storage"])
        ).firstMatch
        XCTAssertFalse(onboarding.waitForExistence(timeout: 5), "Completed onboarding was shown again")
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
    }

    func testIssue28SaveRejectsCredentialsThatCannotReadBackTheProbe() throws {
        let fixture = BackupIssueS3Fixture()
        let endpoint = try fixture.start()
        defer { fixture.stop() }

        let app = launch(bootstrap: "{}")
        let photoExplanation = app.buttons["Allow Photo Access"]
        if photoExplanation.waitForExistence(timeout: 5) { app.buttons["Not Now"].tap() }
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Storage'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add Storage never appeared")
        add.tap()

        let custom = app.buttons.containing(.staticText, identifier: "Custom S3").firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 10), "Custom S3 provider missing")
        custom.tap()

        let bucket = app.textFields["my-photos"]
        let endpointField = app.textFields["s3.your-domain.com"]
        let key = app.textFields["Access key ID"]
        let secret = app.secureTextFields["Secret access key"]
        XCTAssertTrue(bucket.waitForExistence(timeout: 10), "Bucket field missing")
        bucket.tap()
        bucket.typeText("backu-test")
        endpointField.tap()
        endpointField.typeText(endpoint)
        key.tap()
        key.typeText("testkey")
        secret.tap()
        secret.typeText("testsecret")

        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        XCTAssertTrue(save.isEnabled, "Save should be enabled for a complete form")
        save.tap()

        let library = app.staticTexts["Library"]
        let rejection = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Access denied'")).firstMatch
        let outcome = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in library.exists || rejection.exists },
            object: app
        )
        wait(for: [outcome], timeout: 25)

        XCTAssertFalse(library.exists, "Save completed onboarding despite the failed read-back check")
        XCTAssertTrue(rejection.exists, "The failed read permission was not reported")
        XCTAssertTrue(save.exists, "The form should remain available after rejected credentials")
    }
}

/// Loopback-only S3 fixture for the write-only credential regression.
private final class BackupIssueS3Fixture {
    private struct Request {
        var method: String
        var target: String
        var body: Data
    }

    private enum FixtureError: Error {
        case timeout
        case missingPort
    }

    private let queue = DispatchQueue(label: "backu.issue.s3")
    private let ready = DispatchSemaphore(value: 0)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var objects: [String: Data] = [:]

    func start() throws -> String {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
        if case .failed(let error) = listener.state { throw error }
        guard let port = listener.port else { throw FixtureError.missingPort }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.connections.append(connection)
            connection.start(queue: self?.queue ?? .main)
            self?.receive(connection, buffer: Data())
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard error == nil else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = Self.completeRequest(in: next) {
                self?.respond(to: request, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self?.receive(connection, buffer: next)
            }
        }
    }

    private func respond(to request: Request, connection: NWConnection) {
        let components = URLComponents(string: request.target)
        let path = components?.path ?? request.target
        let key = path.hasPrefix("/backu-test/") ? String(path.dropFirst("/backu-test/".count)) : ""
        let query = components?.queryItems ?? []
        var status = 404
        var body = Data("<Error><Code>NoSuchKey</Code></Error>".utf8)
        var contentType = "application/xml"

        if request.method == "PUT" {
            objects[key] = request.body
            status = 200
            body = Data()
        } else if request.method == "DELETE" {
            objects[key] = nil
            status = 204
            body = Data()
        } else if request.method == "GET", query.contains(where: { $0.name == "list-type" }) {
            let prefix = query.first(where: { $0.name == "prefix" })?.value ?? ""
            let entries = objects.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
            body = Data(listXML(entries: entries).utf8)
            status = 200
        } else if request.method == "GET", key == "Backu/.backu/connection-probe" {
            body = Data("<Error><Code>AccessDenied</Code><Message>GetObject denied</Message></Error>".utf8)
            status = 403
        } else if request.method == "GET" || request.method == "HEAD", let stored = objects[key] {
            body = request.method == "HEAD" ? Data() : stored
            status = 200
            contentType = "application/octet-stream"
        }

        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        if request.method != "HEAD" { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in })
    }

    private static func completeRequest(in data: Data) -> Request? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<separator.lowerBound]
        let header = String(decoding: headerData, as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else { return nil }
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return Request(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func listXML(entries: [(key: String, value: Data)]) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let contents = entries.map { entry in
            "<Contents><Key>\(escaped(entry.key))</Key><LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>\"etag\"</ETag><Size>\(entry.value.count)</Size><StorageClass>STANDARD</StorageClass></Contents>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>backu-test</Name><Prefix></Prefix><KeyCount>\(entries.count)</KeyCount><MaxKeys>5</MaxKeys><IsTruncated>false</IsTruncated>\(contents)</ListBucketResult>"
    }
}
