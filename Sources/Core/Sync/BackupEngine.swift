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
        /// Empty for older call sites; the activity view only shows it when a
        /// photo is being copied to more than one bucket.
        var destinationName: String = ""
        var phase: Phase
        var progress: Double
        var error: String?
        var bytes: Int64
        var isMetadataOnly: Bool
    }

    /// One bucket that receives a copy during a run.
    struct Destination {
        var server: ServerConfig
        var client: S3Client
    }

    struct DestinationStatus: Identifiable, Equatable {
        var id: UUID
        var name: String
        var bucket: String
        var total = 0
        var completed = 0
        var failed = 0
        var recovered = 0
        var isActive = false
        var isFinished = false

        var progress: Double {
            guard total > 0 else { return isFinished ? 1 : 0 }
            return min(1, Double(completed + failed) / Double(total))
        }
    }

    enum Trigger: String, Sendable {
        case manual
        case automatic
        case background
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
    /// Bucket currently receiving bytes; nil between destinations or while idle.
    var activeServerID: UUID?
    var destinationStatuses: [DestinationStatus] = []
    var trigger: Trigger = .manual
    var lastError: String?
    var reclaimedCount = 0
    var lastRunDuration: TimeInterval?
    /// Replaces the old whole-index upload. Set by AppModel; the engine only
    /// knows that a bucket's metadata needs publishing.
    var publishMetadata: (() async -> Void)?

    private var runTask: Task<Void, Never>?
    private var runStartedAt: Date?
    /// Settings → Experimental, snapshotted when a run starts.
    private var atlasEnabled = false
    private let library = PhotoLibraryService.shared
    private let journal = UploadJournal.shared

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(completedCount + failedCount) / Double(totalCount))
    }

    var isIdle: Bool { !isRunning }

    var currentItem: Item? {
        items.first { item in
            switch item.phase {
            case .preparing, .analyzing, .uploading, .metadata: return true
            case .queued, .done, .failed: return false
            }
        }
    }

    var queuedCount: Int {
        items.filter { $0.phase == .queued }.count
    }

    var failedItems: [Item] {
        items.filter { $0.phase == .failed }
    }

    var averageBytesPerSecond: Double {
        let elapsed: TimeInterval
        if let runStartedAt {
            elapsed = Date().timeIntervalSince(runStartedAt)
        } else {
            elapsed = lastRunDuration ?? 0
        }
        guard elapsed > 0.2 else { return 0 }
        return Double(transferredBytes) / elapsed
    }

    // MARK: Running

    func start(
        destinations: [Destination],
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        trigger: Trigger,
        force: Bool = false,
        limit: Int? = nil
    ) {
        guard !isRunning, !destinations.isEmpty else { return }
        self.trigger = trigger
        atlasEnabled = settings.atlasThumbnailsEnabled
        serverID = destinations.first?.server.id
        activeServerID = nil
        isRunning = true
        isCancelling = false
        failedCount = 0
        completedCount = 0
        transferredBytes = 0
        totalBytes = 0
        items = []
        lastSummary = nil
        lastError = nil
        reclaimedCount = 0
        lastRunDuration = nil
        runStartedAt = nil
        totalCount = 0
        status = "Checking uploads…"
        lastRunAt = Date()
        destinationStatuses = destinations.map {
            DestinationStatus(id: $0.server.id, name: $0.server.name, bucket: $0.server.bucket)
        }
        // A background window should not grow with the number of buckets.
        let perDestinationLimit = limit.map { max(1, $0 / max(1, destinations.count)) }

        runTask = Task { [weak self] in
            guard let self else { return }

            // Reconcile every destination before planning. This reclaims work
            // that landed while the app was closed and makes the queue honest.
            var plans: [(destination: Destination, candidates: [PhotoItem])] = []
            for destination in destinations {
                if Task.isCancelled { break }
                await destination.client.abortStaleMultipartUploads()
                let recovered = await self.reconcileUploads(
                    server: destination.server,
                    client: destination.client,
                    catalog: catalog,
                    showStatus: true
                )
                if recovered > 0 {
                    self.reclaimedCount += recovered
                    self.updateDestination(destination.server.id) { $0.recovered += recovered }
                }
                let candidates = self.candidatesForBackup(
                    catalog: catalog,
                    server: destination.server,
                    force: force,
                    limit: perDestinationLimit
                )
                self.totalCount += candidates.count
                self.totalBytes += candidates.reduce(into: 0) { total, photo in
                    total += Int64(photo.metadata.fileSize ?? 0)
                }
                self.updateDestination(destination.server.id) { $0.total = candidates.count }
                self.items.append(contentsOf: candidates.map { photo in
                    Item(
                        id: Self.itemID(photoID: photo.id, serverID: destination.server.id),
                        filename: photo.filename,
                        destinationName: destination.server.name,
                        phase: .queued,
                        progress: 0,
                        bytes: photo.copy(on: destination.server.id)?.byteCount ?? 0,
                        isMetadataOnly: photo.copy(on: destination.server.id) != nil && photo.sidecarDirtyAt != nil
                    )
                })
                plans.append((destination, candidates))
            }

            if self.totalCount == 0 {
                // Still publish metadata so names and tags edited while every
                // photo was already uploaded reach every bucket.
                for plan in plans where !Task.isCancelled {
                    await self.publishMetadata?()
                }
                self.isRunning = false
                self.lastRunDuration = 0
                if Task.isCancelled {
                    self.status = "Backup stopped."
                    self.lastSummary = "Stopped before any uploads."
                } else if self.reclaimedCount > 0 {
                    self.status = "Recovered \(self.reclaimedCount) upload\(self.reclaimedCount == 1 ? "" : "s")."
                    self.lastSummary = "Uploads finished in the background."
                } else {
                    self.status = destinations.count > 1
                        ? "Every bucket is up to date."
                        : "Everything is backed up."
                    self.lastSummary = "Everything is up to date."
                }
                return
            }

            self.runStartedAt = Date()
            switch trigger {
            case .automatic: self.status = "Backing up automatically…"
            case .background: self.status = "Backing up in the background…"
            case .manual, .resume: self.status = "Uploading…"
            }

            for plan in plans {
                if Task.isCancelled { break }
                self.activeServerID = plan.destination.server.id
                self.updateDestination(plan.destination.server.id) { $0.isActive = true }
                await self.runDestination(
                    destination: plan.destination,
                    candidates: plan.candidates,
                    catalog: catalog,
                    settings: settings,
                    faceStore: faceStore,
                    force: force
                )
                self.updateDestination(plan.destination.server.id) {
                    $0.isActive = false
                    $0.isFinished = true
                }
            }
            self.activeServerID = nil
            await self.finishRun(catalog: catalog, destinations: destinations)
        }
    }

    /// Lets a background task wait for the whole run instead of reporting
    /// completion as soon as the loop is scheduled.
    func awaitCompletion() async {
        await runTask?.value
    }

    /// Called on launch/activation and after background URLSession events. Only
    /// finalizes uploads that already landed; it never starts a new transfer.
    @discardableResult
    func resumePendingUploads(
        destinations: [Destination],
        catalog: CatalogStore
    ) async -> Int {
        guard !isRunning else { return 0 }
        var recovered = 0
        for destination in destinations {
            if Task.isCancelled { break }
            recovered += await reconcileUploads(
                server: destination.server,
                client: destination.client,
                catalog: catalog,
                showStatus: false
            )
        }
        if recovered > 0 {
            reclaimedCount = recovered
            lastSummary = "Recovered \(recovered) completed upload\(recovered == 1 ? "" : "s")."
            lastRunAt = Date()
            status = lastSummary ?? "Idle"
            catalog.saveNow()
        }
        return recovered
    }

    private func reconcileUploads(
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        showStatus: Bool
    ) async -> Int {
        journal.purgeStale()
        let pending = journal.pending(serverID: server.id).count
        guard pending > 0 else { return 0 }
        if showStatus { status = "Finishing uploads…" }
        let recovered = await UploadReconciler.reconcile(
            server: server,
            client: client,
            catalog: catalog,
            journal: journal
        ) { [weak self] completed, total in
            guard let self else { return }
            if showStatus { self.status = "Finishing uploads… \(completed)/\(total)" }
        }
        if recovered > 0 { catalog.saveNow() }
        return recovered
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
        var selected = catalog.photos.filter { photo in
            if force { return photo.isLocal }
            if let copy = photo.copy(on: server.id) {
                // Already has the bytes; a pending sidecar edit or a missing
                // atlas group still needs a pass. Videos have no frame to pack,
                // so they never become a permanent backfill candidate.
                if photo.isVideo { return photo.sidecarDirtyAt != nil }
                return photo.sidecarDirtyAt != nil || (atlasEnabled && copy.atlasGroup == nil)
            }
            return photo.isLocal
        }
        .sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
        // A bucket written before atlases existed would otherwise re-export an
        // entire library in one run. Newest photos are what a person scrolls
        // first; the rest fills in over later runs.
        let backfillLimit = 500
        let backfillIDs = Set(selected.filter { photo in
            guard atlasEnabled, !photo.isVideo, let copy = photo.copy(on: server.id) else { return false }
            return copy.atlasGroup == nil
        }.map(\.id))
        if backfillIDs.count > backfillLimit {
            let keep = Set(selected
                .filter { backfillIDs.contains($0.id) }
                .sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
                .prefix(backfillLimit)
                .map(\.id))
            selected = selected.filter { photo in
                !backfillIDs.contains(photo.id) || keep.contains(photo.id)
            }
        }
        if let limit { return Array(selected.prefix(limit)) }
        return selected
    }

    private func runDestination(
        destination: Destination,
        candidates: [PhotoItem],
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        force: Bool
    ) async {
        let server = destination.server
        let client = destination.client
        var lastIndexUpload = Date()
        var uploadedSinceIndex = 0
        let analyzer = FaceAnalyzer()
        let device = DeviceInfo.name
        let atlasBatch = AtlasBatch(server: server, client: client, catalog: catalog)

        for photo in candidates {
            if Task.isCancelled { break }
            let itemID = Self.itemID(photoID: photo.id, serverID: server.id)
            let isMetadataOnly = photo.copy(on: server.id) != nil && !force
            updateItem(itemID) { $0.phase = isMetadataOnly ? .metadata : .preparing }
            status = isMetadataOnly
                ? "Updating details for \(photo.filename)"
                : "Backing up \(photo.filename) to \(server.name)"

            do {
                try await backupOne(
                    photo: photo,
                    itemID: itemID,
                    server: server,
                    client: client,
                    catalog: catalog,
                    settings: settings,
                    faceStore: faceStore,
                    analyzer: analyzer,
                    device: device,
                    isMetadataOnly: isMetadataOnly,
                    atlas: atlasBatch
                )
                completedCount += 1
                uploadedSinceIndex += 1
                updateDestination(server.id) { $0.completed += 1 }
                updateItem(itemID) {
                    $0.phase = .done
                    $0.progress = 1
                }
            } catch is CancellationError {
                updateItem(itemID) { $0.phase = .queued }
                break
            } catch {
                failedCount += 1
                updateDestination(server.id) { $0.failed += 1 }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastError = message
                updateItem(itemID) {
                    $0.phase = .failed
                    $0.error = message
                }
                status = "Could not back up \(photo.filename) to \(server.name)"
            }

            if uploadedSinceIndex >= 20 || Date().timeIntervalSince(lastIndexUpload) > 60 {
                await publishMetadata?()
                lastIndexUpload = Date()
                uploadedSinceIndex = 0
            }
        }

        await atlasBatch.flush()
        await publishMetadata?()
    }

    private func finishRun(catalog: CatalogStore, destinations: [Destination]) async {
        isRunning = false
        isCancelling = false
        if let runStartedAt { lastRunDuration = Date().timeIntervalSince(runStartedAt) }
        runStartedAt = nil
        catalog.saveNow()

        let remaining = catalog.photos.filter { photo in
            guard photo.isLocal else { return false }
            return destinations.contains { destination in
                photo.copy(on: destination.server.id) == nil || photo.sidecarDirtyAt != nil
            }
        }.count
        let bucketSuffix = destinations.count > 1 ? " to \(destinations.count) buckets" : ""

        if Task.isCancelled {
            status = "Backup stopped."
            lastSummary = "Stopped after \(completedCount) of \(totalCount) copies."
        } else if failedCount > 0 {
            let failedBuckets = destinationStatuses.filter { $0.failed > 0 }
            status = failedBuckets.count > 1
                ? "Backup finished with problems in \(failedBuckets.count) buckets."
                : "Backup finished with \(failedCount) problem\(failedCount == 1 ? "" : "s")."
            lastSummary = "\(completedCount) uploaded, \(failedCount) failed\(bucketSuffix)."
        } else if remaining > 0 {
            status = "Backed up \(completedCount); \(remaining) waiting for the next background window."
            lastSummary = "\(remaining) photo\(remaining == 1 ? "" : "s") waiting\(bucketSuffix)."
        } else if completedCount == 0, reclaimedCount > 0 {
            status = "Recovered \(reclaimedCount) upload\(reclaimedCount == 1 ? "" : "s")."
            lastSummary = "Everything is up to date."
        } else {
            status = destinations.count > 1
                ? "Backed up \(completedCount) cop\(completedCount == 1 ? "y" : "ies") to \(destinations.count) buckets."
                : "Backed up \(completedCount) item\(completedCount == 1 ? "" : "s")."
            lastSummary = "Everything is up to date."
        }
    }

    private func backupOne(
        photo original: PhotoItem,
        itemID: String,
        server: ServerConfig,
        client: S3Client,
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        analyzer: FaceAnalyzer,
        device: String,
        isMetadataOnly: Bool,
        atlas: AtlasBatch
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

            updateItem(itemID) { $0.phase = .analyzing }
            // The candidate list is built before the first destination runs, so
            // re-read the catalog to avoid analysing the same photo once per
            // bucket.
            if settings.faceRecognitionEnabled, catalog.photo(id: photo.id)?.analyzedAt == nil {
                if let image = await Self.uprightImage(url: exported.url) {
                    let outcome = await analyzer.analyze(image: image, embeddingStore: faceStore)
                    catalog.applyFaceAnalysis(photoID: photo.id, faces: outcome.faces, metadata: metadata)
                    photo = catalog.photo(id: photo.id) ?? photo
                }
            }

            updateItem(itemID) { $0.phase = .uploading }
            let key = Self.objectKey(for: photo, in: server)
            objectKey = key
            let size = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? Int64) ?? 0
            byteCount = size
            let journalSidecarKey = photo.copy(on: server.id)?.sidecarKey ?? key + ".json"
            journal.begin(
                UploadRecord(
                    photoID: photo.id,
                    serverID: server.id,
                    objectKey: key,
                    sidecarKey: journalSidecarKey,
                    byteCount: size,
                    sha256: photo.sha256,
                    startedAt: Date()
                )
            )

            if size >= Self.multipartThreshold {
                sha = try await uploadMultipart(
                    fileURL: exported.url,
                    key: key,
                    contentType: Self.contentType(for: photo),
                    client: client,
                    settings: settings,
                    itemID: itemID
                )
            } else {
                let (request, hash) = try await client.signedPutFileRequestAsync(
                    key: key,
                    fileURL: exported.url,
                    contentType: Self.contentType(for: photo)
                )
                sha = hash
                try await upload(
                    fileURL: exported.url,
                    request: request,
                    settings: settings,
                    itemID: itemID
                )
            }

            if let rendered = await Self.makeThumbnailSet(url: exported.url) {
                let digest = sha ?? ""
                let thumbName = String(digest.prefix(20)) + ".jpg"
                let thumbKey = S3Client.join(server.normalizedPrefix, ".backu/thumbs/\(thumbName)")
                try? await client.putObject(key: thumbKey, data: rendered.thumbnail, contentType: "image/jpeg")
                photo.remoteThumbnailKey = thumbKey
                // The tiles go into the run's atlas batch; it publishes the
                // group every 36 photos and again at the end of the run.
                if atlasEnabled, !digest.isEmpty {
                    await atlas.add(
                        photoID: photo.id,
                        digest: digest,
                        grid: rendered.grid,
                        preview: rendered.preview
                    )
                }
            }

            photo.sha256 = sha
            catalog.mutatePhoto(photo.id) {
                $0.metadata = photo.metadata
                $0.sha256 = sha
                $0.analyzedAt = photo.analyzedAt ?? Date()
                $0.remoteThumbnailKey = photo.remoteThumbnailKey
            }
            journal.begin(
                UploadRecord(
                    photoID: photo.id,
                    serverID: server.id,
                    objectKey: key,
                    sidecarKey: journalSidecarKey,
                    byteCount: size,
                    sha256: sha,
                    startedAt: Date()
                )
            )
        }

        // A photo whose bytes are already in the bucket but whose atlas group is
        // missing (interrupted publish, or an older install) is re-rendered
        // from the local original without uploading the original again.
        if atlasEnabled,
           isMetadataOnly,
           !photo.isVideo,
           photo.copy(on: server.id)?.atlasGroup == nil,
           let sha,
           let localIdentifier = photo.localIdentifier,
           let exported = try? await library.exportOriginal(for: localIdentifier) {
            defer { try? FileManager.default.removeItem(at: exported.url) }
            updateItem(itemID) { $0.phase = .analyzing }
            if let rendered = await Self.makeThumbnailSet(url: exported.url) {
                await atlas.add(
                    photoID: photo.id,
                    digest: sha,
                    grid: rendered.grid,
                    preview: rendered.preview
                )
            }
        }

        updateItem(itemID) { $0.phase = .metadata }
        let current = catalog.photo(id: photo.id) ?? photo
        let sidecar = SidecarDocument.make(
            photo: current,
            people: Dictionary(catalog.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            device: device,
            sha256: sha,
            serverID: server.id
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
        journal.finish(photoID: current.id, serverID: server.id)
        transferredBytes += byteCount
    }

    private func upload(
        fileURL: URL,
        request: URLRequest,
        settings: AppSettings,
        itemID: String
    ) async throws {
        let allowsCellular = settings.backupOnCellular
        do {
            try await S3RetryPolicy.default.run {
                try await BackgroundUploader.shared.upload(
                    fileURL: fileURL,
                    request: request,
                    allowsCellular: allowsCellular
                ) { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateItem(itemID) { $0.progress = fraction }
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private func uploadMultipart(
        fileURL: URL,
        key: String,
        contentType: String,
        client: S3Client,
        settings: AppSettings,
        itemID: String
    ) async throws -> String {
        let allowsCellular = settings.backupOnCellular
        // File-backed because the background URLSession can only send a file;
        // the uploader then hashes and stages each part in one pass.
        let transport = MultipartTransport(fileBacked: true) { upload, number, payload, payloadHash, size, progress in
            let request = try client.signedUploadPartRequest(
                upload: upload,
                partNumber: number,
                payloadHash: payloadHash
            )
            let sink = progress
            return try await S3RetryPolicy.default.run {
                guard case let .file(partURL) = payload else {
                    throw S3Error.decoding("Background uploads require file-backed parts")
                }
                let result = try await BackgroundUploader.shared.uploadResult(
                    fileURL: partURL,
                    request: request,
                    allowsCellular: allowsCellular,
                    progress: { fraction in sink.report(fraction) }
                )
                guard let etag = result.etag else {
                    throw S3Error.decoding("UploadPart returned no ETag")
                }
                return S3MultipartPart(number: number, etag: etag, size: size)
            }
        }

        // Part size and concurrency are adaptive now: `TransferTuning` uses the
        // file size, the link type and this server's measured throughput.
        let uploader = MultipartUploader(
            client: client,
            temporaryDirectory: AppPaths.stagingDirectory,
            transport: transport
        ) { [weak self] fraction in
            Task { @MainActor in
                self?.updateItem(itemID) { $0.progress = fraction }
            }
        }
        return try await uploader.upload(
            fileURL: fileURL,
            key: key,
            contentType: contentType
        )
    }

    private func updateItem(_ id: String, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private func updateDestination(_ id: UUID, _ body: (inout DestinationStatus) -> Void) {
        guard let index = destinationStatuses.firstIndex(where: { $0.id == id }) else { return }
        body(&destinationStatuses[index])
    }

    nonisolated static func itemID(photoID: String, serverID: UUID) -> String {
        "\(serverID.uuidString)|\(photoID)"
    }

    // MARK: Heavy work, off the main actor

    /// UI tests lower this to exercise multipart with the small photo fixtures.
    nonisolated static var multipartThreshold: Int64 {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["BACKU_MULTIPART_THRESHOLD_BYTES"],
           let value = Int64(raw), value > 0 {
            return value
        }
        #endif
        return MultipartUploader.defaultThreshold
    }

    nonisolated static func readMetadata(url: URL) async -> PhotoMetadata {
        await Task.detached(priority: .utility) {
            ImageMetadataReader.read(url: url)
        }.value
    }

    nonisolated static func makeThumbnailSet(url: URL) async -> (thumbnail: Data, grid: CGImage, preview: CGImage)? {
        await Task.detached(priority: .utility) {
            AtlasTileRenderer.render(url: url)
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
