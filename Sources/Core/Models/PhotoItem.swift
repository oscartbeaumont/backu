import Foundation

struct PhotoMetadata: Codable, Hashable, Sendable {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var fNumber: Double?
    var exposureTime: Double?
    var focalLength: Double?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var placeName: String?
    var orientation: Int?
    var uti: String?
    var fileExtension: String?
    var fileSize: Int64?
    var software: String?

    init() {}

    var cameraDescription: String? {
        guard let model = cameraModel, !model.isEmpty else { return cameraMake }
        if let make = cameraMake, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
            return "\(make) \(model)"
        }
        return model
    }

    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    var exposureDescription: String? {
        var parts: [String] = []
        if let fNumber { parts.append("ƒ/\(format(fNumber))") }
        if let exposureTime { parts.append(formatShutter(exposureTime)) }
        if let iso { parts.append("ISO \(iso)") }
        if let focalLength { parts.append("\(Int(focalLength.rounded())) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private func formatShutter(_ value: Double) -> String {
        if value >= 1 { return String(format: "%.0fs", value) }
        return "1/\(Int((1 / value).rounded()))s"
    }
}

struct PhotoCopy: Codable, Hashable, Sendable {
    var serverID: UUID
    var objectKey: String
    var sidecarKey: String
    var thumbnailKey: String?
    var uploadedAt: Date
    var byteCount: Int64
    var etag: String?
    /// Content hash of the original bytes, when known. Used for deduplication.
    var sha256: String?
}

/// One asset in the local catalog. It can be backed by the photo library, by a
/// remote server, or both.
struct PhotoItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var localIdentifier: String?
    var filename: String
    var takenAt: Date?
    var addedAt: Date?
    var modifiedAt: Date?
    var isVideo: Bool
    var isFavorite: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double?
    var tags: [String]
    var metadata: PhotoMetadata
    var faces: [PhotoFace]
    var copies: [PhotoCopy]
    var sha256: String?
    var analyzedAt: Date?
    var remoteThumbnailKey: String?
    var serverID: UUID?
    /// Set whenever tags, people or metadata change and the sidecar in S3 needs
    /// to be rewritten by the next backup pass.
    var sidecarDirtyAt: Date?

    init(
        id: String,
        localIdentifier: String? = nil,
        filename: String,
        takenAt: Date? = nil,
        addedAt: Date? = nil,
        modifiedAt: Date? = nil,
        isVideo: Bool = false,
        isFavorite: Bool = false,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: Double? = nil,
        tags: [String] = [],
        metadata: PhotoMetadata = PhotoMetadata(),
        faces: [PhotoFace] = [],
        copies: [PhotoCopy] = [],
        sha256: String? = nil,
        analyzedAt: Date? = nil,
        remoteThumbnailKey: String? = nil,
        serverID: UUID? = nil,
        sidecarDirtyAt: Date? = nil
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.takenAt = takenAt
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.tags = tags
        self.metadata = metadata
        self.faces = faces
        self.copies = copies
        self.sha256 = sha256
        self.analyzedAt = analyzedAt
        self.remoteThumbnailKey = remoteThumbnailKey
        self.serverID = serverID
        self.sidecarDirtyAt = sidecarDirtyAt
    }

    var isLocal: Bool { localIdentifier != nil }

    var isBackedUp: Bool { !copies.isEmpty }

    var isRemoteOnly: Bool { localIdentifier == nil }

    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var captureYear: Int? {
        guard let takenAt else { return nil }
        return Calendar.current.component(.year, from: takenAt)
    }

    var displayTitle: String {
        if !filename.isEmpty { return filename }
        return takenAt.map { PhotoItem.filenameDateFormatter.string(from: $0) } ?? id
    }

    var tagSummary: String? {
        tags.isEmpty ? nil : tags.joined(separator: ", ")
    }

    static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    func copy(on serverID: UUID) -> PhotoCopy? {
        copies.first { $0.serverID == serverID }
    }

    func hashableSearchText(people: [UUID: Person]) -> String {
        var parts: [String] = [filename]
        if let place = metadata.placeName { parts.append(place) }
        if let camera = metadata.cameraDescription { parts.append(camera) }
        if let lens = metadata.lensModel { parts.append(lens) }
        parts.append(contentsOf: tags)
        for face in faces {
            if let personID = face.personID, let person = people[personID] {
                parts.append(person.displayName)
            }
        }
        return parts.joined(separator: " ").lowercased()
    }
}
