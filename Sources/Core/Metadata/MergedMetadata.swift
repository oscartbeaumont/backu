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

/// What one `apply` batch actually changed. A sync materialises only these ids
/// instead of walking the whole library, which is what keeps a 7 KB edit from
/// costing O(photos).
struct MetadataChangeSet: Sendable {
    /// Photo entities whose merged value changed (created or edited).
    var changedPhotos: Set<String> = []
    /// Photo entities that no longer exist, including ids that only gained a
    /// tombstone so a reader can drop a stale catalog entry.
    var removedPhotos: Set<String> = []
    var changedPeople: Set<String> = []
    var removedPeople: Set<String> = []
    /// SHA-256 values whose tombstone was raised.
    var deletedHashes: Set<String> = []

    mutating func formUnion(_ other: MetadataChangeSet) {
        changedPhotos.formUnion(other.changedPhotos)
        removedPhotos.formUnion(other.removedPhotos)
        changedPeople.formUnion(other.changedPeople)
        removedPeople.formUnion(other.removedPeople)
        deletedHashes.formUnion(other.deletedHashes)
    }

    /// An id can be touched and removed by the same batch. The final state
    /// decides whether a reader should upsert or drop it.
    mutating func resolve(with state: MergedMetadata) {
        for id in changedPhotos.intersection(removedPhotos) {
            if state.photos[id] == nil { changedPhotos.remove(id) } else { removedPhotos.remove(id) }
        }
        for id in changedPeople.intersection(removedPeople) {
            if state.people[id] == nil { changedPeople.remove(id) } else { removedPeople.remove(id) }
        }
    }
}

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

    var isEmpty: Bool {
        photos.isEmpty && people.isEmpty && photoTombstones.isEmpty
            && personTombstones.isEmpty && deletedHashes.isEmpty
    }

    func version(_ writer: String, _ hlc: Int64) -> Version {
        Version(hlc: hlc, writer: WriterFingerprint.of(writer))
    }

    // MARK: Apply

    @discardableResult
    mutating func apply(_ record: MetaRecord) -> MetadataChangeSet {
        let version = self.version(record.by, record.hlc)
        switch record.op {
        case .photoUpsert, .photoPatch:
            return applyPhoto(record, version: version)
        case .photoDelete:
            return applyPhotoDelete(record, version: version)
        case .personUpsert, .personPatch:
            return applyPerson(record, version: version)
        case .personDelete:
            return applyPersonDelete(record, version: version)
        case .deletedHash:
            var changes = MetadataChangeSet()
            if let sha = record.sha256 {
                if applyDeletedHash(sha, version: version) { changes.deletedHashes.insert(sha) }
            }
            return changes
        }
    }

    @discardableResult
    mutating func apply(_ records: [MetaRecord]) -> MetadataChangeSet {
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
        var result = MetadataChangeSet()
        for record in sorted { result.formUnion(apply(record)) }
        // One batch can remove and re-create the same entity. The end state
        // decides whether a reader should upsert or drop it.
        result.resolve(with: self)
        return result
    }

    private mutating func applyPhoto(_ record: MetaRecord, version: Version) -> MetadataChangeSet {
        var changes = MetadataChangeSet()
        guard let incoming = record.photo else { return changes }
        if let tombstone = photoTombstones[record.id], tombstone > version {
            return changes
        }
        let existing = photos[record.id]
        var entity = existing ?? MergedPhoto(photo: incoming)
        var mutated = existing == nil

        let fields = record.changed ?? SharedPhoto.Field.allCases.map(\.rawValue)
        for name in fields {
            guard let field = SharedPhoto.Field(rawValue: name) else { continue }
            if version > (entity.fieldVersions[name] ?? Version.zero) ||
                entity.fieldVersions[name] == nil {
                entity.photo.apply(field, from: incoming)
                entity.fieldVersions[name] = version
                mutated = true
            }
        }

        for tag in record.tagsAdd ?? [] {
            if applyTag(tag, present: true, version: version, to: &entity) { mutated = true }
        }
        for tag in record.tagsRemove ?? [] {
            if applyTag(tag, present: false, version: version, to: &entity) { mutated = true }
        }
        for face in record.facesSet ?? [] {
            let key = face.id.uuidString
            if version > (entity.faces[key]?.version ?? Version.zero) ||
                entity.faces[key] == nil {
                let updated = MergedFace(face: face, version: version)
                if entity.faces[key] != updated {
                    entity.faces[key] = updated
                    mutated = true
                }
            }
        }
        for faceID in record.facesDelete ?? [] {
            let key = faceID.uuidString
            if version > (entity.faces[key]?.version ?? Version.zero) {
                let updated = MergedFace(face: nil, version: version)
                if entity.faces[key] != updated {
                    entity.faces[key] = updated
                    mutated = true
                }
            }
        }

        if mutated {
            photos[record.id] = entity
            changes.changedPhotos.insert(record.id)
        }
        if let tombstone = photoTombstones[record.id], tombstone <= version {
            photoTombstones.removeValue(forKey: record.id)
            changes.changedPhotos.insert(record.id)
        }
        return changes
    }

    /// Returns true when the tag map actually changed.
    private func applyTag(_ tag: String, present: Bool, version: Version, to entity: inout MergedPhoto) -> Bool {
        if present {
            guard version > (entity.removedTags[tag] ?? Version.zero) ||
                    entity.removedTags[tag] == nil
            else { return false }
            // Always keep the highest add version: a delayed older add must
            // not lower the tag's watermark and let a later remove win.
            var mutated = false
            let updated = max(entity.tags[tag] ?? Version.zero, version)
            if entity.tags[tag] != updated {
                entity.tags[tag] = updated
                mutated = true
            }
            if (entity.removedTags[tag] ?? Version.zero) < version {
                if entity.removedTags.removeValue(forKey: tag) != nil { mutated = true }
            }
            return mutated
        } else {
            guard version > (entity.tags[tag] ?? Version.zero) || entity.tags[tag] == nil
            else { return false }
            var mutated = false
            let updated = max(entity.removedTags[tag] ?? Version.zero, version)
            if entity.removedTags[tag] != updated {
                entity.removedTags[tag] = updated
                mutated = true
            }
            if (entity.tags[tag] ?? Version.zero) < version {
                if entity.tags.removeValue(forKey: tag) != nil { mutated = true }
            }
            return mutated
        }
    }

    private mutating func applyPhotoDelete(_ record: MetaRecord, version: Version) -> MetadataChangeSet {
        var changes = MetadataChangeSet()
        if let existing = photos[record.id], existing.maxVersion > version {
            return changes
        }
        photos.removeValue(forKey: record.id)
        if version > (photoTombstones[record.id] ?? Version.zero) {
            photoTombstones[record.id] = version
        }
        // Report the id even when the entity was already gone: a reader may
        // hold a stale catalog entry for it.
        changes.removedPhotos.insert(record.id)
        return changes
    }

    private mutating func applyPerson(_ record: MetaRecord, version: Version) -> MetadataChangeSet {
        var changes = MetadataChangeSet()
        guard let incoming = record.person else { return changes }
        let key = incoming.id.uuidString
        if let tombstone = personTombstones[key], tombstone > version { return changes }
        let existing = people[key]
        var entity = existing ?? MergedPerson(person: incoming)
        var mutated = existing == nil
        let fields = record.changed ?? SharedPerson.Field.allCases.map(\.rawValue)
        for name in fields {
            guard let field = SharedPerson.Field(rawValue: name) else { continue }
            if version > (entity.fieldVersions[name] ?? Version.zero) ||
                entity.fieldVersions[name] == nil {
                entity.person.apply(field, from: incoming)
                entity.fieldVersions[name] = version
                mutated = true
            }
        }
        if mutated {
            people[key] = entity
            changes.changedPeople.insert(key)
        }
        if let tombstone = personTombstones[key], tombstone <= version {
            personTombstones.removeValue(forKey: key)
            changes.changedPeople.insert(key)
        }
        return changes
    }

    private mutating func applyPersonDelete(_ record: MetaRecord, version: Version) -> MetadataChangeSet {
        var changes = MetadataChangeSet()
        if let existing = people[record.id], existing.maxVersion > version { return changes }
        people.removeValue(forKey: record.id)
        if version > (personTombstones[record.id] ?? Version.zero) {
            personTombstones[record.id] = version
        }
        changes.removedPeople.insert(record.id)
        return changes
    }

    @discardableResult
    mutating func applyDeletedHash(_ sha: String, version: Version) -> Bool {
        if version > (deletedHashes[sha] ?? Version.zero) {
            deletedHashes[sha] = version
            return true
        }
        return false
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
            let (item, faces) = Self.item(for: entity, serverID: serverID)
            for face in faces {
                if let personID = face.personID {
                    faceCounts[personID, default: 0] += 1
                }
            }
            items.append(item)
        }

        let people = people.values.map { entity in
            entity.person.person(faceCount: faceCounts[entity.person.id] ?? 0)
        }
        let removedPeople = Set(personTombstones.keys.compactMap(UUID.init(uuidString:)))
        return (items, people, removedPeople, Set(deletedHashes.keys))
    }

    /// One entity as a catalog item, plus the faces it carries so the caller
    /// can count them without re-reading the item.
    private static func item(
        for entity: MergedPhoto,
        serverID: UUID
    ) -> (PhotoItem, [PhotoFace]) {
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

        // Keep the v1 convention for items that only exist in a bucket, so a
        // library migrated from `index.json` does not duplicate itself.
        let catalogID = entity.photo.id.hasPrefix("remote:") ? entity.photo.id : "remote:\(entity.photo.id)"
        let item = PhotoItem(
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
        return (item, faces)
    }

    /// The incremental counterpart of `materialize(serverID:)`: only the
    /// entities a sync changed. Duplicate-SHA canonicalisation stays in the
    /// full path; here an item whose bytes already exist in the catalog is
    /// folded into that photo by `CatalogStore` instead.
    func materialize(serverID: UUID, changes: MetadataChangeSet) -> (
        photos: [PhotoItem],
        people: [Person],
        deletedPeople: Set<UUID>,
        removedPhotoIDs: Set<String>
    ) {
        var photos: [PhotoItem] = []
        photos.reserveCapacity(changes.changedPhotos.count)
        for id in changes.changedPhotos {
            guard let entity = self.photos[id] else { continue }
            photos.append(Self.item(for: entity, serverID: serverID).0)
        }

        var people: [Person] = []
        var deletedPeople: Set<UUID> = []
        if !changes.changedPeople.isEmpty || !changes.removedPeople.isEmpty {
            // A person's face count spans every photo, so this is the one
            // O(library) part of an incremental sync — and it only runs when a
            // person actually changed.
            var counts: [UUID: Int] = [:]
            for entity in self.photos.values {
                for face in entity.faces.values {
                    guard let personID = face.face?.personID,
                          changes.changedPeople.contains(personID.uuidString)
                    else { continue }
                    counts[personID, default: 0] += 1
                }
            }
            people.reserveCapacity(changes.changedPeople.count)
            for key in changes.changedPeople {
                guard let entity = self.people[key] else { continue }
                people.append(entity.person.person(faceCount: counts[entity.person.id] ?? 0))
            }
            for key in changes.removedPeople {
                if let id = UUID(uuidString: key) { deletedPeople.insert(id) }
            }
            // An id that was both changed and removed is a deletion.
            for key in changes.changedPeople where self.people[key] == nil {
                if let id = UUID(uuidString: key) { deletedPeople.insert(id) }
            }
            people.removeAll { deletedPeople.contains($0.id) }
        }

        return (photos, people, deletedPeople, changes.removedPhotos)
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
    /// losing the rest, and a file-backed snapshot can be streamed instead of
    /// buffered.
    static func decodeSnapshot(_ data: Data) throws -> DecodedSnapshot {
        let builder = SnapshotBuilder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            builder.parse(Data(line))
        }
        guard let header = builder.header else { throw MetadataError.invalidSnapshot }
        return DecodedSnapshot(metadata: builder.metadata, header: header)
    }

    /// Decodes a gzipped snapshot straight from disk. The compressed body is
    /// never held in memory and each decoded line is dropped after it becomes a
    /// merged entity, which is what keeps a 100k-photo cold start from peaking
    /// at a full 60 MB JSON document.
    static func decodeSnapshot(gzipFile url: URL) throws -> DecodedSnapshot {
        let builder = SnapshotBuilder()
        var line = Data()
        line.reserveCapacity(4_096)
        try Gzip.decompress(fileURL: url) { chunk in
            let bytes = chunk.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, bytes.count > 0 else { return }
            // `memchr` rather than a Swift byte loop: this runs over ~60 MB on a
            // 100k-photo cold start.
            var start = 0
            while start < bytes.count {
                guard let found = memchr(base + start, 0x0A, bytes.count - start) else { break }
                let newline = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                line.append(base + start, count: newline - start)
                if !line.isEmpty {
                    builder.parse(line)
                    line.removeAll(keepingCapacity: true)
                }
                start = newline + 1
            }
            if start < bytes.count {
                line.append(base + start, count: bytes.count - start)
            }
        }
        if !line.isEmpty { builder.parse(line) }
        guard let header = builder.header else { throw MetadataError.invalidSnapshot }
        return DecodedSnapshot(metadata: builder.metadata, header: header)
    }

    /// Accumulates snapshot lines into a merged state. Shared by the buffered
    /// and streamed decoders so both accept exactly the same lines.
    private final class SnapshotBuilder {
        var metadata = MergedMetadata()
        var header: SnapshotHeader?

        func parse(_ body: Data) {
            struct KindLine: Codable { var kind: String }
            let decoder = JSONFile.decoder
            guard let kind = (try? decoder.decode(KindLine.self, from: body))?.kind else { return }
            switch kind {
            case "header":
                guard header == nil,
                      let decoded = try? decoder.decode(SnapshotHeaderLine.self, from: body)
                else { return }
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
                return
            }
        }
    }
}

enum MetadataError: LocalizedError {
    case invalidSnapshot
    case invalidSegment
    case missingObject(String)
    case missingHead
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The metadata snapshot could not be read."
        case .invalidSegment: return "A metadata segment could not be read."
        case let .missingObject(key): return "The metadata object \(key) is missing."
        case .missingHead: return "The bucket has no metadata head yet."
        case let .uploadFailed(reason): return "A metadata segment could not be uploaded. \(reason)"
        }
    }
}
