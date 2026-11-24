import Foundation

// MARK: - Clock

/// Hybrid logical clock: physical milliseconds with a logical counter and a
/// stable writer tie-break. Records only need to be *totally ordered*, not
/// wall-clock accurate; HLC keeps ordering close to real time while staying
/// monotonic on a device whose clock jumps backwards.
enum HybridClock {
    /// Milliseconds in the high 48 bits, counter in the low 16.
    static func pack(milliseconds: Int64, counter: UInt16) -> Int64 {
        (milliseconds << 16) | Int64(counter)
    }

    static func unpack(_ value: Int64) -> (milliseconds: Int64, counter: UInt16) {
        (value >> 16, UInt16(truncatingIfNeeded: value))
    }

    static func now(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Stable 32-bit fingerprint of a writer id. Versions compare by (HLC,
/// fingerprint) on every device without carrying a 36-character id per field.
enum WriterFingerprint {
    static func of(_ writer: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in writer.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// A field's last writer. Ordered by HLC, then a stable writer fingerprint, so
/// two devices that see the same records resolve equal timestamps the same way.
struct Version: Codable, Hashable, Comparable, Sendable {
    var hlc: Int64
    var writer: UInt32

    init(hlc: Int64, writer: UInt32) {
        self.hlc = hlc
        self.writer = writer
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        hlc = try container.decode(Int64.self)
        writer = try container.decode(UInt32.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(hlc)
        try container.encode(writer)
    }

    static let zero = Version(hlc: 0, writer: 0)

    static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.hlc == rhs.hlc ? lhs.writer < rhs.writer : lhs.hlc < rhs.hlc
    }

    var milliseconds: Int64 { HybridClock.unpack(hlc).milliseconds }
}

// MARK: - Shared entities

/// A copy of one object in *this* bucket. Server ids are device-local, so they
/// are deliberately absent: a reader attaches its own server id after import.
struct SharedCopy: Codable, Hashable, Sendable {
    var objectKey: String
    var sidecarKey: String
    var thumbnailKey: String?
    var atlasGroup: String?
    var atlasCell: Int?
    var byteCount: Int64
    var sha256: String?
    var uploadedAt: Date
    var etag: String?

    init(copy: PhotoCopy) {
        objectKey = copy.objectKey
        sidecarKey = copy.sidecarKey
        thumbnailKey = copy.thumbnailKey
        atlasGroup = copy.atlasGroup
        atlasCell = copy.atlasCell
        byteCount = copy.byteCount
        sha256 = copy.sha256
        uploadedAt = copy.uploadedAt
        etag = copy.etag
    }

    func photoCopy(serverID: UUID) -> PhotoCopy {
        PhotoCopy(
            serverID: serverID,
            objectKey: objectKey,
            sidecarKey: sidecarKey,
            thumbnailKey: thumbnailKey,
            uploadedAt: uploadedAt,
            byteCount: byteCount,
            etag: etag,
            sha256: sha256,
            atlasGroup: atlasGroup,
            atlasCell: atlasCell
        )
    }
}

/// The fields every device needs and that can be edited concurrently.
struct SharedPhoto: Codable, Hashable, Sendable {
    var id: String
    var filename: String
    var takenAt: Date?
    var addedAt: Date?
    var modifiedAt: Date?
    var isVideo: Bool
    var isFavorite: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double?
    var metadata: PhotoMetadata
    var sha256: String?
    var copies: [SharedCopy]

    /// Field names used in patch records. Anything not listed here is either
    /// immutable (id) or device-local (localIdentifier, analyzedAt).
    enum Field: String, CaseIterable {
        case filename, takenAt, addedAt, modifiedAt, isVideo, isFavorite
        case pixelWidth, pixelHeight, duration, metadata, copies, sha256
    }

    init(photo: PhotoItem, serverID: UUID) {
        // Remote-only catalog items carry a `remote:` prefix to keep them
        // distinct from a local asset id. The log uses one canonical id for a
        // photo, whichever device is writing, so the prefix never reaches it.
        var canonical = photo.id
        if canonical.hasPrefix("remote:") {
            canonical.removeFirst("remote:".count)
        }
        id = canonical
        filename = photo.filename
        takenAt = photo.takenAt
        addedAt = photo.addedAt
        modifiedAt = photo.modifiedAt
        isVideo = photo.isVideo
        isFavorite = photo.isFavorite
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
        duration = photo.duration
        metadata = photo.metadata
        sha256 = photo.sha256
        copies = photo.copies
            .filter { $0.serverID == serverID }
            .map(SharedCopy.init)
    }

    mutating func apply(_ field: Field, from other: SharedPhoto) {
        switch field {
        case .filename: filename = other.filename
        case .takenAt: takenAt = other.takenAt
        case .addedAt: addedAt = other.addedAt
        case .modifiedAt: modifiedAt = other.modifiedAt
        case .isVideo: isVideo = other.isVideo
        case .isFavorite: isFavorite = other.isFavorite
        case .pixelWidth: pixelWidth = other.pixelWidth
        case .pixelHeight: pixelHeight = other.pixelHeight
        case .duration: duration = other.duration
        case .metadata: metadata = other.metadata
        case .copies: copies = other.copies
        case .sha256: sha256 = other.sha256
        }
    }
}

/// Face boxes and assignments travel in the log; `embeddingIndex` is local.
struct SharedFace: Codable, Hashable, Sendable {
    var id: UUID
    var personID: UUID?
    var kind: PhotoFace.Kind
    var rect: NormRect
    var quality: Double

    init(face: PhotoFace) {
        id = face.id
        personID = face.personID
        kind = face.kind
        rect = face.rect
        quality = face.quality
    }

    func photoFace(embeddingIndex: Int?) -> PhotoFace {
        PhotoFace(
            id: id,
            personID: personID,
            kind: kind,
            rect: rect,
            quality: quality,
            embeddingIndex: embeddingIndex
        )
    }
}

struct SharedPerson: Codable, Hashable, Sendable {
    var id: UUID
    var name: String?
    var isPet: Bool
    var createdAt: Date
    var coverPhotoID: String?
    var coverFaceID: UUID?
    var isHidden: Bool

    enum Field: String, CaseIterable {
        case name, isPet, coverPhotoID, coverFaceID, isHidden
    }

    init(person: Person) {
        id = person.id
        name = person.name
        isPet = person.isPet
        createdAt = person.createdAt
        coverPhotoID = person.coverPhotoID
        coverFaceID = person.coverFaceID
        isHidden = person.isHidden
    }

    mutating func apply(_ field: Field, from other: SharedPerson) {
        switch field {
        case .name: name = other.name
        case .isPet: isPet = other.isPet
        case .coverPhotoID: coverPhotoID = other.coverPhotoID
        case .coverFaceID: coverFaceID = other.coverFaceID
        case .isHidden: isHidden = other.isHidden
        }
    }

    func person(faceCount: Int = 0) -> Person {
        Person(
            id: id,
            name: name,
            isPet: isPet,
            createdAt: createdAt,
            coverPhotoID: coverPhotoID,
            coverFaceID: coverFaceID,
            faceCount: faceCount,
            isHidden: isHidden
        )
    }
}

// MARK: - Records

enum MetaOperation: String, Codable, Sendable {
    case photoUpsert
    case photoPatch
    case photoDelete
    case personUpsert
    case personPatch
    case personDelete
    /// A SHA-256 the person deleted locally. Bucket bytes are kept as a
    /// backup, but other devices must not re-import them as new photos.
    case deletedHash
}

/// One immutable fact appended to a writer's log. `hlc` is packed; `by` is the
/// writer id used for tie-breaks.
struct MetaRecord: Codable, Sendable {
    var v: Int = 2
    var op: MetaOperation
    var id: String
    var hlc: Int64
    var by: String

    /// Present on upserts and patches: the entity's full current value, so the
    /// patch never needs a schema for "set to null".
    var photo: SharedPhoto? = nil
    var changed: [String]? = nil

    var tagsAdd: [String]? = nil
    var tagsRemove: [String]? = nil

    var facesSet: [SharedFace]? = nil
    var facesDelete: [UUID]? = nil

    var person: SharedPerson? = nil
    var sha256: String? = nil

    var versionKey: (Int64, String) { (hlc, by) }
}

// MARK: - Log identifiers

enum MetadataLayout {
    static let schema = "backu.meta.v2"
    static let root = ".backu/meta/v2"
    static let logPrefix = "\(root)/log"
    static let snapshotPrefix = "\(root)/snap"
    static let headKey = "\(root)/head.json"
    /// Kept only as a read-only migration source. Nothing writes it any more.
    static let legacyIndexKey = ".backu/index.json"

    static func writerPrefix(_ writer: String) -> String {
        "\(logPrefix)/\(writer)"
    }

    static func segmentKey(writer: String, sequence: Int, hlc: Int64, digest: String) -> String {
        String(format: "%@/%012d-%016llx-%@.jsonl.gz", writerPrefix(writer), sequence, UInt64(bitPattern: hlc), String(digest.prefix(16)))
    }

    /// Parses a segment key into its ordering components. Returns nil for
    /// anything that is not one of ours (a sidecar, a stray object).
    static func parseSegment(_ key: String) -> (writer: String, sequence: Int, hlc: Int64)? {
        let parts = key.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        let name = parts[parts.count - 1]
        let fields = name.split(separator: "-")
        guard fields.count >= 3,
              let sequence = Int(fields[0]),
              let raw = UInt64(fields[1], radix: 16)
        else { return nil }
        let writer = String(parts[parts.count - 2])
        return (writer, sequence, Int64(bitPattern: raw))
    }

    static func snapshotKey(generation: Int, hlc: Int64, digest: String) -> String {
        String(format: "%@/%012d-%016llx-%@.jsonl.gz", snapshotPrefix, generation, UInt64(bitPattern: hlc), String(digest.prefix(16)))
    }
}

/// The only mutable object in the log. Written by compaction, never by an edit.
struct MetadataHead: Codable, Sendable {
    var schema: String = MetadataLayout.schema
    var generation: Int
    var snapshot: String?
    var watermark: [String: Int]
    var updatedAt: Date
    var device: String

    var isEmpty: Bool { generation <= 0 && snapshot == nil && watermark.isEmpty }
}

// MARK: - Snapshot lines

struct SnapshotHeader: Codable, Sendable {
    var schema: String = MetadataLayout.schema
    var generation: Int
    var writers: [String]
    var watermark: [String: Int]
    var createdAt: Date
    var count: Int
}

struct SnapshotPhotoLine: Codable, Sendable {
    var kind = "photo"
    var photo: MergedPhoto
}

struct SnapshotPersonLine: Codable, Sendable {
    var kind = "person"
    var person: MergedPerson
}

struct SnapshotTombstoneLine: Codable, Sendable {
    var kind = "tombstone"
    var id: String
    var version: Version
}

struct SnapshotPersonTombstoneLine: Codable, Sendable {
    var kind = "personTombstone"
    var id: String
    var version: Version
}

struct SnapshotHashLine: Codable, Sendable {
    var kind = "hash"
    var sha256: String
    var version: Version
}

struct SnapshotHeaderLine: Codable, Sendable {
    var kind = "header"
    var header: SnapshotHeader
}

enum MetadataSegmentCodec {
    static func encode(_ records: [MetaRecord]) throws -> Data {
        var output = Data()
        let encoder = JSONFile.encoder()
        for record in records {
            output.append(try encoder.encode(record))
            output.append(0x0A)
        }
        return output
    }

    static func decode(_ data: Data) throws -> [MetaRecord] {
        let decoder = JSONFile.decoder
        var records: [MetaRecord] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(MetaRecord.self, from: Data(line)) else {
                throw MetadataError.invalidSegment
            }
            records.append(record)
        }
        return records
    }
}
