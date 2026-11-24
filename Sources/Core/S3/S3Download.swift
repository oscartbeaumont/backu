import Foundation

/// Downloads a whole object to disk without ever holding it in memory. Small
/// objects use one streaming connection (with resume); large objects fan out
/// into byte ranges sized by `TransferTuning`.
extension S3Client {
    static let parallelDownloadThreshold = TransferPlanner.downloadParallelThreshold
    /// Legacy fixed size, kept for callers that referenced it. Adaptive plans
    /// pick the real value.
    static let downloadPartSize: Int64 = 8 * 1024 * 1024

    /// Downloads `key` to `destination`, replacing it atomically on success.
    ///
    /// `sizeHint` still saves a round trip for small objects, but a hint does
    /// not skip the latency probe for large ones: the app viewer always knows
    /// the byte count from the catalog, and without the probe it would stay on
    /// one stream on every network. A small-object hint skips HEAD, so it cannot
    /// identify an existing partial's object version; hinted downloads restart
    /// instead of resuming.
    func downloadObject(
        key: String,
        to destination: URL,
        sizeHint: Int64? = nil,
        concurrency: Int = 0,
        minimumRoundTripForParallel: TimeInterval = 0.008,
        tuning: TransferTuning = .shared,
        onPlan: (@Sendable (TransferPlan) -> Void)? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let started = Date()
        let hint = sizeHint.flatMap { $0 > 0 ? $0 : nil }
        var sizeIsHint = hint != nil
        var size: Int64 = hint ?? 0
        var roundTrip: TimeInterval?
        var etag: String?
        var supportsRanges = true
        // A hint alone cannot decide whether ranges pay off, so a large object
        // still probes. The probe is served from the short-lived HEAD cache when
        // this object was opened recently, which skips a round trip on every
        // repeated viewer open.
        var needsProbe = hint == nil || size >= Self.parallelDownloadThreshold
        // A 412 means the cached metadata (or a resumed partial file) belongs to
        // an older object version. Re-probe once, fresh, and start over.
        var preconditionRetries = 0

        while true {
            if needsProbe {
                let (head, latency) = try await headObjectForDownload(
                    key: key,
                    useCache: preconditionRetries == 0
                )
                roundTrip = latency
                guard let head else {
                    throw S3Error.http(status: 404, code: "NoSuchKey", message: nil, requestID: nil)
                }
                size = head.size
                sizeIsHint = false
                etag = head.etag
                supportsRanges = head.acceptRanges != false
                needsProbe = false
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            progress?(0)

            if size == 0 {
                try Data().write(to: destination, options: .atomic)
                progress?(1)
                return
            }

            let plan = tuning.plan(
                serverKey: connection.transferTuningKey,
                direction: .download,
                size: size,
                latency: roundTrip,
                minimumLatencyForParallel: minimumRoundTripForParallel,
                concurrencyCap: concurrency > 0 ? concurrency : nil
            )
            onPlan?(plan)

            if plan.parallel, plan.partCount > 1, plan.concurrency > 1, supportsRanges {
                do {
                    try await downloadParallel(
                        key: key,
                        to: destination,
                        size: size,
                        plan: plan,
                        etag: etag,
                        progress: progress
                    )
                    record(tuning, direction: .download, bytes: size, seconds: Date().timeIntervalSince(started), plan: plan)
                    return
                } catch S3DownloadError.rangeUnsupported {
                    // The service ignored Range. Fall back to one stream; any
                    // part files were already cleaned up.
                    supportsRanges = false
                } catch let error as S3Error {
                    if case let .http(status, _, _, _) = error,
                       status == 412,
                       preconditionRetries == 0 {
                        preconditionRetries = 1
                        invalidateCachedHead(key: key)
                        needsProbe = true
                        continue
                    }
                    tuning.penalise(serverKey: connection.transferTuningKey, direction: .download)
                    throw error
                } catch {
                    if !(error is CancellationError) {
                        tuning.penalise(serverKey: connection.transferTuningKey, direction: .download)
                    }
                    throw error
                }
            }

            var single = plan
            single.concurrency = 1
            single.partCount = 1
            single.parallel = false
            single.reason = "single stream"

            // A 412 means the object changed between the HEAD and the GET (or a
            // resumed partial file belongs to an older version). Re-probe once so
            // the viewer gets the current bytes instead of a failure.
            var recovered = preconditionRetries > 0
            while true {
                do {
                    let downloadedSize = try await downloadSingle(
                        key: key,
                        to: destination,
                        size: size,
                        sizeIsHint: sizeIsHint,
                        etag: etag,
                        progress: progress
                    )
                    size = downloadedSize
                    break
                } catch let error as S3Error {
                    guard !recovered,
                          case let .http(status, _, _, _) = error,
                          status == 412 else { throw error }
                    recovered = true
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))
                    invalidateCachedHead(key: key)
                    let (head, latency) = try await headObjectForDownload(key: key, useCache: false)
                    roundTrip = latency
                    guard let head else {
                        throw S3Error.http(status: 404, code: "NoSuchKey", message: nil, requestID: nil)
                    }
                    size = head.size
                    sizeIsHint = false
                    etag = head.etag
                }
            }
            record(tuning, direction: .download, bytes: size, seconds: Date().timeIntervalSince(started), plan: single)
            return
        }
    }

    private func record(
        _ tuning: TransferTuning,
        direction: TransferDirection,
        bytes: Int64,
        seconds: TimeInterval,
        plan: TransferPlan
    ) {
        tuning.record(
            serverKey: connection.transferTuningKey,
            direction: direction,
            bytes: bytes,
            seconds: seconds,
            plan: plan
        )
    }

    // MARK: - Single stream, with resume

    private func downloadSingle(
        key: String,
        to destination: URL,
        size: Int64,
        sizeIsHint: Bool,
        etag: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int64 {
        let partial = destination.appendingPathExtension("part")
        var offset = fileSize(partial)
        // A hint cannot identify a partial's object version, and a full-length
        // partial has no ETag to compare. Fetch the object instead of promoting
        // either one based only on its length.
        if offset >= size || sizeIsHint {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }

        let requestOffset = offset
        let request = { [self] in
            var request = try makeRequest(method: "GET", key: key, query: [])
            if requestOffset > 0 {
                request.setValue("bytes=\(requestOffset)-", forHTTPHeaderField: "Range")
            }
            sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
            if let etag {
                // Signed headers do not include If-Match; S3 accepts unsigned
                // conditional headers and it pins every byte to the version
                // that the HEAD described.
                request.setValue(etag, forHTTPHeaderField: "If-Match")
            }
            return request
        }

        let (temporary, response) = try await downloadWithRetry(makeRequest: request) { written, expected in
            let base = requestOffset
            let total = max(size, base + expected)
            progress?(min(1, Double(base + written) / Double(max(1, total))))
        }

        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else {
            throw S3Error.decoding("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error.http(
                status: http.statusCode,
                code: nil,
                message: nil,
                requestID: http.value(forHTTPHeaderField: "x-amz-request-id")
            )
        }
        if http.statusCode == 200 || requestOffset == 0 {
            // A fresh download: move URLSession's file straight into place,
            // rather than writing the bytes a second time.
            if http.statusCode == 206 {
                try validateContentRange(http, offset: 0, size: size)
            }
            let written = fileSize(temporary)
            guard sizeIsHint || written == size else {
                throw S3Error.decoding("Downloaded \(written) of \(size) bytes")
            }
            try? FileManager.default.removeItem(at: partial)
            try replace(destination: destination, with: temporary)
            progress?(1)
            return written
        }
        guard http.statusCode == 206 else {
            throw S3Error.http(
                status: http.statusCode,
                code: nil,
                message: nil,
                requestID: http.value(forHTTPHeaderField: "x-amz-request-id")
            )
        }
        try validateContentRange(http, offset: requestOffset, size: size)

        try append(temporary, to: partial)
        let written = fileSize(partial)
        guard written == size else {
            throw S3Error.decoding("Downloaded \(written) of \(size) bytes")
        }
        try replace(destination: destination, with: partial)
        progress?(1)
        return size
    }

    // MARK: - Parallel ranges

    private func downloadParallel(
        key: String,
        to destination: URL,
        size: Int64,
        plan: TransferPlan,
        etag: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let maximumRanges = Int(max(1, size / TransferPlanner.minimumDownloadRangeSize))
        let partCount = max(2, min(plan.partCount, maximumRanges))
        let concurrency = max(1, min(plan.concurrency, partCount))
        let base = size / Int64(partCount)
        let tempRoot = destination.deletingLastPathComponent()
            .appendingPathComponent(".backu-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tracker = DownloadProgressTracker(total: size, callback: progress)
        let ranges: [(index: Int, start: Int64, end: Int64)] = (0..<partCount).map { index in
            let start = Int64(index) * base
            let end = index == partCount - 1 ? size - 1 : start + base - 1
            return (index, start, end)
        }

        // Assembled inside the per-download directory, so a crash or failure
        // can never leave a full-length `.part` that the single-stream resume
        // path would mistake for a complete download. The final move into place
        // is still atomic.
        let assembled = tempRoot.appendingPathComponent("assembled.bin")
        FileManager.default.createFile(atPath: assembled.path, contents: nil)
        let output = try FileHandle(forWritingTo: assembled)
        // Pre-size once so every range can be written at its own offset with
        // `pwrite`; the kernel allocates blocks as they arrive.
        do {
            try output.truncate(atOffset: UInt64(size))
        } catch {
            try? output.close()
            throw error
        }
        let descriptor = output.fileDescriptor

        do {
            try await withThrowingTaskGroup(of: (Int, URL, Int64, Int64).self) { group in
                var next = 0
                var inFlight = 0
                while next < ranges.count || inFlight > 0 {
                    if Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    while inFlight < concurrency, next < ranges.count {
                        let range = ranges[next]
                        next += 1
                        inFlight += 1
                        group.addTask {
                            let length = range.end - range.start + 1
                            let url = try await downloadRange(
                                key: key,
                                start: range.start,
                                end: range.end,
                                size: size,
                                etag: etag,
                                tracker: tracker,
                                index: range.index,
                                temporaryDirectory: tempRoot
                            )
                            return (range.index, url, range.start, length)
                        }
                    }
                    guard let (index, url, start, length) = try await group.next() else { break }
                    inFlight -= 1
                    guard length == fileSize(url) else {
                        try? FileManager.default.removeItem(at: url)
                        throw S3Error.decoding("Range \(index) downloaded the wrong number of bytes")
                    }
                    // Copy the finished range straight into its slot while the
                    // remaining ranges are still on the wire, instead of a
                    // sequential concatenation pass after everything finished.
                    try writeRange(of: url, into: descriptor, at: start)
                    try? FileManager.default.removeItem(at: url)
                    tracker.finished(index: index, length: length)
                }
            }
        } catch {
            try? output.close()
            if error is CancellationError, !Task.isCancelled {
                // A sibling range hit a service that ignores Range and the
                // group cancelled the rest; fall back to a single stream.
                throw S3DownloadError.rangeUnsupported
            }
            throw error
        }
        try output.close()

        let written = fileSize(assembled)
        guard written == size else {
            try? FileManager.default.removeItem(at: assembled)
            throw S3Error.decoding("Assembled \(written) of \(size) bytes")
        }
        try replace(destination: destination, with: assembled)
        progress?(1)
    }

    private func downloadRange(
        key: String,
        start: Int64,
        end: Int64,
        size: Int64,
        etag: String?,
        tracker: DownloadProgressTracker,
        index: Int,
        temporaryDirectory: URL
    ) async throws -> URL {
        let request = { [self] in
            var request = try makeRequest(method: "GET", key: key, query: [])
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
            if let etag {
                // Every range must describe the same object version the HEAD
                // did; otherwise a concurrent overwrite could interleave bytes.
                request.setValue(etag, forHTTPHeaderField: "If-Match")
            }
            return request
        }
        let length = end - start + 1
        tracker.started(index: index, length: length)
        let (temporary, response) = try await downloadWithRetry(
            makeRequest: request,
            temporaryDirectory: temporaryDirectory
        ) { written, _ in
            tracker.update(index: index, written: written)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw S3Error.decoding("No HTTP response")
        }
        guard http.statusCode == 206 else {
            try? FileManager.default.removeItem(at: temporary)
            if http.statusCode == 200 {
                throw S3DownloadError.rangeUnsupported
            }
            throw S3Error.http(
                status: http.statusCode,
                code: nil,
                message: nil,
                requestID: http.value(forHTTPHeaderField: "x-amz-request-id")
            )
        }
        do {
            try validateContentRange(http, offset: start, size: size, expectedEnd: end)
            let written = fileSize(temporary)
            guard written == length else {
                throw S3Error.decoding("Range \(start)-\(end) returned \(written) bytes")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return temporary
    }

    // MARK: - Retrying download task

    private func downloadWithRetry(
        makeRequest: () throws -> URLRequest,
        temporaryDirectory: URL? = nil,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        // A range is one request among many; a longer budget keeps one unlucky
        // response from failing the whole object.
        let policy = S3RetryPolicy.parallelTransfer
        var attempt = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            let delegate = S3DownloadDelegate(
                temporaryDirectory: temporaryDirectory,
                progress: progress
            )
            metrics?.recordRequest()
            do {
                let (returned, response) = try await session.download(for: try makeRequest(), delegate: delegate)
                let http = response as? HTTPURLResponse
                if let http, S3RetryPolicy.isRetryable(status: http.statusCode),
                   attempt + 1 < policy.maxAttempts {
                    delegate.discard()
                    attempt += 1
                    metrics?.recordRetryableResponse()
                    metrics?.recordRetry()
                    try await policy.sleepBeforeRetry(
                        attempt: attempt,
                        retryAfter: S3RetryHeaders.retryAfter(http)
                    )
                    continue
                }
                return (delegate.finishedURL ?? returned, response)
            } catch is CancellationError {
                delegate.discard()
                throw CancellationError()
            } catch {
                delegate.discard()
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                metrics?.recordTransportFailure()
                guard attempt + 1 < policy.maxAttempts,
                      S3RetryPolicy.isRetryable(error: error) else {
                    throw error is S3Error ? error : S3Error.transport(error)
                }
                attempt += 1
                metrics?.recordRetry()
                try await policy.sleepBeforeRetry(attempt: attempt, retryAfter: nil)
            }
        }
    }

    // MARK: - Helpers

    private func validateContentRange(
        _ response: HTTPURLResponse,
        offset: Int64,
        size: Int64,
        expectedEnd: Int64? = nil
    ) throws {
        guard let raw = response.value(forHTTPHeaderField: "Content-Range") else {
            throw S3Error.decoding("Range response has no Content-Range")
        }
        // bytes START-END/TOTAL
        let pieces = raw.split(separator: " ")
        guard pieces.count == 2, pieces[0] == "bytes" else {
            throw S3Error.decoding("Unexpected Content-Range: \(raw)")
        }
        let numbers = pieces[1].split(separator: "/")
        guard numbers.count == 2, let total = Int64(numbers[1]) else {
            throw S3Error.decoding("Unexpected Content-Range: \(raw)")
        }
        let bounds = numbers[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else {
            throw S3Error.decoding("Unexpected Content-Range: \(raw)")
        }
        guard total == size, start == offset, end >= start else {
            throw S3Error.decoding("Content-Range \(raw) does not match the request")
        }
        if let expectedEnd, end != expectedEnd {
            throw S3Error.decoding("Content-Range \(raw) ended at the wrong byte")
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let expected = Int64(length), expected != end - start + 1 {
            throw S3Error.decoding("Content-Length does not match Content-Range")
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Copies `source` into the already-open destination at `offset`. `pwrite`
    /// makes concurrent callers safe for distinct offsets and needs no shared
    /// seek position or lock.
    private func writeRange(of source: URL, into descriptor: Int32, at offset: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var position = offset
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                var written = 0
                while written < buffer.count {
                    let result = pwrite(
                        descriptor,
                        base.advanced(by: written),
                        buffer.count - written,
                        off_t(position) + off_t(written)
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += result
                }
            }
            position += Int64(chunk.count)
        }
    }

    private func append(_ source: URL, to destination: URL) throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
    }

    private func replace(destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// A single streaming GET written straight to `destination`. No HEAD probe
    /// and no in-memory body: the metadata journal reads a snapshot once, and a
    /// probe would only add a round trip to a body it is about to read whole.
}

enum S3DownloadError: Error {
    case rangeUnsupported
}

private final class S3DownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    private let temporaryDirectory: URL?
    private let lock = NSLock()
    private var finished: URL?

    init(temporaryDirectory: URL?, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.temporaryDirectory = temporaryDirectory
        self.progress = progress
    }

    var finishedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func discard() {
        lock.lock()
        let url = finished
        finished = nil
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the file out of URLSession's scratch space before this delegate
        // method returns; the async download call's URL may be reused.
        let directory = temporaryDirectory ?? location.deletingLastPathComponent()
        let target = directory.appendingPathComponent("backu-download-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            try? FileManager.default.copyItem(at: location, to: target)
        }
        lock.lock()
        finished = target
        lock.unlock()
    }
}

private final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let callback: (@Sendable (Double) -> Void)?
    private var completed: Int64 = 0
    private var inFlight: [Int: (length: Int64, written: Int64)] = [:]
    private var lastEmitted: Double = -1

    init(total: Int64, callback: (@Sendable (Double) -> Void)?) {
        self.total = max(1, total)
        self.callback = callback
    }

    func started(index: Int, length: Int64) {
        lock.lock()
        inFlight[index] = (length, 0)
        lock.unlock()
        emitIfNeeded()
    }

    func update(index: Int, written: Int64) {
        lock.lock()
        if var entry = inFlight[index] {
            entry.written = min(max(written, 0), entry.length)
            inFlight[index] = entry
        }
        lock.unlock()
        emitIfNeeded()
    }

    func finished(index: Int, length: Int64) {
        lock.lock()
        if let entry = inFlight.removeValue(forKey: index) {
            completed += entry.length
        } else {
            completed += length
        }
        lock.unlock()
        emitIfNeeded()
    }

    private func emitIfNeeded() {
        lock.lock()
        var done = completed
        for entry in inFlight.values { done += entry.written }
        let value = min(1, max(0, Double(done) / Double(total)))
        let shouldEmit = value - lastEmitted >= 0.002 || value >= 1
        if shouldEmit { lastEmitted = value }
        let callback = self.callback
        lock.unlock()
        if shouldEmit { callback?(value) }
    }
}
