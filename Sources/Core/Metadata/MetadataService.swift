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
    var lastGarbageCollection: Date?

    private enum CodingKeys: String, CodingKey {
        case writerID, sequence, headETag, generation, snapshotKey, headSnapshot, watermark
        case lastSyncAt, lastHLC, segmentsSinceSnapshot, editsSinceSnapshot
        case isMigration, seeded, seedLastID, seedPendingLastID, lastGarbageCollection
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
        lastGarbageCollection = try container.decodeIfPresent(Date.self, forKey: .lastGarbageCollection)
    }
}

struct MetadataSyncOutcome: Sendable {
    var hasHead: Bool = false
    /// True when this bucket already has v2 data (a head, snapshot or segment).
    var sawLog: Bool = false
    var changed: Bool = false
    /// True when `photos` is every photo in the bucket (cold start, or a first
    /// sync of a bucket whose log is only segments). Only then may a reader
    /// reconcile photos that are absent from the list.
    var isFull: Bool = false
    /// The changed photos for an incremental sync, or all photos for a full one.
    var photos: [PhotoItem] = []
    var people: [Person] = []
    var deletedPeople: Set<UUID> = []
    var deletedHashes: Set<String> = []
    /// Merged entity ids that no longer exist. Filled for incremental syncs so a
    /// reader can drop exactly those catalog entries.
    var removedPhotoIDs: Set<String> = []
}

/// When compaction is worth a whole-snapshot upload. Segment count alone makes
/// a 100k library rewrite 13 MB after eight trivial edits; the edit count keeps
/// a busy but short-lived log from growing without bound.
struct MetadataCompactionPolicy: Sendable {
    var segmentThreshold: Int = 32
    var editThreshold: Int = 20_000
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
    let compaction: MetadataCompactionPolicy

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

    /// Merged records not yet folded into the local cache file. Rewriting 13 MB
    /// after every 7 KB edit is the cache's whole cost, so it is only written
    /// when this reaches `cacheRecordThreshold`, on a snapshot change, or when
    /// the app asks (background/termination).
    private var pendingCacheRecords = 0
    private var cacheNeedsWrite = false
    private var lastCachePersist = Date.distantPast
    /// Exposed so a test can exercise the threshold without building thousands
    /// of records. Production keeps the default.
    var cacheRecordThreshold = 2_000
    /// A long session with sporadic edits still refreshes the cache eventually.
    var cacheMaximumInterval: TimeInterval = 300
    /// How many cache writes have been started. Read by tests; a counter is
    /// cheaper than exposing the queue.
    private(set) var cacheWriteCount = 0

    init(
        serverID: UUID,
        writerID: String? = nil,
        compaction: MetadataCompactionPolicy = MetadataCompactionPolicy()
    ) {
        self.serverID = serverID
        self.compaction = compaction
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

        // Captured before anything is applied: a first sync of a bucket whose
        // log is only segments starts from an empty state, so materialising the
        // changed ids is the same as materialising everything.
        let startedEmpty = state.isEmpty

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

        if let head { replication.headSnapshot = head.snapshot }
        var changed = false
        var snapshotLoaded = false
        let headSnapshot = head?.snapshot ?? replication.headSnapshot
        let needsSnapshot = headSnapshot != replication.snapshotKey
            || (!cacheLoaded && replication.snapshotKey != nil)
        if needsSnapshot, let snapshotKey = headSnapshot ?? replication.snapshotKey {
            // The snapshot is the one object big enough to matter: stream it to
            // a temporary file and decode the JSONL incrementally, so peak
            // memory is the merged state rather than the state plus 60 MB of
            // JSON text.
            let decoded = try await Self.loadSnapshot(snapshotKey, from: store)
            state = decoded.metadata
            replication.snapshotKey = snapshotKey
            replication.headSnapshot = snapshotKey
            replication.generation = max(decoded.header.generation, head?.generation ?? 0)
            // The snapshot's own watermark is authority: the state file may
            // have advanced past a cache write that never landed.
            replication.watermark = decoded.header.watermark
            replication.segmentsSinceSnapshot = 0
            replication.editsSinceSnapshot = 0
            cacheLoaded = true
            changed = true
            snapshotLoaded = true
        }

        // A 304 only skips the head *body*; segments still have to be listed or
        // edits made since the last compaction never arrive.
        let listing = try await pendingSegments(store: store)
        if !probedSequence {
            probedSequence = true
            adoptSequence(from: listing.maxSequences)
        }
        let segments = listing.pending
        var changes = MetadataChangeSet()
        var appliedRecords = 0
        if !segments.isEmpty {
            let downloaded = try await download(segments: segments, store: store)
            var records: [MetaRecord] = []
            for item in downloaded {
                records.append(contentsOf: item.records)
                replication.watermark[item.writer] = max(
                    replication.watermark[item.writer] ?? -1,
                    item.sequence
                )
                // Our own segments were already counted when they were written;
                // counting them again here would compact twice as eagerly as
                // the configured policy says.
                if item.writer != replication.writerID {
                    replication.segmentsSinceSnapshot += 1
                }
            }
            changes = state.apply(records)
            appliedRecords = records.count
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

        guard changed else {
            return MetadataSyncOutcome(hasHead: hasHead, sawLog: sawLog, changed: false)
        }

        // Materialise only what moved. A snapshot load replaces the whole state
        // and a first sync starts from nothing, so both are a full read.
        let outcome: MetadataSyncOutcome
        if snapshotLoaded || startedEmpty {
            let materialized = state.materialize(serverID: serverID)
            outcome = MetadataSyncOutcome(
                hasHead: hasHead,
                sawLog: sawLog,
                changed: true,
                isFull: true,
                photos: materialized.photos,
                people: materialized.people,
                deletedPeople: materialized.deletedPeople,
                deletedHashes: materialized.deletedHashes
            )
        } else {
            let delta = state.materialize(serverID: serverID, changes: changes)
            outcome = MetadataSyncOutcome(
                hasHead: hasHead,
                sawLog: sawLog,
                changed: true,
                isFull: false,
                photos: delta.photos,
                people: delta.people,
                deletedPeople: delta.deletedPeople,
                deletedHashes: changes.deletedHashes,
                removedPhotoIDs: delta.removedPhotoIDs
            )
        }

        noteCacheChanges(records: appliedRecords, snapshot: snapshotLoaded)
        return outcome
    }

    private static func loadSnapshot(
        _ key: String,
        from store: MetadataObjectStore
    ) async throws -> MergedMetadata.DecodedSnapshot {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backu-metadata-\(UUID().uuidString).jsonl.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        switch try await store.downloadObject(key, to: url) {
        case .missing: throw MetadataError.missingObject(key)
        case .notModified: throw MetadataError.invalidSnapshot
        case .downloaded: break
        }
        // Parsing a 100k-photo snapshot is hundreds of milliseconds; keep it off
        // the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try MergedMetadata.decodeSnapshot(gzipFile: url)
        }.value
    }

    private struct PendingSegment {
        var key: String
        var writer: String
        var sequence: Int
    }

    private struct SegmentListing {
        var pending: [PendingSegment] = []
        /// writer id -> highest sequence seen, used to recover a lost counter.
        var maxSequences: [String: Int] = [:]
    }

    /// Lists writer namespaces with one delimiter request, then one
    /// `start-after` list per writer. This avoids walking the whole history on
    /// every sync, which is what makes steady-state replication cheap.
    ///
    /// The same listing recovers a lost sequence counter, so a state-file loss
    /// costs no extra request.
    private func pendingSegments(store: MetadataObjectStore) async throws -> SegmentListing {
        let logPrefix = MetadataLayout.logPrefix + "/"
        var writers = Set<String>()
        var listing = SegmentListing()
        var token: String?
        // A state file that vanished (server removed and re-added) hides the
        // counter this writer used. Ask for the whole namespace once so the
        // highest sequence is in the answer.
        let probeSelf = replication.sequence == 0 && !stateFileExisted

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
                listing.maxSequences[parsed.writer] = max(
                    listing.maxSequences[parsed.writer] ?? -1,
                    parsed.sequence
                )
                if parsed.sequence > (replication.watermark[parsed.writer] ?? -1) {
                    listing.pending.append(
                        PendingSegment(key: key, writer: parsed.writer, sequence: parsed.sequence)
                    )
                }
            }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil

        // A delimiter-aware store gives no keys above, so ask each writer only
        // for what is new. `start-after` on a zero-padded sequence is the first
        // unseen segment without walking the writer's history.
        if listing.pending.isEmpty {
            for writer in writers {
                let prefix = MetadataLayout.writerPrefix(writer)
                let startSequence = (replication.watermark[writer] ?? -1) + 1
                var startAfter: String? = (probeSelf && writer == replication.writerID)
                    ? nil
                    : String(format: "%@/%012d", prefix, startSequence)
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
                              parsed.writer == writer
                        else { continue }
                        listing.maxSequences[writer] = max(
                            listing.maxSequences[writer] ?? -1,
                            parsed.sequence
                        )
                        guard parsed.sequence > (replication.watermark[writer] ?? -1) else { continue }
                        listing.pending.append(
                            PendingSegment(key: key, writer: writer, sequence: parsed.sequence)
                        )
                    }
                    continuation = page.isTruncated ? page.nextToken : nil
                    startAfter = nil
                } while continuation != nil
            }
        }

        listing.pending.sort { lhs, rhs in
            lhs.sequence == rhs.sequence ? lhs.writer < rhs.writer : lhs.sequence < rhs.sequence
        }
        return listing
    }

    /// A removed-and-re-added server loses its state file, including the
    /// sequence counter. Reusing sequence 0 would make every existing reader
    /// ignore the new segments forever, so take the highest sequence from the
    /// listing we already fetched.
    private func adoptSequence(from maxSequences: [String: Int]) {
        guard replication.sequence == 0, !stateFileExisted else { return }
        guard let maxSequence = maxSequences[replication.writerID], maxSequence >= 0 else { return }
        replication.sequence = maxSequence + 1
        persist()
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

    /// Publishes the outbox in one PUT per chunk, up to four chunks in flight.
    /// A failed PUT leaves its records in the outbox; retrying reuses the same
    /// key and bytes when the chunks before it landed, so a lost response
    /// cannot duplicate a segment.
    ///
    /// Returns false when another flush is already running; the outbox is still
    /// intact and the caller should retry rather than assume success.
    @discardableResult
    func flush(store: MetadataObjectStore) async throws -> Bool {
        guard !outbox.isEmpty else { return true }
        guard !flushing else { return false }
        flushing = true
        defer { flushing = false }

        let chunkSize = Self.segmentRecordLimit
        let concurrency = 4
        while !outbox.isEmpty {
            let base = replication.sequence
            let writer = replication.writerID
            let count = outbox.count
            let chunkCount = min(concurrency, (count + chunkSize - 1) / chunkSize)
            let chunks = (0..<chunkCount).map { index in
                Array(outbox[index * chunkSize..<min((index + 1) * chunkSize, count)])
            }

            // Encode and compress off the main actor while the PUTs run.
            let prepared = try await withThrowingTaskGroup(
                of: (index: Int, key: String, data: Data).self
            ) { group in
                for (index, chunk) in chunks.enumerated() {
                    let sequence = base + index
                    group.addTask {
                        let raw = try MetadataSegmentCodec.encode(chunk)
                        let compressed = try Gzip.compress(raw)
                        let hlc = chunk.map(\.hlc).max() ?? 0
                        let key = MetadataLayout.segmentKey(
                            writer: writer,
                            sequence: sequence,
                            hlc: hlc,
                            digest: SigV4Signer.sha256Hex(compressed)
                        )
                        return (index, key, compressed)
                    }
                }
                var output: [(index: Int, key: String, data: Data)] = []
                for try await value in group { output.append(value) }
                return output.sorted { $0.index < $1.index }
            }

            let outcome = await withTaskGroup(of: (Int, String?).self) { group in
                for item in prepared {
                    group.addTask {
                        do {
                            try await store.putObject(
                                item.key,
                                data: item.data,
                                contentType: "application/gzip"
                            )
                            return (item.index, nil)
                        } catch {
                            return (item.index, String(describing: error))
                        }
                    }
                }
                var results: [Int: String?] = [:]
                for await (index, failure) in group { results[index] = failure }
                return results
            }

            // Remove only the contiguous uploaded prefix. A gap keeps the later
            // chunks in the outbox so a retry cannot skip records; re-sending
            // them under a fresh sequence is harmless because records are
            // idempotent, and with no gap every retry reuses the exact key.
            var advanced = 0
            for index in 0..<chunks.count {
                guard let failure = outcome[index], failure == nil else { break }
                advanced += 1
            }
            if advanced > 0 {
                let removed = chunks.prefix(advanced).reduce(0) { $0 + $1.count }
                outbox.removeFirst(removed)
                replication.sequence = base + advanced
                replication.segmentsSinceSnapshot += advanced
                replication.editsSinceSnapshot += removed
                persistOutbox()
                persist()
            }
            if advanced < chunks.count {
                let failure = outcome[advanced].flatMap { $0 }
                throw MetadataError.uploadFailed(failure ?? "upload failed")
            }
        }
        return true
    }

    /// Records per segment. A segment is the unit readers fetch and gzip, so it
    /// stays small enough to be cheap to replay.
    static let segmentRecordLimit = 500

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

        // Queue several batches before flushing so the writer can keep four
        // PUTs in flight. Every queued record is in the outbox *before*
        // `seedPendingLastID` advances past it, so a crash mid-flush still
        // resumes at a record that was actually published.
        let batchSize = Self.segmentRecordLimit
        let batchesPerFlush = 4
        while cursor < photos.count {
            var lastID: String?
            var queued = 0
            var batches = 0
            while cursor < photos.count && batches < batchesPerFlush {
                let upper = min(cursor + batchSize, photos.count)
                var records: [MetaRecord] = []
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
                queued += records.count
                batches += 1
            }
            guard queued > 0 else { continue }
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
        // A snapshot is a 13 MB upload for a 100k library, so segment count
        // alone is a bad trigger: eight trivial edits would rewrite everything.
        // Compact on whichever threshold is reached first.
        let due = replication.segmentsSinceSnapshot >= compaction.segmentThreshold
            || replication.editsSinceSnapshot >= compaction.editThreshold
        guard due || force else { return }
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

        // A compacted snapshot makes every covered segment redundant for
        // readers (they start from the head snapshot). Keep a retention window
        // for in-flight syncs, then collect at most once a day.
        let gcDue = replication.lastGarbageCollection
            .map { Date().timeIntervalSince($0) > 86_400 } ?? true
        if gcDue {
            await collectGarbage(store: store)
        }
    }

    /// Deletes segments covered by the current head snapshot and older than
    /// `retention`, plus superseded snapshots. Only the head snapshot is
    /// authoritative; a reader always fetches it before any segment, so covered
    /// segments are never needed for correctness. The retention window avoids
    /// breaking a sync that listed a segment just before it was collected.
    @discardableResult
    func collectGarbage(
        store: MetadataObjectStore,
        retention: TimeInterval = 7 * 24 * 3600,
        now: Date = Date()
    ) async -> Int {
        guard let headResult = try? await store.getObject(MetadataLayout.headKey, ifNoneMatch: nil),
              case let .found(headData, _) = headResult,
              let head = try? JSONFile.decoder.decode(MetadataHead.self, from: headData),
              let snapshot = head.snapshot
        else { return 0 }
        guard let snapshotResult = try? await store.getObject(snapshot, ifNoneMatch: nil),
              case .found = snapshotResult
        else { return 0 }

        let cutoff = now.addingTimeInterval(-retention)
        var deleted = 0

        var token: String?
        repeat {
            guard let page = try? await store.listObjects(
                prefix: MetadataLayout.logPrefix + "/",
                delimiter: nil,
                startAfter: nil,
                continuationToken: token,
                maxKeys: 1000
            ) else { return deleted }
            for entry in page.entries {
                guard let parsed = MetadataLayout.parseSegment(entry.key),
                      parsed.sequence <= (head.watermark[parsed.writer] ?? -1),
                      let modified = entry.lastModified,
                      modified < cutoff
                else { continue }
                if (try? await store.deleteObject(entry.key)) != nil { deleted += 1 }
            }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil

        var snapshotToken: String?
        repeat {
            guard let page = try? await store.listObjects(
                prefix: MetadataLayout.snapshotPrefix + "/",
                delimiter: nil,
                startAfter: nil,
                continuationToken: snapshotToken,
                maxKeys: 1000
            ) else { return deleted }
            for entry in page.entries where entry.key != snapshot {
                guard let modified = entry.lastModified, modified < cutoff else { continue }
                if (try? await store.deleteObject(entry.key)) != nil { deleted += 1 }
            }
            snapshotToken = page.isTruncated ? page.nextToken : nil
        } while snapshotToken != nil

        replication.lastGarbageCollection = now
        persist()
        return deleted
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
        guard let decoded = try? MergedMetadata.decodeSnapshot(gzipFile: url) else { return }
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

    /// Decide whether this sync is worth a 13 MB local rewrite. A 304 plus one
    /// segment leaves the cache stale, which is safe: the cache's header
    /// watermark is authoritative, so the next launch replays the few records
    /// it missed instead of trusting a head that moved past it.
    private func noteCacheChanges(records: Int, snapshot: Bool) {
        pendingCacheRecords += records
        cacheNeedsWrite = cacheNeedsWrite || snapshot
        let stale = Date().timeIntervalSince(lastCachePersist) > cacheMaximumInterval
        guard cacheNeedsWrite
            || pendingCacheRecords >= cacheRecordThreshold
            || (pendingCacheRecords > 0 && stale)
        else { return }
        persistCache()
    }

    /// Writes any pending merged state now. Called when the app backgrounds so
    /// a long session's cache stays close to the server.
    func flushCacheIfNeeded() {
        guard cacheNeedsWrite || pendingCacheRecords > 0 else { return }
        persistCache()
    }

    private func persistCache() {
        let snapshot = state
        let generation = replication.generation
        let watermark = replication.watermark
        let url = AppPaths.metadataCacheFile(serverID)
        pendingCacheRecords = 0
        cacheNeedsWrite = false
        lastCachePersist = Date()
        cacheWriteCount += 1
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
        flushCacheIfNeeded()
        await withCheckedContinuation { continuation in
            Self.cacheQueue.async { continuation.resume() }
        }
    }
    #endif

    private static func gzipInBackground(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .utility) { try Gzip.compress(data) }.value
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
