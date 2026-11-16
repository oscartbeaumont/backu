import Foundation

/// One multipart upload that was started and not yet completed or aborted.
struct MultipartUploadRecord: Codable, Equatable, Sendable {
    var key: String
    var uploadId: String
    /// Endpoint + bucket, matching `S3Connection.transferTuningKey`, so a
    /// recovery pass only aborts uploads that belong to the server it is
    /// connected to.
    var serverKey: String
    var createdAt: Date
}

/// A small on-disk journal of in-flight multipart uploads.
///
/// `CreateMultipartUpload` is the one request that cannot be retried safely when
/// its response is lost: retrying creates a second upload, and a crash between
/// create and complete leaves the server holding parts nobody will finish. The
/// journal is written *before* the first part is uploaded and cleared on
/// complete or abort, so `MultipartUploadRecovery` can abort what a previous
/// launch left behind.
///
/// A journal cannot cover the case where the create response never arrived (no
/// id was ever learned). The documented backstop for those is a bucket lifecycle
/// rule:
///
///     <Rule>
///       <ID>abort-incomplete-multipart</ID>
///       <Filter><Prefix></Prefix></Filter>
///       <Status>Enabled</Status>
///       <AbortIncompleteMultipartUpload>
///         <DaysAfterInitiation>1</DaysAfterInitiation>
///       </AbortIncompleteMultipartUpload>
///     </Rule>
final class MultipartUploadJournal: @unchecked Sendable {
    static let shared = MultipartUploadJournal(fileURL: MultipartUploadJournal.defaultFileURL)

    /// Older than this and a recorded upload is presumed orphaned. A day is
    /// long enough that a legitimately paused background upload is not killed,
    /// and matches the lifecycle rule above.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Application Support/Backu/multipart-uploads.json. Resolved here rather
    /// than through `AppPaths` so the S3 layer stays independent of app storage.
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Backu", isDirectory: true)
            .appendingPathComponent("multipart-uploads.json")
    }

    let fileURL: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Records an upload id before any part is sent. Failure to persist is not
    /// fatal: the upload can still complete, it just loses crash recovery.
    func begin(key: String, uploadId: String, serverKey: String) {
        lock.lock()
        var records = loadLocked()
        records.removeAll { $0.uploadId == uploadId }
        records.append(
            MultipartUploadRecord(
                key: key,
                uploadId: uploadId,
                serverKey: serverKey,
                createdAt: now()
            )
        )
        saveLocked(records)
        lock.unlock()
    }

    /// Called once the upload is complete or has been aborted successfully.
    func finish(uploadId: String) {
        lock.lock()
        var records = loadLocked()
        let before = records.count
        records.removeAll { $0.uploadId == uploadId }
        if records.count != before {
            saveLocked(records)
        }
        lock.unlock()
    }

    func records() -> [MultipartUploadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func staleRecords(serverKey: String, olderThan age: TimeInterval = MultipartUploadJournal.staleAfter) -> [MultipartUploadRecord] {
        let deadline = now().addingTimeInterval(-max(0, age))
        return records().filter { $0.serverKey == serverKey && $0.createdAt <= deadline }
    }

    /// Drops records for a server without contacting it, used when the server is
    /// removed from the app.
    func removeAll(serverKey: String) {
        lock.lock()
        var records = loadLocked()
        records.removeAll { $0.serverKey == serverKey }
        saveLocked(records)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        saveLocked([])
        lock.unlock()
    }

    private func loadLocked() -> [MultipartUploadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MultipartUploadRecord].self, from: data)) ?? []
    }

    private func saveLocked(_ records: [MultipartUploadRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Losing the journal only costs crash recovery; never fail an upload
            // because a diagnostic file could not be written.
        }
    }
}

extension S3Client {
    /// Aborts multipart uploads this app started for this server more than
    /// `olderThan` ago, then forgets them. A NoSuchUpload response means the
    /// server already cleaned up, so the record is dropped either way.
    ///
    /// This deliberately does not call ListMultipartUploads: the mock (and some
    /// S3-compatible services) do not implement it, so the journal is the
    /// source of truth and the bucket lifecycle rule is the backstop.
    @discardableResult
    func abortStaleMultipartUploads(
        journal: MultipartUploadJournal = .shared,
        olderThan age: TimeInterval = MultipartUploadJournal.staleAfter
    ) async -> Int {
        let serverKey = connection.transferTuningKey
        let stale = journal.staleRecords(serverKey: serverKey, olderThan: age)
        guard !stale.isEmpty else { return 0 }
        var aborted = 0
        for record in stale {
            if Task.isCancelled { break }
            let upload = S3MultipartUpload(key: record.key, uploadId: record.uploadId)
            do {
                try await abortMultipartUpload(upload: upload)
                aborted += 1
            } catch let error as S3Error {
                // NoSuchUpload: the lifecycle rule or a previous recovery already
                // removed it, so forget the record too. Any other failure keeps
                // it for the next pass.
                guard case let .http(status, _, _, _) = error, status == 404 else { continue }
            } catch {
                continue
            }
            journal.finish(uploadId: record.uploadId)
        }
        return aborted
    }
}
