import Foundation

/// One object transfer that started and has not been confirmed in the catalog.
/// Written before any bytes are sent so a process death after the upload can be
/// reconciled on the next launch instead of uploading the photo again.
struct UploadRecord: Codable, Hashable, Sendable {
    var photoID: String
    var serverID: UUID
    var objectKey: String
    var sidecarKey: String
    var byteCount: Int64
    var sha256: String?
    var startedAt: Date
}

/// Small on-disk journal of in-flight object uploads.
final class UploadJournal: @unchecked Sendable {
    static let shared = UploadJournal()

    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    let fileURL: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    init(
        fileURL: URL = AppPaths.uploadJournalFile,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    func begin(_ record: UploadRecord) {
        lock.lock()
        var records = loadLocked()
        records.removeAll { $0.photoID == record.photoID && $0.serverID == record.serverID }
        records.append(record)
        saveLocked(records)
        lock.unlock()
    }

    func finish(photoID: String, serverID: UUID) {
        lock.lock()
        var records = loadLocked()
        let before = records.count
        records.removeAll { $0.photoID == photoID && $0.serverID == serverID }
        if records.count != before { saveLocked(records) }
        lock.unlock()
    }

    func finish(_ record: UploadRecord) {
        finish(photoID: record.photoID, serverID: record.serverID)
    }

    func records() -> [UploadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func pending(serverID: UUID) -> [UploadRecord] {
        records().filter { $0.serverID == serverID }
    }

    /// Drops records that can no longer belong to a real transfer. The object is
    /// left in the bucket; it is simply no longer considered pending.
    @discardableResult
    func purgeStale(olderThan age: TimeInterval = UploadJournal.staleAfter) -> Int {
        let deadline = now().addingTimeInterval(-max(0, age))
        lock.lock()
        var records = loadLocked()
        let before = records.count
        records.removeAll { $0.startedAt <= deadline }
        if records.count != before { saveLocked(records) }
        lock.unlock()
        return before - records.count
    }

    func removeAll(serverID: UUID) {
        lock.lock()
        var records = loadLocked()
        records.removeAll { $0.serverID == serverID }
        saveLocked(records)
        lock.unlock()
    }

    // MARK: - Disk

    private func loadLocked() -> [UploadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONFile.decoder.decode([UploadRecord].self, from: data)) ?? []
    }

    private func saveLocked(_ records: [UploadRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONFile.encoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A failed journal write only costs resume fidelity; never fail a
            // transfer because of it.
        }
    }
}

/// Reconciles journaled uploads after a relaunch or a background URLSession
/// event: if the object and sidecar are already in the bucket, the catalog copy
/// is restored without transferring the bytes again.
@MainActor
enum UploadReconciler {
    @discardableResult
    static func reconcile(
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        journal: UploadJournal = .shared,
        progress: (@MainActor (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Int {
        let records = journal.pending(serverID: server.id)
        guard !records.isEmpty else { return 0 }

        var completed = 0
        for record in records {
            if Task.isCancelled { break }
            guard let photo = catalog.photo(id: record.photoID) else {
                journal.finish(record)
                continue
            }
            do {
                guard let head = try await client.headObject(key: record.objectKey) else {
                    // The object may still be in flight; retry this record later.
                    continue
                }
                guard head.size == record.byteCount else { continue }

                let expectedSHA = record.sha256 ?? photo.sha256
                var sha = expectedSHA
                var sidecarFound = false
                if let data = try? await client.getObject(key: record.sidecarKey),
                   let sidecar = try? JSONFile.decoder.decode(SidecarDocument.self, from: data) {
                    if let expectedSHA, sidecar.sha256 != expectedSHA { continue }
                    sha = sidecar.sha256 ?? expectedSHA
                    sidecarFound = true
                }

                if !sidecarFound {
                    // Object is there but the metadata wasn't written. Build it
                    // from the local catalog and finish the upload.
                    let sidecar = SidecarDocument.make(
                        photo: catalog.photo(id: record.photoID) ?? photo,
                        people: Dictionary(catalog.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                        device: DeviceInfo.name,
                        sha256: sha
                    )
                    try await client.putObject(
                        key: record.sidecarKey,
                        data: try sidecar.data(),
                        contentType: "application/json"
                    )
                }

                var thumbKey: String?
                if let sha {
                    let candidate = S3Client.join(server.normalizedPrefix, ".backu/thumbs/\(sha.prefix(20)).jpg")
                    if (try? await client.headObject(key: candidate)) != nil {
                        thumbKey = candidate
                    }
                }
                catalog.recordUpload(
                    copy: PhotoCopy(
                        serverID: server.id,
                        objectKey: record.objectKey,
                        sidecarKey: record.sidecarKey,
                        thumbnailKey: thumbKey,
                        uploadedAt: Date(),
                        byteCount: head.size > 0 ? head.size : record.byteCount,
                        etag: head.etag,
                        sha256: sha
                    ),
                    for: record.photoID
                )
                catalog.mutatePhoto(record.photoID) {
                    $0.sha256 = sha
                    $0.sidecarDirtyAt = nil
                    $0.remoteThumbnailKey = $0.remoteThumbnailKey ?? thumbKey
                }
                journal.finish(record)
                completed += 1
                progress?(completed, records.count)
            } catch {
                // Keep the record; a later run retries the HEAD/sidecar.
                progress?(completed, records.count)
            }
        }
        return completed
    }
}
