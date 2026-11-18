import Foundation

/// Device-wide writer identity. One per install, shared by every bucket: the
/// writer prefix is namespaced by bucket anyway, and a single id makes the
/// segment names comparable across servers in tooling.
enum MetadataWriterIdentity {
    private static let key = "metadataWriterID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

/// What exists on the server for this bucket. Persisted next to the cache so a
/// relaunch knows exactly which segments it has already folded in.
struct MetadataReplicationState: Codable, Sendable {
    var writerID: String
    var sequence: Int = 0
    var headETag: String?
    var generation: Int = 0
    var snapshotKey: String?
    /// The snapshot named by the last decoded head. Needed on a 304, where the
    /// head body is skipped but a snapshot fetch may still be required.
    var headSnapshot: String?
    /// writer id -> highest segment sequence applied.
    var watermark: [String: Int] = [:]
    var lastSyncAt: Date?
    var lastHLC: Int64 = 0
    var segmentsSinceSnapshot: Int = 0
    var editsSinceSnapshot: Int = 0
    /// A bucket with no head and no segments at first contact needs its existing
    /// library published once. Persisted so a partial seed resumes.
    var isMigration: Bool = false
    var seeded: Bool = false
    /// Last photo id (sorted) whose seed batch was flushed.
    var seedLastID: String?
    /// The batch currently sitting in the outbox. Advanced on the next start.
    var seedPendingLastID: String?

    private enum CodingKeys: String, CodingKey {
        case writerID, sequence, headETag, generation, snapshotKey, headSnapshot, watermark
        case lastSyncAt, lastHLC, segmentsSinceSnapshot, editsSinceSnapshot
        case isMigration, seeded, seedLastID, seedPendingLastID
    }

    init(writerID: String) {
        self.writerID = writerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        writerID = try container.decodeIfPresent(String.self, forKey: .writerID) ?? ""
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        headETag = try container.decodeIfPresent(String.self, forKey: .headETag)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        snapshotKey = try container.decodeIfPresent(String.self, forKey: .snapshotKey)
        headSnapshot = try container.decodeIfPresent(String.self, forKey: .headSnapshot)
        watermark = try container.decodeIfPresent([String: Int].self, forKey: .watermark) ?? [:]
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastHLC = try container.decodeIfPresent(Int64.self, forKey: .lastHLC) ?? 0
        segmentsSinceSnapshot = try container.decodeIfPresent(Int.self, forKey: .segmentsSinceSnapshot) ?? 0
        editsSinceSnapshot = try container.decodeIfPresent(Int.self, forKey: .editsSinceSnapshot) ?? 0
        isMigration = try container.decodeIfPresent(Bool.self, forKey: .isMigration) ?? false
        seeded = try container.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        seedLastID = try container.decodeIfPresent(String.self, forKey: .seedLastID)
        seedPendingLastID = try container.decodeIfPresent(String.self, forKey: .seedPendingLastID)
    }
}

struct MetadataSyncOutcome: Sendable {
    var hasHead: Bool = false
    /// True when this bucket already has v2 data (a head, snapshot or segment).
    var sawLog: Bool = false
    var changed: Bool = false
    var photos: [PhotoItem] = []
    var people: [Person] = []
    var deletedPeople: Set<UUID> = []
    var deletedHashes: Set<String> = []
}

/// One bucket's replication state, writer queue and compactor.
///
/// The normal edit path only appends to this device's own segment namespace, so
/// two devices never contend. Compaction is the single place that writes a
/// shared object (`head.json`), and a lost race just leaves an orphan snapshot.
@MainActor
final class MetadataService {
    let serverID: UUID
    private(set) var state = MergedMetadata()
    private(set) var replication: MetadataReplicationState
    private(set) var outbox: [MetaRecord] = []
    private var catalog: CatalogStore?

    private var syncing = false
    private var compacting = false
    private var flushing = false
    /// False when the local merged-state cache could not be read. A 304 on the
    /// head must then re-fetch the snapshot instead of trusting local state.
    private var cacheLoaded = false
    /// A per-bucket state file that did not exist means the segment sequence may
    /// collide with segments this writer published before (remove server,
    /// reset). One probe on the first sync fixes the counter.
    private var probedSequence = false
    private var stateFileExisted = false

    private(set) var hasSynced = false
    private(set) var sawLog = false
    var hasOutbox: Bool { !outbox.isEmpty }

    private let compactionSegmentThreshold = 8

    init(serverID: UUID, writerID: String? = nil) {
        self.serverID = serverID
        let url = AppPaths.metadataStateFile(serverID)
        stateFileExisted = FileManager.default.fileExists(atPath: url.path)
        var persisted = JSONFile.read(MetadataReplicationState.self, from: url)
        if persisted == nil {
            persisted = MetadataReplicationState(writerID: MetadataWriterIdentity.current)
        }
        var value = persisted!
        if let writerID {
            value.writerID = writerID
        } else if value.writerID.isEmpty {
            value.writerID = MetadataWriterIdentity.current
        }
        replication = value
        if replication.lastHLC == 0 {
            replication.lastHLC = HybridClock.now() << 16
        }
        loadCache()
        outbox = Self.loadOutbox(serverID)
        if let max = outbox.map(\.hlc).max(), max > replication.lastHLC {
            replication.lastHLC = max
        }
    }

    func configure(catalog: CatalogStore) {
        self.catalog = catalog
    }

    // MARK: - Clock

    private func tick() -> Int64 {
        let now = HybridClock.now()
        if now > (replication.lastHLC >> 16) {
            replication.lastHLC = now << 16
        } else {
            replication.lastHLC += 1
        }
        return replication.lastHLC
    }

    /// Standard HLC receive step: a device with a slow clock must be able to
    /// overtake records it has seen rather than losing every edit until its
    /// wall clock catches up.
    private func observe(_ records: [MetaRecord]) {
        guard let max = records.map(\.hlc).max() else { return }
        if max > replication.lastHLC {
            replication.lastHLC = max
        }
    }

    // MARK: - Reading

    func sync(store: MetadataObjectStore) async throws -> MetadataSyncOutcome {
        guard !syncing else { return MetadataSyncOutcome(hasHead: sawLog, sawLog: sawLog) }
        syncing = true
        defer { syncing = false }

        var head: MetadataHead?
        var headUnreadable = false
        var headNotModified = false
        switch try await store.getObject(MetadataLayout.headKey, ifNoneMatch: replication.headETag) {
        case let .notModified(etag):
            headNotModified = true
            replication.headETag = etag
        case let .found(data, etag):
            if let decoded = try? JSONFile.decoder.decode(MetadataHead.self, from: data) {
                head = decoded
                replication.headETag = etag
            } else {
                // Do not remember the ETag: a head from a newer schema should be
                // retried, not wedged into the "no head" branch.
                headUnreadable = true
            }
        case .missing:
            head = nil
        }

        if headUnreadable {
            // Something owns this bucket. Never migrate or seed over it.
            return MetadataSyncOutcome(hasHead: true, sawLog: true, changed: false)
        }

        if !probedSequence {
            probedSequence = true
            try await probeSequence(store: store)
        }

        if let head { replication.headSnapshot = head.snapshot }
        var changed = false
        let headSnapshot = head?.snapshot ?? replication.headSnapshot
        let needsSnapshot = headSnapshot != replication.snapshotKey
            || (!cacheLoaded && replication.snapshotKey != nil)
        if needsSnapshot, let snapshotKey = headSnapshot ?? replication.snapshotKey {
            let compressed = try await read(snapshotKey, from: store)
            let raw = try await Self.gunzipInBackground(compressed)
            // Parsing a 100k-photo snapshot is hundreds of milliseconds; keep
            // it off the main actor.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try MergedMetadata.decodeSnapshot(raw)
            }.value
            state = decoded.metadata
            replication.snapshotKey = snapshotKey
            replication.headSnapshot = snapshotKey
            replication.generation = max(decoded.header.generation, head?.generation ?? 0)
            // The snapshot's own watermark is authority: the state file may
            // have advanced past a cache write that never landed.
            replication.watermark = decoded.header.watermark
            cacheLoaded = true
            changed = true
        }

        // A 304 only skips the head *body*; segments still have to be listed or
        // edits made since the last compaction never arrive.
        let segments = try await pendingSegments(store: store)
        if !segments.isEmpty {
            let downloaded = try await download(segments: segments, store: store)
            var records: [MetaRecord] = []
            for item in downloaded {
                records.append(contentsOf: item.records)
                replication.watermark[item.writer] = max(
                    replication.watermark[item.writer] ?? -1,
                    item.sequence
                )
                replication.segmentsSinceSnapshot += 1
            }
            state.apply(records)
            observe(records)
            changed = true
        }

        if !stateFileExisted {
            stateFileExisted = true
        }
        hasSynced = true
        let hasHead = head != nil || headNotModified
        sawLog = hasHead || !segments.isEmpty || !state.photos.isEmpty
        if !hasHead && !sawLog {
            replication.isMigration = true
        }
        replication.lastSyncAt = Date()
        persist()
        if changed {
            let materialized = state.materialize(serverID: serverID)
            persistCache()
            return MetadataSyncOutcome(
                hasHead: hasHead,
                sawLog: sawLog,
                changed: true,
                photos: materialized.photos,
                people: materialized.people,
                deletedPeople: materialized.deletedPeople,
                deletedHashes: materialized.deletedHashes
            )
        }
        return MetadataSyncOutcome(hasHead: hasHead, sawLog: sawLog, changed: false)
    }

    private func read(_ key: String, from store: MetadataObjectStore) async throws -> Data {
        switch try await store.getObject(key, ifNoneMatch: nil) {
        case let .found(data, _): return data
        case .missing: throw MetadataError.missingObject(key)
        case .notModified: throw MetadataError.invalidSegment
        }
    }

    private struct PendingSegment {
        var key: String
        var writer: String
        var sequence: Int
    }

    /// Lists writer namespaces with one delimiter request, then one
    /// `start-after` list per writer. This avoids walking the whole history on
    /// every sync, which is what makes steady-state replication cheap.
    private func pendingSegments(store: MetadataObjectStore) async throws -> [PendingSegment] {
        let logPrefix = MetadataLayout.logPrefix + "/"
        var writers = Set<String>()
        var direct: [PendingSegment] = []
        var token: String?
        var maxSequences: [String: Int] = [:]

        repeat {
            let page = try await store.listObjects(
                prefix: logPrefix,
                delimiter: "/",
                startAfter: nil,
                continuationToken: token,
                maxKeys: 1000
            )
            for prefix in page.commonPrefixes {
                let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
                if let name = trimmed.split(separator: "/").last, !name.isEmpty {
                    writers.insert(String(name))
                }
            }
            for key in page.keys {
                guard let parsed = MetadataLayout.parseSegment(key) else { continue }
                writers.insert(parsed.writer)
                maxSequences[parsed.writer] = max(maxSequences[parsed.writer] ?? -1, parsed.sequence)
                if parsed.sequence > (replication.watermark[parsed.writer] ?? -1) {
                    direct.append(PendingSegment(key: key, writer: parsed.writer, sequence: parsed.sequence))
                }
            }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil

        // A delimiter-aware store gives no keys above, so ask each writer only
        // for what is new. `start-after` on a zero-padded sequence is the first
        // unseen segment without walking the writer's history.
        if direct.isEmpty {
            for writer in writers {
                let prefix = MetadataLayout.writerPrefix(writer)
                let startSequence = (replication.watermark[writer] ?? -1) + 1
                var startAfter: String? = String(format: "%@/%012d", prefix, startSequence)
                var continuation: String?
                repeat {
                    let page = try await store.listObjects(
                        prefix: prefix + "/",
                        delimiter: nil,
                        startAfter: startAfter,
                        continuationToken: continuation,
                        maxKeys: 1000
                    )
                    for key in page.keys {
                        guard let parsed = MetadataLayout.parseSegment(key),
                              parsed.writer == writer,
                              parsed.sequence > (replication.watermark[writer] ?? -1)
                        else { continue }
                        maxSequences[writer] = max(maxSequences[writer] ?? -1, parsed.sequence)
                        direct.append(PendingSegment(key: key, writer: writer, sequence: parsed.sequence))
                    }
                    continuation = page.isTruncated ? page.nextToken : nil
                    startAfter = nil
                } while continuation != nil
            }
        }

        direct.sort { lhs, rhs in
            lhs.sequence == rhs.sequence ? lhs.writer < rhs.writer : lhs.sequence < rhs.sequence
        }
        return direct
    }

    /// A removed-and-re-added server loses its state file, including the
    /// sequence counter. Reusing sequence 0 would make every existing reader
    /// ignore the new segments forever, so inspect this writer's namespace once
    /// when the state file was absent.
    private func probeSequence(store: MetadataObjectStore) async throws {
        guard replication.sequence == 0, !stateFileExisted else { return }
        var maxSequence = -1
        var token: String?
        repeat {
            let page = try await store.listObjects(
                prefix: MetadataLayout.writerPrefix(replication.writerID) + "/",
                delimiter: nil,
                startAfter: nil,
                continuationToken: token,
                maxKeys: 1000
            )
            for key in page.keys {
                guard let parsed = MetadataLayout.parseSegment(key),
                      parsed.writer == replication.writerID
                else { continue }
                maxSequence = max(maxSequence, parsed.sequence)
            }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
        if maxSequence >= 0 {
            replication.sequence = maxSequence + 1
            persist()
        }
    }

    private func download(
        segments: [PendingSegment],
        store: MetadataObjectStore
    ) async throws -> [(writer: String, sequence: Int, records: [MetaRecord])] {
        var results: [(writer: String, sequence: Int, records: [MetaRecord])] = []
        results.reserveCapacity(segments.count)
        let concurrency = 4
        var index = 0
        while index < segments.count {
            let batch = Array(segments[index..<min(index + concurrency, segments.count)])
            let decoded = try await withThrowingTaskGroup(
                of: (String, Int, [MetaRecord]).self
            ) { group in
                for segment in batch {
                    group.addTask {
                        // A missing or corrupt segment aborts the whole sync so
                        // the watermark never advances past unread records.
                        let compressed: Data
                        switch try await store.getObject(segment.key, ifNoneMatch: nil) {
                        case let .found(data, _): compressed = data
                        case .missing: throw MetadataError.missingObject(segment.key)
                        case .notModified: throw MetadataError.invalidSegment
                        }
                        let raw = try Gzip.decompress(compressed)
                        return (segment.writer, segment.sequence, MetadataSegmentCodec.decode(raw))
                    }
                }
                var collected: [(String, Int, [MetaRecord])] = []
                for try await value in group { collected.append(value) }
                return collected
            }
            results.append(contentsOf: decoded)
            index += batch.count
        }
        return results
    }

    // MARK: - Writing

    /// Diffs the catalog's dirty ids against the merged state and appends only
    /// what changed. A photo with no copy in this bucket is not shared.
    @discardableResult
    func recordLocalChanges(delta: MetadataDelta, catalog: CatalogStore) -> Int {
        guard delta.isDirty else { return 0 }
        var records: [MetaRecord] = []
        var referencedPeople: Set<UUID> = []

        for id in delta.touchedPhotos {
            guard let photo = catalog.photo(id: id) else { continue }
            for face in photo.faces {
                if let personID = face.personID { referencedPeople.insert(personID) }
            }
            records.append(contentsOf: photoRecords(for: photo))
        }

        for (id, sha) in delta.deletedPhotos {
            let canonical = id.hasPrefix("remote:") ? String(id.dropFirst("remote:".count)) : id
            records.append(
                MetaRecord(op: .photoDelete, id: canonical, hlc: tick(), by: replication.writerID)
            )
            if let sha {
                records.append(
                    MetaRecord(
                        op: .deletedHash,
                        id: canonical,
                        hlc: tick(),
                        by: replication.writerID,
                        sha256: sha
                    )
                )
            }
        }

        var personIDs = delta.touchedPeople
        personIDs.formUnion(referencedPeople)
        for id in personIDs {
            guard let person = catalog.person(id: id) else { continue }
            records.append(contentsOf: personRecords(for: person))
        }
        for id in delta.deletedPeople {
            records.append(
                MetaRecord(op: .personDelete, id: id.uuidString, hlc: tick(), by: replication.writerID)
            )
        }

        guard !records.isEmpty else { return 0 }
        outbox.append(contentsOf: records)
        persistOutbox()
        return records.count
    }

    private func photoRecords(for photo: PhotoItem) -> [MetaRecord] {
        let shared = SharedPhoto(photo: photo, serverID: serverID)
        let existing = state.photos[shared.id]

        guard !shared.copies.isEmpty else {
            // No copy in this bucket any more. A v2 bucket should stop
            // advertising it. A photo with a nil sha is still a valid record;
            // deleting it here was a data-loss bug.
            guard existing != nil else { return [] }
            return [MetaRecord(op: .photoDelete, id: shared.id, hlc: tick(), by: replication.writerID)]
        }

        let tags = Set(photo.tags)
        var existingTags: Set<String> = []
        if let existing {
            for (tag, version) in existing.tags
            where version > (existing.removedTags[tag] ?? Version.zero) {
                existingTags.insert(tag)
            }
        }
        let tagsAdd = Array(tags.subtracting(existingTags))
        let tagsRemove = Array(existingTags.subtracting(tags))

        let currentFaces = Dictionary(
            uniqueKeysWithValues: photo.faces.map { ($0.id.uuidString, SharedFace(face: $0)) }
        )
        let existingFaces = existing?.faces.compactMapValues { $0.face } ?? [:]
        let facesSet = currentFaces.filter { key, face in existingFaces[key] != face }.map(\.value)
        let facesDelete = existingFaces.keys
            .filter { currentFaces[$0] == nil }
            .compactMap(UUID.init(uuidString:))

        var changed: [String] = []
        if let existing {
            for field in SharedPhoto.Field.allCases where !shared.matches(existing.photo, field: field) {
                changed.append(field.rawValue)
            }
        }

        let hasEntity = existing != nil
        let hasPatch = !changed.isEmpty || !tagsAdd.isEmpty || !tagsRemove.isEmpty
            || !facesSet.isEmpty || !facesDelete.isEmpty
        guard !hasEntity || hasPatch else { return [] }

        return [
            MetaRecord(
                op: hasEntity ? .photoPatch : .photoUpsert,
                id: shared.id,
                hlc: tick(),
                by: replication.writerID,
                photo: shared,
                changed: hasEntity ? changed : nil,
                tagsAdd: tagsAdd.isEmpty ? nil : tagsAdd,
                tagsRemove: tagsRemove.isEmpty ? nil : tagsRemove,
                facesSet: facesSet.isEmpty ? nil : facesSet,
                facesDelete: facesDelete.isEmpty ? nil : facesDelete
            )
        ]
    }

    private func personRecords(for person: Person) -> [MetaRecord] {
        let key = person.id.uuidString
        // A remote deletion wins over a local edit made before the delete was
        // applied: do not resurrect the person with a fresh timestamp.
        if state.people[key] == nil, state.personTombstones[key] != nil {
            return []
        }
        let shared = SharedPerson(person: person)
        let existing = state.people[key]
        var changed: [String] = []
        if let existing {
            for field in SharedPerson.Field.allCases where !shared.matches(existing.person, field: field) {
                changed.append(field.rawValue)
            }
            guard !changed.isEmpty else { return [] }
        }
        return [
            MetaRecord(
                op: existing == nil ? .personUpsert : .personPatch,
                id: key,
                hlc: tick(),
                by: replication.writerID,
                changed: existing == nil ? nil : changed,
                person: shared
            )
        ]
    }

    /// Publishes the outbox in one PUT per chunk. A failed PUT leaves the
    /// records in the outbox; retrying reuses the same key and bytes, so a
    /// lost response cannot duplicate a segment.
    ///
    /// Returns false when another flush is already running; the outbox is still
    /// intact and the caller should retry rather than assume success.
    @discardableResult
    func flush(store: MetadataObjectStore) async throws -> Bool {
        guard !outbox.isEmpty else { return true }
        guard !flushing else { return false }
        flushing = true
        defer { flushing = false }

        while !outbox.isEmpty {
            let chunk = Array(outbox.prefix(500))
            let raw = try MetadataSegmentCodec.encode(chunk)
            let compressed = try await Self.gzipInBackground(raw)
            let hlc = chunk.map(\.hlc).max() ?? tick()
            let key = MetadataLayout.segmentKey(
                writer: replication.writerID,
                sequence: replication.sequence,
                hlc: hlc,
                digest: SigV4Signer.sha256Hex(compressed)
            )
            try await store.putObject(key, data: compressed, contentType: "application/gzip")
            outbox.removeFirst(chunk.count)
            replication.sequence += 1
            replication.segmentsSinceSnapshot += 1
            replication.editsSinceSnapshot += chunk.count
            persistOutbox()
            persist()
        }
        return true
    }

    // MARK: - Migration

    /// One-time publish of a bucket that predates v2 (or a fresh bucket whose
    /// device already has uploaded photos).
    ///
    /// Resumable by *id*, not array index: a scan re-sorts and inserts photos
    /// between runs. A failed batch stays in the outbox; the next attempt
    /// flushes it before moving the cursor.
    func seedIfNeeded(catalog: CatalogStore, store: MetadataObjectStore) async {
        guard !replication.seeded, replication.isMigration else { return }
        if !outbox.isEmpty {
            do {
                guard try await flush(store: store) else { return }
            } catch {
                return
            }
            if let pending = replication.seedPendingLastID {
                replication.seedLastID = pending
                replication.seedPendingLastID = nil
                persist()
            }
        }

        let photos = catalog.photos.sorted { $0.id < $1.id }
        var cursor = 0
        if let last = replication.seedLastID {
            cursor = photos.firstIndex { $0.id > last } ?? photos.count
        }

        while cursor < photos.count {
            let upper = min(cursor + 500, photos.count)
            var records: [MetaRecord] = []
            var lastID: String?
            for photo in photos[cursor..<upper] {
                guard let copy = photo.copy(on: serverID) else { continue }
                let shared = SharedPhoto(photo: photo, serverID: serverID)
                guard !shared.copies.isEmpty else { continue }
                lastID = photo.id
                records.append(
                    MetaRecord(
                        op: .photoUpsert,
                        id: shared.id,
                        hlc: tick(),
                        by: replication.writerID,
                        photo: shared,
                        tagsAdd: photo.tags.isEmpty ? nil : photo.tags,
                        facesSet: photo.faces.isEmpty ? nil : photo.faces.map(SharedFace.init),
                        sha256: copy.sha256
                    )
                )
            }
            cursor = upper
            guard !records.isEmpty else { continue }
            outbox.append(contentsOf: records)
            replication.seedPendingLastID = lastID
            persistOutbox()
            persist()
            do {
                guard try await flush(store: store) else { return }
            } catch {
                return
            }
            if let pending = replication.seedPendingLastID {
                replication.seedLastID = pending
                replication.seedPendingLastID = nil
                persist()
            }
        }

        // People and local deletions are small; emit them in one pass.
        var records: [MetaRecord] = []
        for person in catalog.people.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            records.append(
                MetaRecord(
                    op: .personUpsert,
                    id: person.id.uuidString,
                    hlc: tick(),
                    by: replication.writerID,
                    person: SharedPerson(person: person)
                )
            )
        }
        for sha in catalog.deletedSHA256.sorted() {
            records.append(
                MetaRecord(
                    op: .deletedHash,
                    id: sha,
                    hlc: tick(),
                    by: replication.writerID,
                    sha256: sha
                )
            )
        }
        if !records.isEmpty {
            outbox.append(contentsOf: records)
            persistOutbox()
            do {
                guard try await flush(store: store) else { return }
            } catch {
                return
            }
        }
        replication.seeded = true
        replication.isMigration = false
        sawLog = true
        persist()
    }

    // MARK: - Compaction

    /// Materialises the merged state into a snapshot and points `head` at it.
    /// Any device may do this. A device that loses the head race leaves an
    /// orphan snapshot; because segments are never deleted, correctness does
    /// not depend on the race's outcome.
    func compactIfNeeded(store: MetadataObjectStore, force: Bool = false) async {
        guard !compacting else { return }
        guard replication.segmentsSinceSnapshot >= compactionSegmentThreshold || force else { return }
        guard !state.photos.isEmpty || !state.people.isEmpty else { return }
        compacting = true
        defer { compacting = false }

        // Capture every input before the first await. A sync that lands while
        // the snapshot uploads must not make the head claim coverage for
        // records that are not in the snapshot.
        let snapshotState = state
        let watermark = replication.watermark
        let generation = max(replication.generation, 0) + 1
        let raw = await Task.detached(priority: .utility) {
            snapshotState.encodeSnapshot(generation: generation, watermark: watermark)
        }.value
        guard let compressed = try? await Self.gzipInBackground(raw) else { return }
        let key = MetadataLayout.snapshotKey(
            generation: generation,
            hlc: tick(),
            digest: SigV4Signer.sha256Hex(compressed)
        )
        guard (try? await store.putObject(key, data: compressed, contentType: "application/gzip")) != nil else {
            return
        }

        // If the current head cannot be read, overwriting it is unsafe.
        guard let headResult = try? await store.getObject(MetadataLayout.headKey, ifNoneMatch: nil) else {
            return
        }
        var current: MetadataHead?
        switch headResult {
        case let .found(data, _):
            guard let decoded = try? JSONFile.decoder.decode(MetadataHead.self, from: data) else { return }
            current = decoded
        case .missing:
            current = nil
        case .notModified:
            return
        }
        let dominant = (current?.watermark ?? [:]).allSatisfy { writer, sequence in
            watermark[writer, default: -1] >= sequence
        }
        guard dominant else { return }

        let head = MetadataHead(
            generation: max(current?.generation ?? 0, replication.generation) + 1,
            snapshot: key,
            watermark: watermark,
            updatedAt: Date(),
            device: DeviceInfo.name
        )
        guard let headData = try? JSONFile.encoder().encode(head) else { return }
        guard (try? await store.putObject(
            MetadataLayout.headKey,
            data: headData,
            contentType: "application/json"
        )) != nil else { return }

        replication.generation = head.generation
        replication.snapshotKey = key
        replication.headETag = nil
        replication.segmentsSinceSnapshot = 0
        replication.editsSinceSnapshot = 0
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        try? JSONFile.write(replication, to: AppPaths.metadataStateFile(serverID))
    }

    private func persistOutbox() {
        var output = Data()
        let encoder = JSONFile.encoder()
        for record in outbox {
            if let data = try? encoder.encode(record) {
                output.append(data)
                output.append(0x0A)
            }
        }
        try? output.write(to: AppPaths.metadataOutboxFile(serverID), options: .atomic)
    }

    private static func loadOutbox(_ serverID: UUID) -> [MetaRecord] {
        guard let data = try? Data(contentsOf: AppPaths.metadataOutboxFile(serverID)) else {
            return []
        }
        return MetadataSegmentCodec.decode(data)
    }

    private func loadCache() {
        let url = AppPaths.metadataCacheFile(serverID)
        guard let compressed = try? Data(contentsOf: url),
              let raw = try? Gzip.decompress(compressed),
              let decoded = try? MergedMetadata.decodeSnapshot(raw)
        else { return }
        state = decoded.metadata
        // The cache knows exactly how much it covers. Trust it over the state
        // file, which is written before the asynchronous cache write.
        replication.watermark = decoded.header.watermark
        cacheLoaded = true
    }

    /// A serial queue keeps cache writes in state order; `Task.detached` would
    /// let an older snapshot finish last after two quick syncs.
    private static let cacheQueue = DispatchQueue(
        label: "me.otbeaumont.backu.metadata-cache",
        qos: .utility
    )

    private func persistCache() {
        let snapshot = state
        let generation = replication.generation
        let watermark = replication.watermark
        let url = AppPaths.metadataCacheFile(serverID)
        Self.cacheQueue.async {
            let raw = snapshot.encodeSnapshot(generation: generation, watermark: watermark)
            guard let compressed = try? Gzip.compress(raw) else { return }
            try? compressed.write(to: url, options: .atomic)
        }
    }

    #if DEBUG
    /// Test seam: the cache write is queued, so a test that deletes the file
    /// needs a point where the write has certainly landed.
    func flushCacheForTesting() async {
        await withCheckedContinuation { continuation in
            Self.cacheQueue.async { continuation.resume() }
        }
    }
    #endif

    private static func gzipInBackground(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .utility) { try Gzip.compress(data) }.value
    }

    private static func gunzipInBackground(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .utility) { try Gzip.decompress(data) }.value
    }
}

// MARK: - Field comparison

extension SharedPhoto {
    func matches(_ other: SharedPhoto, field: Field) -> Bool {
        switch field {
        case .filename: return filename == other.filename
        case .takenAt: return takenAt == other.takenAt
        case .addedAt: return addedAt == other.addedAt
        case .modifiedAt: return modifiedAt == other.modifiedAt
        case .isVideo: return isVideo == other.isVideo
        case .isFavorite: return isFavorite == other.isFavorite
        case .pixelWidth: return pixelWidth == other.pixelWidth
        case .pixelHeight: return pixelHeight == other.pixelHeight
        case .duration: return duration == other.duration
        case .metadata: return metadata == other.metadata
        case .copies: return copies == other.copies
        }
    }
}

extension SharedPerson {
    func matches(_ other: SharedPerson, field: Field) -> Bool {
        switch field {
        case .name: return name == other.name
        case .isPet: return isPet == other.isPet
        case .coverPhotoID: return coverPhotoID == other.coverPhotoID
        case .coverFaceID: return coverFaceID == other.coverFaceID
        case .isHidden: return isHidden == other.isHidden
        }
    }
}
