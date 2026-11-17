import Foundation
import Observation
import Photos
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case library
    case search
    case people
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .search: return "Search"
        case .people: return "People"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .search: return "magnifyingglass"
        case .people: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

struct ViewerPresentation: Identifiable, Hashable {
    var id = UUID()
    var photoIDs: [String]
    var startID: String
    var panel: ViewerPanel?
}

enum ViewerPanel: String, Hashable, CaseIterable, Identifiable {
    case info
    case tags
    case people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Details"
        case .tags: return "Tags"
        case .people: return "People"
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .tags: return "tag"
        case .people: return "person.crop.circle.badge.questionmark"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static weak var shared: AppModel?

    let settings: AppSettings
    let servers: ServerStore
    let catalog: CatalogStore
    let backup: BackupEngine
    let analyzer: LibraryAnalyzer
    let faceStore: FaceEmbeddingStore
    let places: PlaceResolver
    let images: ImageCache

    var authorization: PHAuthorizationStatus = PhotoLibraryService.authorizationStatus
    var isScanning = false
    var lastScanMessage: String?
    var errorMessage: String?
    var activeTab: AppTab = .library
    var viewer: ViewerPresentation?
    var isSyncingRemote = false
    var remoteSyncMessage: String?
    var showOnboarding = false
    var lastAutoBackupCheck: Date?
    var lastCloudSyncAt: Date?
    var isBootstrapped = false

    private var libraryObserverTask: Task<Void, Never>?
    private var lastKnownChange = Date.distantPast
    private var remoteSyncDismissTask: Task<Void, Never>?

    init(loadFromDisk: Bool = true) {
        #if DEBUG
        DemoBootstrap.wipeIfRequested()
        #endif
        AppPaths.prepareForLaunch()
        settings = AppSettings()
        servers = ServerStore(loadFromDisk: loadFromDisk)
        catalog = CatalogStore(loadFromDisk: loadFromDisk)
        backup = BackupEngine()
        analyzer = LibraryAnalyzer()
        faceStore = FaceEmbeddingStore()
        places = PlaceResolver()
        images = ImageCache()
        AppModel.shared = self
        installImageLoaders()
    }

    private func installImageLoaders() {
        images.remoteThumbnailLoader = { [weak self] photo, size in
            guard let self else { return nil }
            guard let server = self.servers.server(id: photo.copies.first?.serverID ?? photo.serverID),
                  let client = self.servers.client(for: server) else { return nil }
            return await RemoteAssetLoader.load(photo: photo, server: server, client: client, thumbnail: true)
        }
        images.remoteImageLoader = { [weak self] photo in
            guard let self else { return nil }
            guard let server = self.servers.server(id: photo.copies.first?.serverID ?? photo.serverID),
                  let client = self.servers.client(for: server) else { return nil }
            return await RemoteAssetLoader.load(photo: photo, server: server, client: client, thumbnail: false)
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        #if DEBUG
        DemoBootstrap.applyIfRequested(app: self)
        #endif
        authorization = PhotoLibraryService.authorizationStatus
        if let failure = catalog.loadFailure {
            errorMessage = failure
        }
        if servers.servers.isEmpty {
            showOnboarding = true
        }
        if authorization == .authorized || authorization == .limited {
            await scanLibrary()
        }
        await syncRemoteLibraries()
        startPhotoLibraryObserver()
        if settings.autoBackupEnabled {
            await runAutoBackup(reason: "launch")
        }
        if settings.faceRecognitionEnabled && !catalog.photos.isEmpty {
            await analyzer.analyzeMissing(
                catalog: catalog,
                settings: settings,
                faceStore: faceStore,
                places: places,
                limit: 12
            )
        }
    }

    func handleActivation() async {
        guard isBootstrapped else { return }
        await scanLibrary()
        await syncRemoteLibraries()
        await runAutoBackup(reason: "foreground")
        analyzeInBackgroundIfNeeded()
    }

    private func analyzeInBackgroundIfNeeded() {
        guard settings.faceRecognitionEnabled, !analyzer.isRunning else { return }
        Task {
            await analyzer.analyzeMissing(
                catalog: catalog,
                settings: settings,
                faceStore: faceStore,
                places: places,
                limit: 25
            )
        }
    }

    private func startPhotoLibraryObserver() {
        guard libraryObserverTask == nil else { return }
        libraryObserverTask = Task { [weak self] in
            guard let self else { return }
            for await _ in PhotoLibraryService.shared.changeObserverStream() {
                let now = Date()
                guard now.timeIntervalSince(self.lastKnownChange) > 4 else { continue }
                self.lastKnownChange = now
                await self.scanLibrary(force: true)
            }
        }
    }

    // MARK: - Photo access

    var hasPhotoAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    var photoAccessDescription: String {
        switch authorization {
        case .authorized: return "Full access"
        case .limited: return "Limited access"
        case .denied, .restricted: return "No access"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    @discardableResult
    func requestPhotoAccess() async -> PHAuthorizationStatus {
        authorization = await PhotoLibraryService.requestAuthorization()
        if hasPhotoAccess {
            await scanLibrary(force: true)
        }
        return authorization
    }

    // MARK: - Library

    func scanLibrary(force: Bool = false) async {
        guard !isScanning else { return }
        if !force, let last = catalog.lastScanAt, Date().timeIntervalSince(last) < 20 { return }
        authorization = PhotoLibraryService.authorizationStatus
        if authorization == .notDetermined {
            authorization = await PhotoLibraryService.requestAuthorization()
        }
        guard hasPhotoAccess else { return }

        isScanning = true
        let scanned = await PhotoLibraryService.shared.scan(
            LibraryScanOptions(
                includeVideos: settings.includeVideos,
                includeScreenshots: settings.includeScreenshots
            )
        )
        // Under limited access PhotoKit only returns the chosen assets, so
        // anything else must be kept rather than treated as deleted.
        let result = catalog.mergeScanned(scanned, removingMissing: authorization == .authorized)
        isScanning = false
        lastScanMessage = scanned.isEmpty
            ? "No photos found"
            : "\(scanned.count) photos · \(result.added) new"
    }

    // MARK: - Backup

    var backupServer: ServerConfig? {
        if let id = settings.backupServerID, let server = servers.server(id: id) {
            return server
        }
        return servers.primaryServer
    }

    func startBackup(force: Bool = false) {
        guard let server = backupServer else {
            errorMessage = "Add a storage server first."
            return
        }
        guard let client = servers.client(for: server) else {
            errorMessage = "This server is missing its access key. Open Servers to fix it."
            return
        }
        backup.start(
            server: server,
            client: client,
            catalog: catalog,
            settings: settings,
            faceStore: faceStore,
            trigger: .manual,
            force: force
        )
    }

    func runAutoBackup(reason: String) async {
        guard settings.autoBackupEnabled else { return }
        if let last = lastAutoBackupCheck, Date().timeIntervalSince(last) < 60 * 3 { return }
        lastAutoBackupCheck = Date()
        guard let server = backupServer, let client = servers.client(for: server) else { return }
        guard !backup.isRunning else { return }
        backup.start(
            server: server,
            client: client,
            catalog: catalog,
            settings: settings,
            faceStore: faceStore,
            trigger: .automatic
        )
    }

    var lastBackupError: String? { backup.lastError }

    func verify(server: ServerConfig) async -> S3Client.Verification? {
        guard let client = servers.client(for: server) else {
            errorMessage = "No access key stored for \(server.name)."
            return nil
        }
        do {
            let report = try await client.verify(prefix: server.normalizedPrefix)
            servers.markVerified(server.id)
            return report
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Servers

    func addServer(_ config: ServerConfig, credentials: S3Credentials) async -> Bool {
        servers.add(config, credentials: credentials)
        if settings.backupServerID == nil {
            settings.backupServerID = config.id
        }
        let report = await verify(server: config)
        if report?.canWrite == true {
            await importRemoteLibrary(server: config)
            return true
        }
        // Keep the server so the person can fix a typo, but report the failure.
        if errorMessage == nil {
            errorMessage = "Connected, but the key could not write to this bucket."
        }
        return false
    }

    func updateServer(_ config: ServerConfig, credentials: S3Credentials?) async -> Bool {
        servers.update(config, credentials: credentials)
        if let credentials, !credentials.secretAccessKey.isEmpty {
            _ = await verify(server: config)
        }
        return true
    }

    func resetLibrary() {
        catalog.clearLoadFailure()
        catalog.removeAll()
        for server in servers.servers { servers.remove(server) }
        settings.backupServerID = nil
        images.clearMemory()
        Task { await faceStore.deleteAll() }
        try? FileManager.default.removeItem(at: AppPaths.imageCache)
        try? FileManager.default.removeItem(at: AppPaths.thumbnailCache)
        showOnboarding = true
    }

    func removeServer(_ server: ServerConfig) {
        servers.remove(server)
        if settings.backupServerID == server.id {
            settings.backupServerID = servers.primaryServer?.id
        }
        catalog.removeServerCopies(server.id)
    }

    // MARK: - Remote library

    func syncRemoteLibraries() async {
        guard !isSyncingRemote else { return }
        if let last = lastCloudSyncAt, Date().timeIntervalSince(last) < 60 { return }
        isSyncingRemote = true
        var imported = 0
        for server in servers.servers where server.isEnabled {
            guard let client = servers.client(for: server) else { continue }
            do {
                let result = try await RemoteLibrary.load(
                    client: client,
                    server: server,
                    knownPeople: catalog.people
                )
                catalog.mergePersonRecords(result.people)
                imported += catalog.importRemotePhotos(result.photos)
            } catch {
                // A missing index on a new bucket is expected; stay quiet.
            }
        }
        lastCloudSyncAt = Date()
        isSyncingRemote = false
        if imported > 0 {
            showRemoteSyncMessage("\(imported) photo\(imported == 1 ? "" : "s") found in your buckets")
            catalog.saveSoon()
        }
    }

    func importRemoteLibrary(server: ServerConfig) async {
        guard let client = servers.client(for: server) else { return }
        do {
            let result = try await RemoteLibrary.load(
                client: client,
                server: server,
                knownPeople: catalog.people
            )
            catalog.mergePersonRecords(result.people)
            let imported = catalog.importRemotePhotos(result.photos)
            if imported > 0 {
                showRemoteSyncMessage("\(imported) photo\(imported == 1 ? "" : "s") found in \(server.name)")
            }
        } catch {
            // Non-fatal: an empty bucket has no index yet.
        }
    }

    /// Imports are deduplicated by the catalog, so the same photos never
    /// produce a second announcement. The banner clears itself after a few
    /// seconds instead of sitting above the grid until dismissed.
    private var lastRemoteAnnouncement: (message: String, at: Date)?

    func showRemoteSyncMessage(_ message: String) {
        if remoteSyncMessage != message {
            if let last = lastRemoteAnnouncement,
               last.message == message,
               Date().timeIntervalSince(last.at) < 120 {
                return
            }
            lastRemoteAnnouncement = (message, Date())
            remoteSyncMessage = message
        }
        remoteSyncDismissTask?.cancel()
        remoteSyncDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.remoteSyncMessage = nil
        }
    }

    func dismissRemoteSyncMessage() {
        remoteSyncDismissTask?.cancel()
        remoteSyncDismissTask = nil
        remoteSyncMessage = nil
    }

    // MARK: - Photo helpers

    func toggleFavorite(_ photoID: String) {
        guard let photo = catalog.photo(id: photoID) else { return }
        catalog.setFavorite(photoID, isFavorite: !photo.isFavorite)
        catalog.mutatePhoto(photoID) { $0.sidecarDirtyAt = Date() }
    }

    func photoBackupState(_ photo: PhotoItem) -> BackupState {
        if photo.copies.isEmpty { return .notBackedUp }
        if photo.sidecarDirtyAt != nil { return .needsUpdate }
        return .backedUp
    }

    enum BackupState {
        case backedUp
        case needsUpdate
        case notBackedUp
    }

    func namePerson(_ person: Person, name: String) {
        catalog.renamePerson(person.id, to: name)
    }

    func createPerson(named name: String, isPet: Bool = false) -> Person {
        catalog.createPerson(name: name, isPet: isPet)
    }

    func photosForViewer(startingAt photoID: String, within photos: [PhotoItem], window: Int = 60) -> ViewerPresentation {
        let ids = photos.map(\.id)
        guard let index = ids.firstIndex(of: photoID) else {
            return ViewerPresentation(photoIDs: [photoID], startID: photoID)
        }
        let lower = max(0, index - window)
        let upper = min(ids.count, index + window + 1)
        return ViewerPresentation(photoIDs: Array(ids[lower..<upper]), startID: photoID)
    }
}
