import Network
import XCTest

final class AuditSecondaryUIRegressionTests: XCTestCase {
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

    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
        if app.buttons["tabs.show"].exists { app.buttons["tabs.show"].tap() }
        app.buttons["tab.settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10), "Settings never appeared")
    }

    private func openSearch(_ app: XCUIApplication) {
        app.buttons["search.open"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10), "Search never opened")
    }

    func testSearchHonorsHiddenRemoteOnlyPhotosSetting() throws {
        let fixture = AuditS3Fixture(mode: .remoteIndex)
        let endpoint = try fixture.start()
        defer { fixture.stop() }

        let app = launch(bootstrap: """
        {"servers":[{"name":"Audit Remote","provider":"custom","endpoint":"\(endpoint)","region":"us-east-1","bucket":"backu-test","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":false,"faceRecognitionEnabled":false,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":false}}
        """)
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20), "Library never appeared")
        XCTAssertTrue(fixture.waitForMetadataWrite(timeout: 25), "Remote library was never imported and published")

        openSearch(app)
        let field = app.textFields["search.field"]
        field.tap()
        field.typeText("auditremote")
        let count = app.staticTexts["search.resultCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "Search result count missing")
        XCTAssertEqual(count.label, "0 results", "Search exposed a remote-only photo while the setting was off")
    }

    func testSettingsTogglesExposeTheirTitlesToAccessibility() {
        let app = launch(bootstrap: """
        {"servers":[{"name":"Audit","provider":"custom","endpoint":"http://127.0.0.1:9","region":"us-east-1","bucket":"backu-test","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
         "settings":{"autoBackupEnabled":false,"backupOnCellular":false,"faceRecognitionEnabled":false,"gridColumns":3,"hasCompletedOnboarding":true,"showRemoteOnlyPhotos":false}}
        """)
        openSettings(app)

        let automaticBackup = app.switches.matching(
            NSPredicate(format: "label CONTAINS[c] 'Automatic backup'")
        ).firstMatch
        XCTAssertTrue(
            automaticBackup.waitForExistence(timeout: 5),
            "The Automatic backup switch has no accessible title"
        )
    }
}

/// A tiny loopback-only S3 fixture. It never contacts a live service and keeps
/// all objects in memory, so metadata sync can finish during the UI tests.
private final class AuditS3Fixture {
    enum Mode {
        case writeOnly
        case remoteIndex
    }

    private struct Request {
        var method: String
        var target: String
        var body: Data
    }

    private enum FixtureError: Error {
        case timeout
        case missingPort
    }

    private let mode: Mode
    private let queue = DispatchQueue(label: "backu.audit.s3")
    private let ready = DispatchSemaphore(value: 0)
    private let metadataWrite = DispatchSemaphore(value: 0)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var objects: [String: Data] = [:]

    init(mode: Mode) {
        self.mode = mode
    }

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

    func waitForMetadataWrite(timeout: TimeInterval) -> Bool {
        metadataWrite.wait(timeout: .now() + timeout) == .success
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
            if key.contains(".backu/meta/") { metadataWrite.signal() }
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
        } else if request.method == "GET", mode == .remoteIndex, key == "Backu/.backu/index.json" {
            body = Data(remoteIndexJSON.utf8)
            contentType = "application/json"
            status = 200
        } else if request.method == "GET", mode == .writeOnly, key == "Backu/.backu/connection-probe" {
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
        // Keep the socket alive after writing the framed response. Cancelling
        // here can reset the TCP connection before URLSession consumes it.
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

    private var remoteIndexJSON: String {
        """
        {"schema":"backu.index.v1","updatedAt":"2025-06-12T12:00:00Z","device":"audit","people":[],
         "photos":[{"id":"audit-remote-only","key":"Backu/Photos/2025/06/AUDIT_REMOTE_ONLY.jpg","sidecarKey":"Backu/Photos/2025/06/AUDIT_REMOTE_ONLY.jpg.json","sha256":"audit-remote-only-hash","filename":"AUDIT_REMOTE_ONLY.jpg","capturedAt":"2025-06-12T12:00:00Z","width":100,"height":100,"isVideo":false,"favorite":false,"tags":["auditremote"],"personIDs":[],"byteCount":1,"faces":[]}]}
        """
    }
}
