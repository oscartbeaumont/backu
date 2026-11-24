import Foundation

struct S3Object: Hashable, Sendable {
    var key: String
    var size: Int64
    var lastModified: Date?
    var etag: String?
}

struct S3ListPage: Sendable {
    var objects: [S3Object]
    var nextToken: String?
    var isTruncated: Bool
    /// `delimiter` rollups, used to discover writer prefixes in one request
    /// instead of listing the entire history.
    var commonPrefixes: [String] = []
}

struct S3ObjectHead: Sendable {
    var key: String
    var size: Int64
    var etag: String?
    var contentType: String?
    var acceptRanges: Bool?
}

enum S3Error: LocalizedError {
    case invalidEndpoint
    case http(status: Int, code: String?, message: String?, requestID: String?)
    case transport(Error)
    case decoding(String)
    case listTruncated(limit: Int)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "That endpoint is not a valid URL. Include the host, for example s3.us-west-004.backblazeb2.com."
        case let .http(status, code, message, _):
            let detail = message ?? code ?? HTTPURLResponse.localizedString(forStatusCode: status)
            switch code {
            case "NoSuchBucket":
                return "That bucket does not exist. Check the bucket name and region."
            case "AccessDenied", "Forbidden":
                return "Access denied. This key needs ListBucket, GetObject and PutObject on the bucket."
            case "SignatureDoesNotMatch", "InvalidAccessKeyId":
                return "That access key was rejected. Check the key ID and secret, then try again."
            case "InvalidBucketName":
                return "That bucket name is not valid for this service."
            case "PermanentRedirect", "AuthorizationHeaderMalformed":
                return "Wrong region for this bucket. \(detail)"
            case "RequestTimeTooSkewed":
                return "The upload signature expired before it was sent. Check the clock and try again."
            default:
                return "\(detail) (HTTP \(status))"
            }
        case let .transport(error):
            return (error as NSError).localizedDescription
        case let .decoding(detail):
            return "The storage service returned an unexpected response. \(detail)"
        case let .listTruncated(limit):
            return "The storage service returned more than \(limit) objects. Backu stopped instead of importing a partial library."
        case .missingCredentials:
            return "No access key is stored for this server."
        }
    }
}

/// A minimal, dependency-free S3 client covering exactly what Backu needs.
struct S3Client: Sendable {
    let connection: S3Connection
    let credentials: S3Credentials
    let session: URLSession
    let metrics: S3Metrics?
    /// Short-lived HEAD cache so repeated viewer opens of the same object skip a
    /// round trip. Pass `nil` (or `.disabled()`) in tests that count requests.
    let headCache: S3HeadCache?

    init(
        connection: S3Connection,
        credentials: S3Credentials,
        session: URLSession? = nil,
        metrics: S3Metrics? = nil,
        headCache: S3HeadCache? = .shared
    ) {
        self.connection = connection
        self.credentials = credentials
        self.metrics = metrics
        self.headCache = headCache
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            // Match `TransferPlanner.connectionBudget`; the old value of 6
            // silently throttled every 8-connection transfer plan.
            config.httpMaximumConnectionsPerHost = TransferPlanner.connectionBudget
            config.waitsForConnectivity = true
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    var signer: SigV4Signer {
        SigV4Signer(
            accessKeyID: credentials.accessKeyID,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
            region: connection.region
        )
    }

    // MARK: - Operations

    func listObjects(
        prefix: String,
        continuationToken: String? = nil,
        maxKeys: Int = 1000,
        delimiter: String? = nil,
        startAfter: String? = nil
    ) async throws -> S3ListPage {
        var query = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: String(maxKeys))
        ]
        if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let continuationToken { query.append(URLQueryItem(name: "continuation-token", value: continuationToken)) }
        if let delimiter { query.append(URLQueryItem(name: "delimiter", value: delimiter)) }
        if let startAfter { query.append(URLQueryItem(name: "start-after", value: startAfter)) }

        var request = try makeRequest(method: "GET", key: nil, query: query)
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        do {
            return try ListObjectsParser.parse(data)
        } catch {
            throw S3Error.decoding(String(describing: error))
        }
    }

    /// Lists every object under a prefix, following continuation tokens.
    /// A supplied limit is a hard bound: truncation throws rather than returning
    /// a partial library that callers could mistake for a complete import.
    func listAllObjects(prefix: String, limit: Int? = nil) async throws -> [S3Object] {
        var results: [S3Object] = []
        var token: String?
        repeat {
            let page = try await listObjects(prefix: prefix, continuationToken: token)
            results.append(contentsOf: page.objects)
            if let limit, results.count > limit {
                throw S3Error.listTruncated(limit: limit)
            }
            if page.isTruncated {
                guard let nextToken = page.nextToken, !nextToken.isEmpty else {
                    throw S3Error.decoding("List response was truncated without a continuation token.")
                }
                token = nextToken
                if let limit, results.count >= limit {
                    throw S3Error.listTruncated(limit: limit)
                }
            } else {
                token = nil
            }
        } while token != nil
        return results
    }

    func putObject(key: String, data: Data, contentType: String = "application/octet-stream") async throws {
        var request = try makeRequest(method: "PUT", key: key, query: [])
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let hash = SigV4Signer.sha256Hex(data)
        sign(&request, payloadHash: hash)
        let (body, response) = try await upload(request, data: data)
        try validate(response, data: body)
        invalidateCachedHead(key: key)
    }

    func putFile(key: String, fileURL: URL, contentType: String) async throws -> String {
        let (request, hash) = try signedPutFileRequest(key: key, fileURL: fileURL, contentType: contentType)
        let (body, response) = try await upload(request, fileURL: fileURL)
        try validate(response, data: body)
        invalidateCachedHead(key: key)
        return hash
    }

    /// Builds the same signed request `putFile` sends, for callers that upload
    /// through a background URLSession.
    func signedPutFileRequest(key: String, fileURL: URL, contentType: String) throws -> (URLRequest, String) {
        var request = try makeRequest(method: "PUT", key: key, query: [])
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let hash = try SigV4Signer.sha256Hex(contentsOfFile: fileURL)
        sign(&request, payloadHash: hash)
        return (request, hash)
    }

    /// Hashes off the caller's actor so a multi-gigabyte video never stalls the
    /// main thread before the upload starts.
    func signedPutFileRequestAsync(key: String, fileURL: URL, contentType: String) async throws -> (URLRequest, String) {
        let hash = try await Task.detached(priority: .utility) {
            try SigV4Signer.sha256Hex(contentsOfFile: fileURL)
        }.value
        var request = try makeRequest(method: "PUT", key: key, query: [])
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        sign(&request, payloadHash: hash)
        return (request, hash)
    }

    func getObject(key: String) async throws -> Data {
        var request = try makeRequest(method: "GET", key: key, query: [])
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return data
    }

    /// Conditional GET for the metadata head. A 304 returns `(nil, etag)`
    /// instead of throwing, so a steady-state sync costs one round trip and no
    /// body.
    func getObjectIfChanged(key: String, etag: String?) async throws -> (data: Data?, etag: String?) {
        var request = try makeRequest(method: "GET", key: key, query: [])
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        if response.statusCode == 304 { return (nil, etag) }
        if response.statusCode == 404 { return (nil, nil) }
        try validate(response, data: data)
        return (data, response.value(forHTTPHeaderField: "ETag"))
    }

    /// Returns nil for a missing object instead of throwing 404.
    func headObject(key: String) async throws -> S3ObjectHead? {
        var request = try makeRequest(method: "HEAD", key: key, query: [])
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        if response.statusCode == 404 { return nil }
        try validate(response, data: data)
        return S3ObjectHead(
            key: key,
            size: response.expectedContentLength > 0 ? response.expectedContentLength : 0,
            etag: response.value(forHTTPHeaderField: "ETag"),
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            acceptRanges: (response.value(forHTTPHeaderField: "Accept-Ranges")).map {
                $0.lowercased().contains("bytes")
            }
        )
    }

    func deleteObject(key: String) async throws {
        var request = try makeRequest(method: "DELETE", key: key, query: [])
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        invalidateCachedHead(key: key)
    }

    // MARK: - Verification

    struct Verification: Sendable {
        var canList: Bool
        var canRead: Bool
        var canWrite: Bool
        var objectCount: Int
        var latency: TimeInterval
        var message: String?
    }

    /// Checks the exact permissions Backu needs: listing the folder, writing an
    /// object and reading it back.
    func verify(prefix: String) async throws -> Verification {
        let start = Date()
        var canList = false
        var canRead = false
        var canWrite = false
        var objectCount = 0
        var note: String?

        do {
            let page = try await listObjects(prefix: prefix, maxKeys: 5)
            canList = true
            objectCount = page.objects.count
        } catch {
            note = (error as? S3Error)?.errorDescription ?? error.localizedDescription
        }

        let probeKey = Self.join(prefix, ".backu/connection-probe")
        let probeBody = Data("backu-\(UUID().uuidString)".utf8)
        do {
            try await putObject(key: probeKey, data: probeBody, contentType: "text/plain")
            canWrite = true
            let body = try await getObject(key: probeKey)
            canRead = body == probeBody
            try? await deleteObject(key: probeKey)
        } catch {
            note = note ?? (error as? S3Error)?.errorDescription
        }

        return Verification(
            canList: canList,
            canRead: canRead,
            canWrite: canWrite,
            objectCount: objectCount,
            latency: Date().timeIntervalSince(start),
            message: note
        )
    }

    // MARK: - Request plumbing

    static func join(_ prefix: String, _ key: String) -> String {
        let cleaned = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleaned.isEmpty { return key }
        return "\(cleaned)/\(key)"
    }

    func makeRequest(method: String, key: String?, query: [URLQueryItem]) throws -> URLRequest {
        guard let endpoint = connection.endpoint, let endpointHost = endpoint.host else {
            throw S3Error.invalidEndpoint
        }

        let bucket = connection.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { throw S3Error.invalidEndpoint }

        var host = endpointHost
        let basePath = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = basePath.isEmpty ? "" : "/" + basePath
        if connection.pathStyle {
            path += "/\(bucket)"
        } else {
            host = "\(bucket).\(endpointHost)"
        }
        if let key {
            path += "/" + key
        }
        if path.isEmpty { path = "/" }

        var components = URLComponents()
        components.scheme = endpoint.scheme ?? "https"
        components.host = host
        components.port = endpoint.port
        components.percentEncodedPath = SigV4Signer.uriEncode(path, encodeSlash: false)

        if !query.isEmpty {
            let encoded = query
                .map { "\(SigV4Signer.uriEncode($0.name, encodeSlash: true))=\(SigV4Signer.uriEncode($0.value ?? "", encodeSlash: true))" }
                .joined(separator: "&")
            components.percentEncodedQuery = encoded
        }

        guard let url = components.url else { throw S3Error.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Backu/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    func sign(_ request: inout URLRequest, payloadHash: String) {
        signer.sign(&request, payloadHash: payloadHash)
    }

    func perform(
        _ request: URLRequest,
        retryTransportErrors: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        try await sendWithRetry(retryTransportErrors: retryTransportErrors) {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw S3Error.decoding("No HTTP response")
            }
            return (data, http)
        }
    }

    func upload(
        _ request: URLRequest,
        data: Data,
        policy: S3RetryPolicy = .default
    ) async throws -> (Data, HTTPURLResponse) {
        try await sendWithRetry(policy: policy) {
            let (body, response) = try await self.session.upload(for: request, from: data)
            guard let http = response as? HTTPURLResponse else {
                throw S3Error.decoding("No HTTP response")
            }
            return (body, http)
        }
    }

    func upload(
        _ request: URLRequest,
        fileURL: URL,
        policy: S3RetryPolicy = .default
    ) async throws -> (Data, HTTPURLResponse) {
        try await sendWithRetry(policy: policy) {
            let (body, response) = try await self.session.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else {
                throw S3Error.decoding("No HTTP response")
            }
            return (body, http)
        }
    }

    /// Runs one HTTP exchange with retries for transient statuses and transport
    /// errors. Returns the final response, including a non-2xx one, so callers
    /// validate it with the body and can surface a useful error.
    ///
    /// `retryTransportErrors` is false for non-idempotent requests such as
    /// `CreateMultipartUpload`: if the response is lost, a retry would create a
    /// second upload and orphan the first. A non-2xx status is still safe to
    /// retry because the request provably failed.
    private func sendWithRetry(
        retryTransportErrors: Bool = true,
        policy: S3RetryPolicy = .default,
        _ operation: () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            metrics?.recordRequest()
            do {
                let (data, response) = try await operation()
                if S3RetryPolicy.isRetryable(status: response.statusCode),
                   attempt + 1 < policy.maxAttempts {
                    attempt += 1
                    metrics?.recordRetryableResponse()
                    metrics?.recordRetry()
                    try await policy.sleepBeforeRetry(
                        attempt: attempt,
                        retryAfter: S3RetryHeaders.retryAfter(response)
                    )
                    continue
                }
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                metrics?.recordTransportFailure()
                guard retryTransportErrors,
                      attempt + 1 < policy.maxAttempts,
                      S3RetryPolicy.isRetryable(error: error) else {
                    throw error is S3Error ? error : S3Error.transport(error)
                }
                attempt += 1
                metrics?.recordRetry()
                try await policy.sleepBeforeRetry(attempt: attempt, retryAfter: nil)
            }
        }
    }

    func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let parsed = S3ErrorParser.parse(data)
            throw S3Error.http(
                status: response.statusCode,
                code: parsed.code,
                message: parsed.message,
                requestID: parsed.requestID ?? response.value(forHTTPHeaderField: "x-amz-request-id")
            )
        }
    }
}

// MARK: - XML

private final class ListObjectsParser: NSObject, XMLParserDelegate {
    private var objects: [S3Object] = []
    private var nextToken: String?
    private var isTruncated = false
    private var current: [String: String] = [:]
    private var depth = 0
    private var contentsDepth: Int?
    private var commonPrefixDepth: Int?
    private var commonPrefixes: [String] = []
    private var text = ""
    private var parseError: Error?

    static func parse(_ data: Data) throws -> S3ListPage {
        let parser = ListObjectsParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            throw parser.parseError ?? NSError(domain: "S3XML", code: 1)
        }
        return S3ListPage(
            objects: parser.objects,
            nextToken: parser.nextToken,
            isTruncated: parser.isTruncated,
            commonPrefixes: parser.commonPrefixes
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        text = ""
        if elementName == "Contents" {
            contentsDepth = depth
            current = [:]
        }
        if elementName == "CommonPrefixes" {
            commonPrefixDepth = depth
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commonPrefixDepth, depth == commonPrefixDepth + 1, elementName == "Prefix" {
            commonPrefixes.append(value)
        }
        if let contentsDepth, depth == contentsDepth + 1 {
            current[elementName] = value
        } else if contentsDepth == nil {
            switch elementName {
            case "NextContinuationToken": nextToken = value
            case "IsTruncated": isTruncated = value.lowercased() == "true"
            default: break
            }
        }
        if elementName == "CommonPrefixes", depth == commonPrefixDepth {
            commonPrefixDepth = nil
        }
        if elementName == "Contents", depth == contentsDepth {
            contentsDepth = nil
            if let key = current["Key"], !key.isEmpty {
                objects.append(
                    S3Object(
                        key: key,
                        size: Int64(current["Size"] ?? "0") ?? 0,
                        lastModified: S3Date.parse(current["LastModified"]),
                        etag: current["ETag"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    )
                )
            }
            current = [:]
        }
        depth -= 1
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private final class S3ErrorParser: NSObject, XMLParserDelegate {
    private(set) var code: String?
    private(set) var message: String?
    private(set) var requestID: String?
    private var text = ""
    private var depth = 0

    static func parse(_ data: Data) -> (code: String?, message: String?, requestID: String?) {
        guard !data.isEmpty else { return (nil, nil, nil) }
        let parser = S3ErrorParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return (parser.code, parser.message, parser.requestID)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Code": if depth == 2 { code = value }
        case "Message": if depth == 2 { message = value }
        case "RequestId": if depth == 2 { requestID = value }
        default: break
        }
        depth -= 1
        text = ""
    }
}

enum S3Date {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }
}
