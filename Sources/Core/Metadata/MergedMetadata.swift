import Foundation

// MARK: - Merged entities

struct MergedFace: Codable, Hashable, Sendable {
    /// nil is a tombstone: the face was removed and an older segment must not
    /// bring it back.
    var face: SharedFace?
    var version: Version
}

struct MergedPhoto: Codable, Sendable {
    /// Two devices that uploaded the same bytes under different asset ids
    /// produce two entities with one SHA-256. Merge deterministically so every
    /// reader shows one photo with the same tags, faces and copies.
    func merging(_ other: MergedPhoto) -> MergedPhoto {
        var result = maxVersion >= other.maxVersion ? self : other
        let donor = maxVersion >= other.maxVersion ? other : self
        for field in SharedPhoto.Field.allCases {
            let name = field.rawValue
            let donorVersion = donor.fieldVersions[name] ?? Version.zero
            if donorVersion > (result.fieldVersions[name] ?? Version.zero) {
                result.photo.apply(field, from: donor.photo)
                result.fieldVersions[name] = donorVersion
            }
        }
        for (tag, version) in donor.tags where version > (result.tags[tag] ?? Version.zero) {
            result.tags[tag] = version
        }
        for (tag, version) in donor.removedTags where version > (result.removedTags[tag] ?? Version.zero) {
            result.removedTags[tag] = version
        }
        for (id, face) in donor.faces where face.version > (result.faces[id]?.version ?? Version.zero) {
            result.faces[id] = face
        }
        for copy in donor.photo.copies
        where !result.photo.copies.contains(where: { $0.objectKey == copy.objectKey }) {
            result.photo.copies.append(copy)
        }
        return result
    }

    var photo: SharedPhoto
    var fieldVersions: [String: Version] = [:]
    /// tag -> version of its latest add.
    var tags: [String: Version] = [:]
    /// tag -> version of its latest remove. Kept so a delayed add cannot
    /// resurrect a tag.
    var removedTags: [String: Version] = [:]
    /// Face id (string) -> face.
    var faces: [String: MergedFace] = [:]

    var maxVersion: Version {
        var max = fieldVersions.values.max() ?? Version.zero
        for version in tags.values where version > max { max = version }
        for version in removedTags.values where version > max { max = version }
        for face in faces.values where face.version > max { max = face.version }
        return max
    }
}

struct MergedPerson: Codable, Sendable {
    var person: SharedPerson
    var fieldVersions: [String: Version] = [:]

    var maxVersion: Version {
        fieldVersions.values.max() ?? Version.zero
    }
}

// MARK: - Merge

/// The materialised result of a snapshot plus every newer segment. Applying a
/// record is idempotent and order-independent: every mutating field compares
/// its own version, so a late upload with an older clock cannot overwrite a
/// newer edit.
struct MergedMetadata: Sendable {
    var photos: [String: MergedPhoto] = [:]
    /// UUID string -> person.
    var people: [String: MergedPerson] = [:]
    var photoTombstones: [String: Version] = [:]
    var personTombstones: [String: Version] = [:]
    var deletedHashes: [String: Version] = [:]

    init() {}

    func version(_ writer: String, _ hlc: Int64) -> Version {
        Version(hlc: hlc, writer: WriterFingerprint.of(writer))
    }

    // MARK: Apply

    mutating func apply(_ record: MetaRecord) {
        let version = self.version(record.by, record.hlc)
        switch record.op {
        case .photoUpsert, .photoPatch:
            applyPhoto(record, version: version)
        case .photoDelete:
            applyPhotoDelete(record, version: version)
        case .personUpsert, .personPatch:
            applyPerson(record, version: version)
        case .personDelete:
            applyPersonDelete(record, version: version)
        case .deletedHash:
            if let sha = record.sha256 { applyDeletedHash(sha, version: version) }
        }
    }

    mutating func apply(_ records: [MetaRecord]) {
        // Upserts must be applied before patches from other writers, otherwise
        // a patch could create a half-versioned entity that a late, older
        // upsert then overwrites. Sorting is deterministic across devices.
        let sorted = records.sorted { lhs, rhs in
            if lhs.hlc != rhs.hlc { return lhs.hlc < rhs.hlc }
            let left = WriterFingerprint.of(lhs.by)
            let right = WriterFingerprint.of(rhs.by)
            if left != right { return left < right }
            return lhs.op.rawValue < rhs.op.rawValue
        }
        for record in sorted { apply(record) }
    }

    private mutating func applyPhoto(_ record: MetaRecord, version: Version) {
        guard let incoming = record.photo else { return }
        if let tombstone = photoTombstones[record.id], tombstone > version {
            return
        }
        var entity: MergedPhoto
        if let existing = photos[record.id] {
            entity = existing
        } else {
            entity = MergedPhoto(photo: incoming)
        }

        let fields = record.changed ?? SharedPhoto.Field.allCases.map(\.rawValue)
        for name in fields {
            guard let field = SharedPhoto.Field(rawValue: name) else { continue }
            if version > (entity.fieldVersions[name] ?? Version.zero) ||
                entity.fieldVersions[name] == nil {
                entity.photo.apply(field, from: incoming)
                entity.fieldVersions[name] = version
            }
        }

        for tag in record.tagsAdd ?? [] {
            applyTag(tag, present: true, version: version, to: &entity)
        }
        for tag in record.tagsRemove ?? [] {
            applyTag(tag, present: false, version: version, to: &entity)
        }
        for face in record.facesSet ?? [] {
            let key = face.id.uuidString
            if version > (entity.faces[key]?.version ?? Version.zero) ||
                entity.faces[key] == nil {
                entity.faces[key] = MergedFace(face: face, version: version)
            }
        }
        for faceID in record.facesDelete ?? [] {
            let key = faceID.uuidString
            if version > (entity.faces[key]?.version ?? Version.zero) {
                entity.faces[key] = MergedFace(face: nil, version: version)
            }
        }

        photos[record.id] = entity
        if let tombstone = photoTombstones[record.id], tombstone <= version {
            photoTombstones.removeValue(forKey: record.id)
        }
    }

    private func applyTag(_ tag: String, present: Bool, version: Version, to entity: inout MergedPhoto) {
        if present {
            if version > (entity.removedTags[tag] ?? Version.zero) ||
                entity.removedTags[tag] == nil {
                // Always keep the highest add version: a delayed older add must
                // not lower the tag's watermark and let a later remove win.
                entity.tags[tag] = max(entity.tags[tag] ?? Version.zero, version)
                if (entity.removedTags[tag] ?? Version.zero) < version {
                    entity.removedTags.removeValue(forKey: tag)
                }
            }
        } else {
            if version > (entity.tags[tag] ?? Version.zero) ||
                entity.tags[tag] == nil {
                entity.removedTags[tag] = max(entity.removedTags[tag] ?? Version.zero, version)
                if (entity.tags[tag] ?? Version.zero) < version {
                    entity.tags.removeValue(forKey: tag)
                }
            }
        }
    }

    private mutating func applyPhotoDelete(_ record: MetaRecord, version: Version) {
        if let existing = photos[record.id], existing.maxVersion > version {
            return
        }
        photos.removeValue(forKey: record.id)
        if version > (photoTombstones[record.id] ?? Version.zero) {
            photoTombstones[record.id] = version
        }
    }

    private mutating func applyPerson(_ record: MetaRecord, version: Version) {
        guard let incoming = record.person else { return }
        let key = incoming.id.uuidString
        if let tombstone = personTombstones[key], tombstone > version { return }
        var entity = people[key] ?? MergedPerson(person: incoming)
        let fields = record.changed ?? SharedPerson.Field.allCases.map(\.rawValue)
        for name in fields {
            guard let field = SharedPerson.Field(rawValue: name) else { continue }
            if version > (entity.fieldVersions[name] ?? Version.zero) ||
                entity.fieldVersions[name] == nil {
                entity.person.apply(field, from: incoming)
                entity.fieldVersions[name] = version
            }
        }
        people[key] = entity
        if let tombstone = personTombstones[key], tombstone <= version {
            personTombstones.removeValue(forKey: key)
        }
    }

    private mutating func applyPersonDelete(_ record: MetaRecord, version: Version) {
        if let existing = people[record.id], existing.maxVersion > version { return }
        people.removeValue(forKey: record.id)
        if version > (personTombstones[record.id] ?? Version.zero) {
            personTombstones[record.id] = version
        }
    }

    mutating func applyDeletedHash(_ sha: String, version: Version) {
        if version > (deletedHashes[sha] ?? Version.zero) {
            deletedHashes[sha] = version
        }
    }

    // MARK: Materialise

    /// The current shared state as catalog items for one bucket.
    func materialize(serverID: UUID) -> (
        photos: [PhotoItem],
        people: [Person],
        deletedPeople: Set<UUID>,
        deletedHashes: Set<String>
    ) {
        var faceCounts: [UUID: Int] = [:]
        var items: [PhotoItem] = []
        items.reserveCapacity(photos.count)

        // Canonicalise duplicates by SHA first: the same bytes uploaded by two
        // devices must be one photo, not two entries whose tags differ by
        // dictionary iteration order.
        let ordered = photos.values.sorted { $0.photo.id < $1.photo.id }
        var canonical: [MergedPhoto] = []
        var indexByHash: [String: Int] = [:]
        for entity in ordered {
            if let sha = entity.photo.sha256, let index = indexByHash[sha] {
                canonical[index] = canonical[index].merging(entity)
            } else {
                if let sha = entity.photo.sha256 { indexByHash[sha] = canonical.count }
                canonical.append(entity)
            }
        }

        for entity in canonical {
            let copy = entity.photo.copies.map { $0.photoCopy(serverID: serverID) }
            let tags = entity.tags
                .filter { tag, version in version > (entity.removedTags[tag] ?? Version.zero) }
                .map(\.key)
                .sorted()
            let faces: [PhotoFace] = entity.faces.values
                .compactMap(\.face)
                .sorted { lhs, rhs in
                    lhs.quality == rhs.quality ? lhs.id.uuidString < rhs.id.uuidString : lhs.quality > rhs.quality
                }
                .map { $0.photoFace(embeddingIndex: nil) }
            for face in faces {
                if let personID = face.personID {
                    faceCounts[personID, default: 0] += 1
                }
            }

            // Keep the v1 convention for items that only exist in a bucket, so
            // a library migrated from `index.json` does not duplicate itself.
            let catalogID = entity.photo.id.hasPrefix("remote:") ? entity.photo.id : "remote:\(entity.photo.id)"
            items.append(
                PhotoItem(
                    id: catalogID,
                    localIdentifier: nil,
                    filename: entity.photo.filename,
                    takenAt: entity.photo.takenAt,
                    addedAt: entity.photo.addedAt,
                    modifiedAt: entity.photo.modifiedAt,
                    isVideo: entity.photo.isVideo,
                    isFavorite: entity.photo.isFavorite,
                    pixelWidth: entity.photo.pixelWidth,
                    pixelHeight: entity.photo.pixelHeight,
                    duration: entity.photo.duration,
                    tags: tags,
                    metadata: entity.photo.metadata,
                    faces: faces,
                    copies: copy,
                    sha256: entity.photo.sha256,
                    remoteThumbnailKey: copy.first?.thumbnailKey,
                    serverID: serverID
                )
            )
        }

        let people = people.values.map { entity in
            entity.person.person(faceCount: faceCounts[entity.person.id] ?? 0)
        }
        let removedPeople = Set(personTombstones.keys.compactMap(UUID.init(uuidString:)))
        return (items, people, removedPeople, Set(deletedHashes.keys))
    }

    /// Shared records for local edits. `nil` means no change worth logging.
    func sharedPhoto(for id: String) -> SharedPhoto? {
        photos[id]?.photo
    }

    func sharedPerson(for id: UUID) -> SharedPerson? {
        people[id.uuidString]?.person
    }

    // MARK: Snapshot

    func encodeSnapshot(generation: Int, watermark: [String: Int], createdAt: Date = Date()) -> Data {
        var lines: [Data] = []
        let header = SnapshotHeader(
            generation: generation,
            writers: [],
            watermark: watermark,
            createdAt: createdAt,
            count: photos.count + people.count
        )
        if let data = try? JSONFile.encoder().encode(SnapshotHeaderLine(header: header)) {
            lines.append(data)
        }
        let encoder = JSONFile.encoder()
        for entity in photos.values {
            if let data = try? encoder.encode(SnapshotPhotoLine(photo: entity)) {
                lines.append(data)
            }
        }
        for entity in people.values {
            if let data = try? encoder.encode(SnapshotPersonLine(person: entity)) {
                lines.append(data)
            }
        }
        for (id, version) in photoTombstones {
            if let data = try? encoder.encode(SnapshotTombstoneLine(id: id, version: version)) {
                lines.append(data)
            }
        }
        for (id, version) in personTombstones {
            if let data = try? encoder.encode(SnapshotPersonTombstoneLine(id: id, version: version)) {
                lines.append(data)
            }
        }
        for (sha, version) in deletedHashes {
            if let data = try? encoder.encode(SnapshotHashLine(sha256: sha, version: version)) {
                lines.append(data)
            }
        }
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        return output
    }

    struct DecodedSnapshot: Sendable {
        var metadata: MergedMetadata
        var header: SnapshotHeader
    }

    /// JSONL is decoded line by line: a damaged tail can be skipped without
    /// losing the rest, and the same shape can later be streamed instead of
    /// buffered.
    static func decodeSnapshot(_ data: Data) throws -> DecodedSnapshot {
        struct KindLine: Codable { var kind: String }

        var metadata = MergedMetadata()
        var header: SnapshotHeader?
        let decoder = JSONFile.decoder

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let body = Data(line)
            guard let kind = (try? decoder.decode(KindLine.self, from: body))?.kind else { continue }
            switch kind {
            case "header":
                guard header == nil,
                      let decoded = try? decoder.decode(SnapshotHeaderLine.self, from: body)
                else { continue }
                header = decoded.header
            case "photo":
                if let decoded = try? decoder.decode(SnapshotPhotoLine.self, from: body) {
                    metadata.photos[decoded.photo.photo.id] = decoded.photo
                }
            case "person":
                if let decoded = try? decoder.decode(SnapshotPersonLine.self, from: body) {
                    metadata.people[decoded.person.person.id.uuidString] = decoded.person
                }
            case "tombstone":
                if let decoded = try? decoder.decode(SnapshotTombstoneLine.self, from: body) {
                    metadata.photoTombstones[decoded.id] = decoded.version
                }
            case "personTombstone":
                if let decoded = try? decoder.decode(SnapshotPersonTombstoneLine.self, from: body) {
                    metadata.personTombstones[decoded.id] = decoded.version
                }
            case "hash":
                if let decoded = try? decoder.decode(SnapshotHashLine.self, from: body) {
                    metadata.deletedHashes[decoded.sha256] = decoded.version
                }
            default:
                continue
            }
        }

        guard let header else { throw MetadataError.invalidSnapshot }
        return DecodedSnapshot(metadata: metadata, header: header)
    }
}

enum MetadataError: LocalizedError {
    case invalidSnapshot
    case invalidSegment
    case missingObject(String)
    case missingHead

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The metadata snapshot could not be read."
        case .invalidSegment: return "A metadata segment could not be read."
        case let .missingObject(key): return "The metadata object \(key) is missing."
        case .missingHead: return "The bucket has no metadata head yet."
        }
    }
}
