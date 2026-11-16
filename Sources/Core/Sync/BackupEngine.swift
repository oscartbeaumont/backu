import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

/// Copies a bucket's index back into the app so photos uploaded on another
/// device can be browsed and searched locally.
enum RemoteLibrary {
    struct Result: Sendable {
        var photos: [PhotoItem]
        var people: [Person]
        var indexFound: Bool
    }

    static let indexKey = ".backu/index.json"

    static func load(client: S3Client, server: ServerConfig, knownPeople: [Person] = []) async throws -> Result {
        let prefix = server.normalizedPrefix
        let clientIndexKey = S3Client.join(prefix, indexKey)

        if let data = try? await client.getObject(key: clientIndexKey),
           let document = try? JSONFile.decoder.decode(RemoteIndexDocument.self, from: data) {
            let items = document.photoItems(serverID: server.id)
            var people = knownPeople
            let knownIDs = Set(people.map(\.id))
            for person in document.personRecords where !knownIDs.contains(person.id) {
                people.append(person)
            }
            return Result(photos: items, people: people, indexFound: true)
        }

        // No index yet: fall back to reading sidecars so a bucket produced by an
        // older install still opens.
        let objects = try await client.listAllObjects(prefix: S3Client.join(prefix, "Photos/"))
        let sidecars = objects.filter { $0.key.hasSuffix(".json") }
        var photos: [PhotoItem] = []
        var peopleByID: [UUID: Person] = [:]

        for sidecar in sidecars.prefix(500) {
            guard let data = try? await client.getObject(key: sidecar.key),
                  let doc = try? JSONFile.decoder.decode(SidecarDocument.self, from: data) else { continue }
            var metadata = PhotoMetadata()
            metadata.cameraMake = doc.camera.make
            metadata.cameraModel = doc.camera.model
            metadata.lensModel = doc.camera.lens
            metadata.iso = doc.camera.iso
            metadata.fNumber = doc.camera.aperture
            metadata.exposureTime = doc.camera.shutterSpeed
            metadata.focalLength = doc.camera.focalLength
            metadata.placeName = doc.location?.place
            metadata.latitude = doc.location?.latitude
            metadata.longitude = doc.location?.longitude
            metadata.altitude = doc.location?.altitude

            for person in doc.people {
                if peopleByID[person.id] == nil {
                    peopleByID[person.id] = Person(id: person.id, name: person.name, isPet: person.isPet)
                }
            }

            let objectKey = String(sidecar.key.dropLast(5))
            let copy = PhotoCopy(
                serverID: server.id,
                objectKey: objectKey,
                sidecarKey: sidecar.key,
                thumbnailKey: nil,
                uploadedAt: doc.backedUpAt,
                byteCount: 0,
                etag: nil,
                sha256: doc.sha256
            )
            photos.append(
                PhotoItem(
                    id: "remote:\(doc.id)",
                    localIdentifier: nil,
                    filename: doc.filename,
                    takenAt: doc.capturedAt,
                    isVideo: doc.isVideo,
                    isFavorite: doc.favorite,
                    pixelWidth: doc.width,
                    pixelHeight: doc.height,
                    duration: doc.duration,
                    tags: doc.tags,
                    metadata: metadata,
                    faces: doc.faces.map {
                        PhotoFace(
                            id: $0.id,
                            personID: $0.personID,
                            kind: PhotoFace.Kind(rawValue: $0.kind) ?? .person,
                            rect: NormRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                        )
                    },
                    copies: [copy],
                    sha256: doc.sha256,
                    remoteThumbnailKey: nil,
                    serverID: server.id
                )
            )
        }

        return Result(photos: photos, people: Array(peopleByID.values), indexFound: false)
    }
}

// MARK: - Backup

@MainActor
@Observable
final class BackupEngine {
    enum Phase: String, Sendable {
        case queued
        case preparing
        case analyzing
        case uploading
        case metadata
        case done
        case failed
    }

    struct Item: Identifiable, Sendable {
        var id: String
        var filename: String
        var phase: Phase
        var progress: Double
        var error: String?
        var bytes: Int64
        var isMetadataOnly: Bool
    }

    enum Trigger: String, Sendable {
        case manual
        case automatic
        case resume
    }

    var isRunning = false
    var isCancelling = false
    var status: String = "Idle"
    var items: [Item] = []
    var completedCount = 0
    var failedCount = 0
    var totalCount = 0
    var transferredBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var lastRunAt: Date?
    var lastSummary: String?
    var serverID: UUID?
    var trigger: Trigger = .manual
    var lastError: String?

    private var runTask: Task<Void, Never>?
    private let library = PhotoLibraryService.shared

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(completedCount + failedCount) / Double(totalCount))
    }

    var isIdle: Bool { !isRunning }

    // MARK: Running

    func start(
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        trigger: Trigger,
        force: Bool = false,
        limit: Int? = nil
    ) {
        guard !isRunning else { return }
        self.trigger = trigger
        serverID = server.id
        isRunning = true
        isCancelling = false
        failedCount = 0
        completedCount = 0
        transferredBytes = 0
        totalBytes = 0
        items = []
        lastSummary = nil
        lastError = nil
        status = trigger == .automatic ? "Backing up automatically…" : "Starting backup…"

        let candidates = candidatesForBackup(catalog: catalog, server: server, force: force, limit: limit)
        totalCount = candidates.count
        totalBytes = candidates.reduce(into: 0) { total, photo in
            total += Int64(photo.metadata.fileSize ?? 0)
        }
        items = candidates.map { photo in
            Item(
                id: photo.id,
                filename: photo.filename,
                phase: .queued,
                progress: 0,
                bytes: photo.copy(on: server.id)?.byteCount ?? 0,
                isMetadataOnly: photo.copy(on: server.id) != nil && photo.sidecarDirtyAt != nil
            )
        }
        lastRunAt = Date()

        runTask = Task { [weak self] in
            guard let self else { return }
            if candidates.isEmpty {
                // Still publish the index so names and tags edited while every
                // photo was already uploaded reach the bucket.
                await self.uploadIndex(client: client, catalog: catalog, server: server, device: DeviceInfo.name)
                self.isRunning = false
                self.status = "Everything is backed up."
                self.lastSummary = "Everything is up to date."
                return
            }
            await self.runLoop(
                server: server,
                client: client,
                catalog: catalog,
                settings: settings,
                faceStore: faceStore,
                candidates: candidates,
                force: force
            )
        }
    }

    /// Lets a background task wait for the whole run instead of reporting
    /// completion as soon as the loop is scheduled.
    func awaitCompletion() async {
        await runTask?.value
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        status = "Stopping…"
        runTask?.cancel()
        BackgroundUploader.shared.cancelAll()
    }

    private func candidatesForBackup(
        catalog: CatalogStore,
        server: ServerConfig,
        force: Bool,
        limit: Int?
    ) -> [PhotoItem] {
        let selected = catalog.photos.filter { photo in
            if force { return photo.isLocal }
            if photo.copy(on: server.id) != nil {
                // Already has the bytes; only a pending sidecar edit remains.
                return photo.sidecarDirtyAt != nil
            }
            return photo.isLocal
        }
        .sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
        if let limit { return Array(selected.prefix(limit)) }
        return selected
    }

    private func runLoop(
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        candidates: [PhotoItem],
        force: Bool
    ) async {
        var lastIndexUpload = Date()
        var uploadedSinceIndex = 0
        let analyzer = FaceAnalyzer()
        let device = DeviceInfo.name

        for photo in candidates {
            if Task.isCancelled { break }
            let isMetadataOnly = photo.copy(on: server.id) != nil && !force
            updateItem(photo.id) { $0.phase = isMetadataOnly ? .metadata : .preparing }
            status = isMetadataOnly
                ? "Updating details for \(photo.filename)"
                : "Backing up \(photo.filename)"

            do {
                try await backupOne(
                    photo: photo,
                    server: server,
                    client: client,
                    catalog: catalog,
                    settings: settings,
                    faceStore: faceStore,
                    analyzer: analyzer,
                    device: device,
                    isMetadataOnly: isMetadataOnly
                )
                completedCount += 1
                uploadedSinceIndex += 1
                updateItem(photo.id) {
                    $0.phase = .done
                    $0.progress = 1
                }
            } catch is CancellationError {
                updateItem(photo.id) { $0.phase = .queued }
                break
            } catch {
                failedCount += 1
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastError = message
                updateItem(photo.id) {
                    $0.phase = .failed
                    $0.error = message
                }
                status = "Could not back up \(photo.filename)"
            }

            if uploadedSinceIndex >= 20 || Date().timeIntervalSince(lastIndexUpload) > 60 {
                await uploadIndex(client: client, catalog: catalog, server: server, device: device)
                lastIndexUpload = Date()
                uploadedSinceIndex = 0
            }
        }

        await uploadIndex(client: client, catalog: catalog, server: server, device: device)

        isRunning = false
        isCancelling = false
        catalog.saveNow()
        if Task.isCancelled {
            status = "Backup stopped."
            lastSummary = "Stopped after \(completedCount) of \(totalCount)."
        } else if failedCount > 0 {
            status = "Backup finished with \(failedCount) problem\(failedCount == 1 ? "" : "s")."
            lastSummary = "\(completedCount) uploaded, \(failedCount) failed."
        } else {
            status = "Backed up \(completedCount) item\(completedCount == 1 ? "" : "s")."
            lastSummary = "Everything is up to date."
        }
    }

    private func backupOne(
        photo original: PhotoItem,
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        analyzer: FaceAnalyzer,
        device: String,
        isMetadataOnly: Bool
    ) async throws {
        var photo = original
        var sha = original.sha256
        var byteCount = original.copy(on: server.id)?.byteCount ?? 0
        // Computed once and reused for the object, sidecar and copy record so a
        // concurrent rescan cannot make them disagree.
        var objectKey: String?

        if !isMetadataOnly {
            guard let localIdentifier = photo.localIdentifier,
                  let exported = try await library.exportOriginal(for: localIdentifier) else {
                throw BackupError.exportFailed(photo.filename)
            }
            defer { try? FileManager.default.removeItem(at: exported.url) }

            var metadata = await Self.readMetadata(url: exported.url)
            metadata.placeName = photo.metadata.placeName ?? metadata.placeName
            photo.metadata = metadata
            if photo.metadata.uti == nil {
                photo.metadata.uti = exported.uti
            }

            updateItem(photo.id) { $0.phase = .analyzing }
            if settings.faceRecognitionEnabled && photo.analyzedAt == nil {
                if let image = await Self.uprightImage(url: exported.url) {
                    let outcome = await analyzer.analyze(image: image, embeddingStore: faceStore)
                    catalog.applyFaceAnalysis(photoID: photo.id, faces: outcome.faces, metadata: metadata)
                    photo = catalog.photo(id: photo.id) ?? photo
                }
            }

            updateItem(photo.id) { $0.phase = .uploading }
            let key = Self.objectKey(for: photo, in: server)
            objectKey = key
            let (request, hash) = try await client.signedPutFileRequestAsync(
                key: key,
                fileURL: exported.url,
                contentType: Self.contentType(for: photo)
            )
            sha = hash
            let size = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? Int64) ?? 0
            byteCount = size

            try await upload(
                fileURL: exported.url,
                request: request,
                settings: settings,
                photoID: photo.id
            )

            if let thumb = await Self.makeThumbnail(url: exported.url) {
                let thumbName = String(hash.prefix(20)) + ".jpg"
                let thumbKey = S3Client.join(server.normalizedPrefix, ".backu/thumbs/\(thumbName)")
                try? await client.putObject(key: thumbKey, data: thumb, contentType: "image/jpeg")
                photo.remoteThumbnailKey = thumbKey
            }

            photo.sha256 = hash
            catalog.mutatePhoto(photo.id) {
                $0.metadata = photo.metadata
                $0.sha256 = hash
                $0.analyzedAt = photo.analyzedAt ?? Date()
                $0.remoteThumbnailKey = photo.remoteThumbnailKey
            }
        }

        updateItem(photo.id) { $0.phase = .metadata }
        let current = catalog.photo(id: photo.id) ?? photo
        let sidecar = SidecarDocument.make(
            photo: current,
            people: Dictionary(catalog.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            device: device,
            sha256: sha
        )
        let finalObjectKey = objectKey
            ?? current.copy(on: server.id)?.objectKey
            ?? S3Client.join(server.normalizedPrefix, Self.objectRelativeKey(for: current, in: server))
        let sidecarKey = current.copy(on: server.id)?.sidecarKey ?? finalObjectKey + ".json"
        try await client.putObject(
            key: sidecarKey,
            data: try sidecar.data(),
            contentType: "application/json"
        )

        catalog.recordUpload(
            copy: PhotoCopy(
                serverID: server.id,
                objectKey: finalObjectKey,
                sidecarKey: sidecarKey,
                thumbnailKey: current.remoteThumbnailKey,
                uploadedAt: Date(),
                byteCount: byteCount,
                etag: nil,
                sha256: sha
            ),
            for: current.id
        )
        catalog.mutatePhoto(current.id) { $0.sidecarDirtyAt = nil }
        transferredBytes += byteCount
    }

    private func upload(
        fileURL: URL,
        request: URLRequest,
        settings: AppSettings,
        photoID: String
    ) async throws {
        let allowsCellular = settings.backupOnCellular
        do {
            try await BackgroundUploader.shared.upload(
                fileURL: fileURL,
                request: request,
                allowsCellular: allowsCellular
            ) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateItem(photoID) { $0.progress = fraction }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private func uploadIndex(client: S3Client, catalog: CatalogStore, server: ServerConfig, device: String) async {
        let document = RemoteIndexDocument.make(
            photos: catalog.photos,
            people: catalog.people,
            serverID: server.id,
            device: device
        )
        guard !document.isEmpty else { return }
        guard let data = try? JSONFile.encoder(pretty: true).encode(document) else { return }
        try? await client.putObject(
            key: S3Client.join(server.normalizedPrefix, RemoteLibrary.indexKey),
            data: data,
            contentType: "application/json"
        )
    }

    private func updateItem(_ id: String, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    // MARK: Heavy work, off the main actor

    nonisolated static func readMetadata(url: URL) async -> PhotoMetadata {
        await Task.detached(priority: .utility) {
            ImageMetadataReader.read(url: url)
        }.value
    }

    nonisolated static func makeThumbnail(url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            ImageMetadataReader.thumbnailJPEG(url: url, maxPixel: 900)
        }.value
    }

    nonisolated static func uprightImage(url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            ImageMetadataReader.uprightCGImage(url: url, maxPixel: 1600)
        }.value
    }

    // MARK: Keys

    nonisolated static func objectRelativeKey(for photo: PhotoItem, in server: ServerConfig) -> String {
        let date = photo.takenAt ?? Date()
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = String(format: "%02d", components.month ?? 1)
        let ext = fileExtension(for: photo)
        let stem = sanitize(photo.filename.deletingPathExtensionSafe)
        let short = String(SigV4Signer.sha256Hex(Data(photo.id.utf8)).prefix(8))
        return "Photos/\(year)/\(month)/\(stem)-\(short).\(ext)"
    }

    nonisolated static func objectKey(for photo: PhotoItem, in server: ServerConfig) -> String {
        if let existing = photo.copy(on: server.id)?.objectKey { return existing }
        return S3Client.join(server.normalizedPrefix, objectRelativeKey(for: photo, in: server))
    }

    nonisolated static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "photo" : String(trimmed.prefix(80))
    }

    nonisolated static func fileExtension(for photo: PhotoItem) -> String {
        if !photo.filename.pathExtensionLower.isEmpty { return photo.filename.pathExtensionLower }
        if let uti = photo.metadata.uti, let ext = UTTypeShim.fileExtension(for: uti), !ext.isEmpty {
            return ext.lowercased()
        }
        return photo.isVideo ? "mov" : "jpg"
    }

    nonisolated static func contentType(for photo: PhotoItem) -> String {
        if let uti = photo.metadata.uti {
            return UTTypeShim.mimeType(for: uti)
        }
        if let type = UTType(filenameExtension: fileExtension(for: photo)) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

enum BackupError: LocalizedError {
    case exportFailed(String)
    case missingCredentials
    case invalidServer

    var errorDescription: String? {
        switch self {
        case let .exportFailed(name): return "Could not read \(name) from the photo library."
        case .missingCredentials: return "No access key is stored for this server."
        case .invalidServer: return "This server is missing an endpoint or bucket."
        }
    }
}

extension String {
    var pathExtensionLower: String {
        (self as NSString).pathExtension.lowercased()
    }

    var deletingPathExtensionSafe: String {
        let value = (self as NSString).deletingPathExtension
        return value.isEmpty ? self : value
    }
}
