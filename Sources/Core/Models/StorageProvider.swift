import Foundation

/// A bucket provider Backu knows how to pre-fill.
///
/// S3 itself has no end-user sign-in: buckets are unlocked with an access key
/// pair. The provider presets exist to remove every avoidable step, deep-link to
/// the exact page where a key is created, and pre-fill endpoint and region.
enum StorageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case aws
    case backblaze
    case cloudflareR2
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aws: return "Amazon S3"
        case .backblaze: return "Backblaze B2"
        case .cloudflareR2: return "Cloudflare R2"
        case .custom: return "Custom S3"
        }
    }

    var shortName: String {
        switch self {
        case .aws: return "AWS"
        case .backblaze: return "B2"
        case .cloudflareR2: return "R2"
        case .custom: return "S3"
        }
    }

    var symbol: String {
        switch self {
        case .aws: return "shippingbox.fill"
        case .backblaze: return "flame.fill"
        case .cloudflareR2: return "cloud.fill"
        case .custom: return "server.rack"
        }
    }

    var tint: UInt32 {
        switch self {
        case .aws: return 0xFF9900
        case .backblaze: return 0xE21E29
        case .cloudflareR2: return 0xF48120
        case .custom: return 0x5B6470
        }
    }

    var defaultRegion: String {
        switch self {
        case .aws: return "us-east-1"
        case .cloudflareR2: return "auto"
        case .backblaze, .custom: return ""
        }
    }

    /// Whether the endpoint is derived automatically once the account is known.
    var requiresEndpoint: Bool {
        switch self {
        case .aws: return false
        case .backblaze, .cloudflareR2, .custom: return true
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .aws: return "s3.us-east-1.amazonaws.com"
        case .backblaze: return "s3.us-west-004.backblazeb2.com"
        case .cloudflareR2: return "abc123.r2.cloudflarestorage.com"
        case .custom: return "s3.your-domain.com"
        }
    }

    var defaultPathStyle: Bool {
        switch self {
        case .aws, .backblaze: return false
        case .cloudflareR2, .custom: return true
        }
    }

    /// The page a person opens to mint an access key.
    var consoleURL: URL? {
        switch self {
        case .aws:
            return URL(string: "https://console.aws.amazon.com/iam/home#/users")
        case .backblaze:
            return URL(string: "https://secure.backblaze.com/app_keys.htm")
        case .cloudflareR2:
            return URL(string: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens")
        case .custom:
            return nil
        }
    }

    var setupSteps: [String] {
        switch self {
        case .aws:
            return [
                "Create a bucket in the region you want to use.",
                "Create an IAM user with `s3:PutObject`, `s3:GetObject` and `s3:ListBucket`.",
                "Create an access key for that user and paste it below."
            ]
        case .backblaze:
            return [
                "Create a private bucket and note its region, e.g. `us-west-004`.",
                "Add an application key scoped to that bucket.",
                "Paste the keyID and applicationKey below."
            ]
        case .cloudflareR2:
            return [
                "Create an R2 bucket and copy your Account ID.",
                "Create an R2 API token with Object Read & Write.",
                "Paste the Access Key ID and Secret Access Key below."
            ]
        case .custom:
            return [
                "Paste the endpoint of any S3-compatible service.",
                "Use path-style addressing for MinIO and most appliances.",
                "Enter the bucket and an access key pair."
            ]
        }
    }
}
