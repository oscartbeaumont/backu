import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3. Small, dependency-free and testable against
/// the published AWS examples.
struct SigV4Signer: Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var region: String
    var service: String = "s3"

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    func sign(_ request: inout URLRequest, payloadHash: String, now: Date = Date()) {
        guard let url = request.url, let host = Self.hostHeader(for: url) else { return }

        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }

        var headers: [String: String] = [
            "host": host,
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash
        ]
        if let sessionToken, !sessionToken.isEmpty {
            headers["x-amz-security-token"] = sessionToken
        }
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            headers["content-type"] = Self.trimHeaderValue(contentType)
        }
        if let cacheControl = request.value(forHTTPHeaderField: "Cache-Control") {
            headers["cache-control"] = Self.trimHeaderValue(cacheControl)
        }
        if let range = request.value(forHTTPHeaderField: "Range") {
            headers["range"] = Self.trimHeaderValue(range)
        }

        let canonicalHeaders = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(Self.trimHeaderValue($0.value))\n" }
            .joined()
        let signedHeaders = headers.keys.sorted().joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalURI(for: url),
            Self.canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signatureKey = Self.signingKey(
            secretAccessKey: secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = Self.hex(Self.hmac(key: signatureKey, data: Data(stringToSign.utf8)))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Primitives

    static func signature(stringToSign: String, secretAccessKey: String, dateStamp: String, region: String, service: String) -> String {
        let key = signingKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        return hex(hmac(key: key, data: Data(stringToSign.utf8)))
    }

    static func signingKey(secretAccessKey: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hostHeader(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        guard let port = url.port else { return host }
        if (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80) {
            return host
        }
        return "\(host):\(port)"
    }

    /// RFC 3986 encoding. S3 requires `/` to stay unencoded in the path but
    /// encoded inside a key's individual segments.
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !encodeSlash {
            allowed.insert(charactersIn: "/")
        }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func canonicalURI(for url: URL) -> String {
        // percentEncodedPath preserves a trailing slash and is already encoded,
        // which is exactly what the canonical request needs.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return ""
        }
        var pairs: [(String, String)] = []
        pairs.reserveCapacity(items.count)
        for item in items {
            let name = uriEncode(item.name, encodeSlash: true)
            let value = uriEncode(item.value ?? "", encodeSlash: true)
            pairs.append((name, value))
        }
        pairs.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        var encoded: [String] = []
        encoded.reserveCapacity(pairs.count)
        for pair in pairs {
            encoded.append(pair.0 + "=" + pair.1)
        }
        return encoded.joined(separator: "&")
    }

    static func trimHeaderValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: - Payload hashing

    static let emptyPayloadHash = sha256Hex(Data())

    /// Streaming SHA-256 so multi-gigabyte videos never have to be loaded into memory.
    static func sha256Hex(contentsOfFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(Data(hasher.finalize()))
    }
}
