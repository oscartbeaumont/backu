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
