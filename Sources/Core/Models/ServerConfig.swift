import Foundation

/// A storage destination. Secrets live in the keychain, never in this value.
struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var provider: StorageProvider
    var endpoint: String
    var region: String
    var bucket: String
    var accessKeyID: String
    /// Folder inside the bucket that Backu owns. Empty means the bucket root.
    var prefix: String
    var pathStyle: Bool
    var createdAt: Date
    var lastVerifiedAt: Date?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        provider: StorageProvider,
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String,
        accessKeyID: String,
        prefix: String = "Backu",
        pathStyle: Bool = false,
        createdAt: Date = Date(),
        lastVerifiedAt: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.prefix = prefix
        self.pathStyle = pathStyle
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
        self.isEnabled = isEnabled
    }

    var resolvedEndpoint: URL? {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            if let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") {
                return url
            }
            return nil
        }
        if provider == .aws {
            let region = region.isEmpty ? "us-east-1" : region
            return URL(string: "https://s3.\(region).amazonaws.com")
        }
        if provider == .backblaze, !region.isEmpty {
            return URL(string: "https://s3.\(region).backblazeb2.com")
        }
        return nil
    }

    var normalizedPrefix: String {
        prefix
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
    }

    var displayHost: String {
        resolvedEndpoint?.host ?? endpoint
    }

    var subtitle: String {
        var parts = [bucket]
        if let host = resolvedEndpoint?.host, !host.isEmpty {
            parts.append(host)
        }
        return parts.joined(separator: " · ")
    }

    var folderDescription: String {
        let prefix = normalizedPrefix
        return prefix.isEmpty ? "Bucket root" : prefix
    }

    var connection: S3Connection {
        S3Connection(
            endpoint: resolvedEndpoint,
            region: region.isEmpty ? "us-east-1" : region,
            bucket: bucket,
            pathStyle: pathStyle
        )
    }
}

struct S3Connection: Hashable, Sendable {
    var endpoint: URL?
    var region: String
    var bucket: String
    var pathStyle: Bool

    var isValid: Bool {
        guard let endpoint else { return false }
        return !bucket.isEmpty && endpoint.host != nil
    }
}

struct S3Credentials: Codable, Hashable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
}
