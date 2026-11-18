import CryptoKit
import Foundation

/// A rectangle in normalized (0...1) image space with a top-left origin, which
/// is what SwiftUI overlay geometry wants.
struct NormRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts a Vision rectangle (bottom-left origin) into top-left space.
    init(visionX: Double, visionY: Double, visionWidth: Double, visionHeight: Double) {
        self.x = visionX
        self.y = 1 - visionY - visionHeight
        self.width = visionWidth
        self.height = visionHeight
    }

    var center: (x: Double, y: Double) {
        (x + width / 2, y + height / 2)
    }

    func inset(by fraction: Double) -> NormRect {
        let dx = width * fraction
        let dy = height * fraction
        return NormRect(
            x: max(0, x - dx),
            y: max(0, y - dy),
            width: min(1, width + dx * 2),
            height: min(1, height + dy * 2)
        )
    }
}

/// Stable face identity shared by every device.
///
/// A random UUID per analysis made two devices analysing the same photo
/// produce different ids; each then published a delete for the other's faces.
/// Deriving the id from the photo and the quantised box makes the same face
/// the same object everywhere, while leaving `embeddingIndex` local.
enum FaceIdentity {
    static func canonical(photoID: String, kind: PhotoFace.Kind, rect: NormRect) -> UUID {
        var canonical = photoID
        if canonical.hasPrefix("remote:") {
            canonical.removeFirst("remote:".count)
        }
        // 1% quantisation absorbs the tiny box differences between two
        // analyses of the same bytes.
        let seed = String(
            format: "%@|%@|%.2f|%.2f|%.2f|%.2f",
            canonical,
            kind.rawValue,
            rect.x,
            rect.y,
            rect.width,
            rect.height
        )
        let digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct PhotoFace: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case person
        case pet
    }

    var id: UUID
    var personID: UUID?
    var kind: Kind
    var rect: NormRect
    var quality: Double
    /// Index into the on-device embedding store. Never leaves the device.
    var embeddingIndex: Int?

    init(
        id: UUID = UUID(),
        personID: UUID? = nil,
        kind: Kind = .person,
        rect: NormRect,
        quality: Double = 1,
        embeddingIndex: Int? = nil
    ) {
        self.id = id
        self.personID = personID
        self.kind = kind
        self.rect = rect
        self.quality = quality
        self.embeddingIndex = embeddingIndex
    }
}

struct Person: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String?
    var isPet: Bool
    var createdAt: Date
    var coverPhotoID: String?
    var coverFaceID: UUID?
    var faceCount: Int
    var lastSeenAt: Date?
    var isHidden: Bool

    init(
        id: UUID = UUID(),
        name: String? = nil,
        isPet: Bool = false,
        createdAt: Date = Date(),
        coverPhotoID: String? = nil,
        coverFaceID: UUID? = nil,
        faceCount: Int = 1,
        lastSeenAt: Date? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isPet = isPet
        self.createdAt = createdAt
        self.coverPhotoID = coverPhotoID
        self.coverFaceID = coverFaceID
        self.faceCount = faceCount
        self.lastSeenAt = lastSeenAt
        self.isHidden = isHidden
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return isPet ? "Unnamed pet" : "Unnamed person"
    }

    var isNamed: Bool {
        !(name ?? "").isEmpty
    }
}
