import Foundation

// MARK: - Multipart primitives

struct S3MultipartUpload: Sendable, Hashable {
    var key: String
    var uploadId: String
}

struct S3MultipartPart: Sendable, Hashable {
    var number: Int
    var etag: String
    var size: Int64
}

extension S3Client {
    /// POST /key?uploads
    func createMultipartUpload(key: String, contentType: String) async throws -> S3MultipartUpload {
        var request = try makeRequest(
            method: "POST",
            key: key,
            query: [URLQueryItem(name: "uploads", value: "")]
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        guard let uploadID = MultipartResponseParser.uploadID(from: data), !uploadID.isEmpty else {
            throw S3Error.decoding("CreateMultipartUpload returned no UploadId")
        }
        return S3MultipartUpload(key: key, uploadId: uploadID)
    }

    /// PUT /key?partNumber=N&uploadId=…
    func uploadPart(
        upload: S3MultipartUpload,
        partNumber: Int,
        data: Data
    ) async throws -> S3MultipartPart {
        let hash = SigV4Signer.sha256Hex(data)
        let request = try signedUploadPartRequest(
            upload: upload,
            partNumber: partNumber,
            payloadHash: hash
        )
        let (body, response) = try await self.upload(request, data: data)
        try validate(response, data: body)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.decoding("UploadPart returned no ETag")
        }
        return S3MultipartPart(number: partNumber, etag: etag, size: Int64(data.count))
    }

    /// A file-backed part, used by the background uploader. The caller can pass
    /// a hash it already computed while reading the part.
    func uploadPart(
        upload: S3MultipartUpload,
        partNumber: Int,
        fileURL: URL,
        payloadHash: String,
        size: Int64
    ) async throws -> S3MultipartPart {
        let request = try signedUploadPartRequest(
            upload: upload,
            partNumber: partNumber,
            payloadHash: payloadHash
        )
        let (body, response) = try await self.upload(request, fileURL: fileURL)
        try validate(response, data: body)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.decoding("UploadPart returned no ETag")
        }
        return S3MultipartPart(number: partNumber, etag: etag, size: size)
    }

    /// Builds the signed part request for a background `URLSession`.
    func signedUploadPartRequest(
        upload: S3MultipartUpload,
        partNumber: Int,
        payloadHash: String
    ) throws -> URLRequest {
        var request = try makeRequest(
            method: "PUT",
            key: upload.key,
            query: [
                URLQueryItem(name: "partNumber", value: String(partNumber)),
                URLQueryItem(name: "uploadId", value: upload.uploadId)
            ]
        )
        sign(&request, payloadHash: payloadHash)
        return request
    }

    /// POST /key?uploadId=… with the CompleteMultipartUpload document.
    func completeMultipartUpload(
        upload: S3MultipartUpload,
        parts: [S3MultipartPart]
    ) async throws -> String {
        guard parts.count <= 10_000 else {
            throw S3Error.decoding("A multipart upload cannot have more than 10,000 parts")
        }
        let body = MultipartRequest.completeBody(parts: parts)
        var request = try makeRequest(
            method: "POST",
            key: upload.key,
            query: [URLQueryItem(name: "uploadId", value: upload.uploadId)]
        )
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        sign(&request, payloadHash: SigV4Signer.sha256Hex(body))
        let (data, response) = try await self.upload(request, data: body)
        try validate(response, data: data)
        return MultipartResponseParser.etag(from: data) ?? ""
    }

    /// DELETE /key?uploadId=…
    func abortMultipartUpload(upload: S3MultipartUpload) async throws {
        var request = try makeRequest(
            method: "DELETE",
            key: upload.key,
            query: [URLQueryItem(name: "uploadId", value: upload.uploadId)]
        )
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
    }

    /// GET /key?uploadId=… — useful for diagnostics and a future resume path.
    func listParts(upload: S3MultipartUpload) async throws -> [S3MultipartPart] {
        var request = try makeRequest(
            method: "GET",
            key: upload.key,
            query: [URLQueryItem(name: "uploadId", value: upload.uploadId)]
        )
        sign(&request, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, response) = try await perform(request)
        try validate(response, data: data)
        return MultipartResponseParser.parts(from: data)
    }
}

enum MultipartRequest {
    static func completeBody(parts: [S3MultipartPart]) -> Data {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for part in parts.sorted(by: { $0.number < $1.number }) {
            xml += "<Part><PartNumber>\(part.number)</PartNumber>"
            xml += "<ETag>\(xmlEscape(part.etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Response XML

private final class MultipartResponseParser: NSObject, XMLParserDelegate {
    private var uploadID: String?
    private var etag: String?
    private var parts: [S3MultipartPart] = []
    private var currentPart: [String: String] = [:]
    private var inPart = false
    private var text = ""

    static func uploadID(from data: Data) -> String? {
        let parser = MultipartResponseParser()
        parser.parse(data)
        return parser.uploadID
    }

    static func etag(from data: Data) -> String? {
        let parser = MultipartResponseParser()
        parser.parse(data)
        return parser.etag
    }

    static func parts(from data: Data) -> [S3MultipartPart] {
        let parser = MultipartResponseParser()
        parser.parse(data)
        return parser.parts
    }

    private func parse(_ data: Data) {
        let xml = XMLParser(data: data)
        xml.delegate = self
        xml.shouldProcessNamespaces = false
        xml.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        if elementName == "Part" {
            inPart = true
            currentPart = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "UploadId": uploadID = value
        case "ETag":
            etag = value
            if inPart { currentPart["ETag"] = value }
        case "PartNumber", "Size":
            if inPart { currentPart[elementName] = value }
        case "Part":
            if let number = Int(currentPart["PartNumber"] ?? ""), let etag = currentPart["ETag"] {
                parts.append(
                    S3MultipartPart(
                        number: number,
                        etag: etag,
                        size: Int64(currentPart["Size"] ?? "0") ?? 0
                    )
                )
            }
            inPart = false
            currentPart = [:]
        default:
            break
        }
        text = ""
    }
}

// MARK: - Uploader

/// Transport used to move one part. The default talks through `S3Client`; the
/// app injects a background-URLSession transport so multipart uploads keep
/// moving when Backu leaves the foreground.
struct MultipartTransport: Sendable {
    var uploadPart: @Sendable (
        _ upload: S3MultipartUpload,
        _ partNumber: Int,
        _ fileURL: URL,
        _ payloadHash: String,
        _ size: Int64,
        _ progress: MultipartProgressSink
    ) async throws -> S3MultipartPart

    static func direct(client: S3Client) -> MultipartTransport {
        MultipartTransport { upload, number, fileURL, hash, size, progress in
            progress.report(0)
            let part = try await client.uploadPart(
                upload: upload,
                partNumber: number,
                fileURL: fileURL,
                payloadHash: hash,
                size: size
            )
            progress.report(1)
            return part
        }
    }
}

/// A reference-typed progress channel so transports can hand progress to an
/// async URLSession without escaping a non-escaping closure parameter.
final class MultipartProgressSink: @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double) {
        handler(min(max(fraction, 0), 1))
    }
}

/// Splits a large file into S3 parts and uploads a bounded number at once.
/// Parts are read with `FileHandle`, so the whole file never sits in memory.
struct MultipartUploader: Sendable {
    static let defaultThreshold: Int64 = 16 * 1024 * 1024
    static let minimumPartSize: Int64 = 5 * 1024 * 1024
    static let maximumParts = 10_000

    var client: S3Client
    var partSize: Int
    var concurrency: Int
    var threshold: Int64
    var temporaryDirectory: URL?
    var transport: MultipartTransport?
    var progress: (@Sendable (Double) -> Void)?

    init(
        client: S3Client,
        partSize: Int = 8 * 1024 * 1024,
        concurrency: Int = 4,
        threshold: Int64 = MultipartUploader.defaultThreshold,
        temporaryDirectory: URL? = nil,
        transport: MultipartTransport? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.client = client
        self.partSize = max(Int(MultipartUploader.minimumPartSize), partSize)
        self.concurrency = max(1, min(concurrency, 16))
        self.threshold = max(0, threshold)
        self.temporaryDirectory = temporaryDirectory
        self.transport = transport
        self.progress = progress
    }

    /// Returns the streaming SHA-256 of the file, which the sidecar records.
    @discardableResult
    func upload(fileURL: URL, key: String, contentType: String) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        progress?(0)

        if size < threshold || size <= Self.minimumPartSize {
            let (request, hash) = try await client.signedPutFileRequestAsync(
                key: key,
                fileURL: fileURL,
                contentType: contentType
            )
            let (body, response) = try await client.upload(request, fileURL: fileURL)
            try client.validate(response, data: body)
            progress?(1)
            return hash
        }

        // Hash and initiate concurrently: one streaming pass over the file,
        // never `Data(contentsOf:)`.
        let hashTask = Task.detached(priority: .utility) {
            try SigV4Signer.sha256Hex(contentsOfFile: fileURL)
        }

        let effectivePartSize = Self.effectivePartSize(
            size: size,
            requested: partSize
        )
        let partCount = Int((size + effectivePartSize - 1) / effectivePartSize)

        let tempRoot = (temporaryDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("backu-multipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let upload: S3MultipartUpload
        do {
            upload = try await client.createMultipartUpload(key: key, contentType: contentType)
        } catch {
            hashTask.cancel()
            throw error
        }

        do {
            let parts = try await uploadParts(
                upload: upload,
                fileURL: fileURL,
                size: size,
                partSize: effectivePartSize,
                partCount: partCount,
                tempRoot: tempRoot
            )
            if Task.isCancelled { throw CancellationError() }
            guard parts.count == partCount else {
                throw S3Error.decoding("Only \(parts.count) of \(partCount) parts uploaded")
            }
            _ = try await client.completeMultipartUpload(upload: upload, parts: parts)
            let hash = try await hashTask.value
            progress?(1)
            return hash
        } catch {
            await abort(upload)
            hashTask.cancel()
            throw error
        }
    }

    private static func effectivePartSize(size: Int64, requested: Int) -> Int64 {
        var candidate = max(Int64(requested), minimumPartSize)
        if size > candidate * Int64(maximumParts) {
            candidate = (size + Int64(maximumParts) - 1) / Int64(maximumParts)
        }
        return candidate
    }

    private func uploadParts(
        upload: S3MultipartUpload,
        fileURL: URL,
        size: Int64,
        partSize: Int64,
        partCount: Int,
        tempRoot: URL
    ) async throws -> [S3MultipartPart] {
        let tracker = MultipartProgressTracker(total: size, callback: progress)
        let transport = transport ?? .direct(client: client)
        let maxConcurrent = concurrency

        return try await withThrowingTaskGroup(of: S3MultipartPart.self) { group in
            var nextPart = 1
            var inFlight = 0
            var finished: [S3MultipartPart] = []
            finished.reserveCapacity(partCount)

            while nextPart <= partCount || inFlight > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                while inFlight < maxConcurrent, nextPart <= partCount {
                    let number = nextPart
                    nextPart += 1
                    inFlight += 1
                    group.addTask {
                        try await uploadOnePart(
                            upload: upload,
                            number: number,
                            fileURL: fileURL,
                            size: size,
                            partSize: partSize,
                            tempRoot: tempRoot,
                            transport: transport,
                            tracker: tracker
                        )
                    }
                }
                guard let part = try await group.next() else { break }
                inFlight -= 1
                finished.append(part)
            }
            return finished
        }
    }

    private func uploadOnePart(
        upload: S3MultipartUpload,
        number: Int,
        fileURL: URL,
        size: Int64,
        partSize: Int64,
        tempRoot: URL,
        transport: MultipartTransport,
        tracker: MultipartProgressTracker
    ) async throws -> S3MultipartPart {
        if Task.isCancelled { throw CancellationError() }
        let offset = Int64(number - 1) * partSize
        let length = Int(min(partSize, size - offset))
        guard length > 0 else {
            throw S3Error.decoding("Part \(number) has no bytes")
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw S3Error.decoding("Could not read part \(number) from the file")
        }

        let partURL = tempRoot.appendingPathComponent("part-\(number).bin")
        try data.write(to: partURL, options: .atomic)
        let hash = SigV4Signer.sha256Hex(data)
        tracker.started(number: number, size: Int64(length))

        let part = try await transport.uploadPart(
            upload,
            number,
            partURL,
            hash,
            Int64(length),
            MultipartProgressSink { fraction in
                tracker.update(number: number, fraction: fraction)
            }
        )
        try? FileManager.default.removeItem(at: partURL)
        guard part.size == Int64(length) else {
            throw S3Error.decoding("Part \(number) reported the wrong size")
        }
        tracker.finished(number: number, size: Int64(length))
        return part
    }

    private func abort(_ upload: S3MultipartUpload) async {
        let client = self.client
        // An abort must still run when the parent task was cancelled, so give it
        // an unstructured task that does not inherit cancellation.
        await Task.detached(priority: .utility) {
            try? await client.abortMultipartUpload(upload: upload)
        }.value
    }
}

final class MultipartProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let callback: (@Sendable (Double) -> Void)?
    private var completed: Int64 = 0
    private var inFlight: [Int: (size: Int64, fraction: Double)] = [:]
    private var lastEmitted: Double = -1

    init(total: Int64, callback: (@Sendable (Double) -> Void)?) {
        self.total = max(1, total)
        self.callback = callback
    }

    func started(number: Int, size: Int64) {
        lock.lock()
        inFlight[number] = (size, 0)
        lock.unlock()
        emitIfNeeded()
    }

    func update(number: Int, fraction: Double) {
        lock.lock()
        if var entry = inFlight[number] {
            entry.fraction = min(max(fraction, 0), 1)
            inFlight[number] = entry
        }
        lock.unlock()
        emitIfNeeded()
    }

    func finished(number: Int, size: Int64) {
        lock.lock()
        if let entry = inFlight.removeValue(forKey: number) {
            completed += entry.size
        } else {
            completed += size
        }
        lock.unlock()
        emitIfNeeded()
    }

    private func emitIfNeeded() {
        lock.lock()
        var done = completed
        for entry in inFlight.values {
            done += Int64(Double(entry.size) * entry.fraction)
        }
        let value = min(1, max(0, Double(done) / Double(total)))
        let shouldEmit = value - lastEmitted >= 0.002 || value >= 1
        if shouldEmit { lastEmitted = value }
        let callback = self.callback
        lock.unlock()
        if shouldEmit { callback?(value) }
    }
}
