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
    let atlases = AtlasStore()

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
    /// When iOS is asked to wake the app for automatic uploads. Shown in the
    /// backup activity sheet so the background promise is visible.
    var backgroundBackupRequestedAt: Date?

    private var libraryObserverTask: Task<Void, Never>?
    private var backgroundObserverTask: Task<Void, Never>?
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
        images.atlasEnabled = settings.atlasThumbnailsEnabled
        AppModel.shared = self
        installImageLoaders()
    }

    private func installImageLoaders() {
        images.atlasStore = atlases
        images.atlasClient = { [weak self] serverID in
            guard let self else { return nil }
            guard let server = self.servers.server(id: serverID) else { return nil }
            return self.servers.client(for: server)
        }
        images.atlasPrefix = { [weak self] serverID in
            self?.servers.server(id: serverID)?.normalizedPrefix ?? ""
        }
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
        await resumePendingUploads()
        startPhotoLibraryObserver()
        startBackgroundUploadObserver()
        if settings.autoBackupEnabled {
            await runAutoBackup(reason: "launch")
        }
        scheduleBackgroundBackup()
        if BackgroundUploader.shared.hasPendingBackgroundEvents {
            await processBackgroundUploadEvents()
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
        await resumePendingUploads()
        await syncRemoteLibraries()
        await runAutoBackup(reason: "foreground")
        scheduleBackgroundBackup()
        analyzeInBackgroundIfNeeded()
        if BackgroundUploader.shared.hasPendingBackgroundEvents {
            await processBackgroundUploadEvents()
        }
    }

    /// Runs after iOS delivers background URLSession events. Reconcile first,
    /// persist, then release the system completion handler.
    func processBackgroundUploadEvents() async {
        // Only reconcile here. Starting new uploads from a URLSession event has
        // no guaranteed execution time; the scheduled BGProcessingTask does that
        // with a real window and an expiry handler.
        await resumePendingUploads()
        scheduleBackgroundBackup()
        catalog.saveNow()
        BackgroundUploader.shared.completeBackgroundEvents()
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

    private func startBackgroundUploadObserver() {
        guard backgroundObserverTask == nil else { return }
        backgroundObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .backupUploaderDidFinishEvents) {
                guard let self else { return }
                await self.processBackgroundUploadEvents()
            }
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

    /// Every bucket that should hold a copy. Selection order is preserved and
    /// disabled servers are skipped; if nothing was ever selected, fall back to
    /// the primary server so upgrades keep backing up.
    var backupServers: [ServerConfig] {
        let selected = settings.backupServerIDs.compactMap { servers.server(id: $0) }
            .filter(\.isEnabled)
        if !selected.isEmpty { return selected }
        return servers.primaryServer.map { [$0] } ?? []
    }

    /// First destination, kept for UI that needs one representative server.
    var backupServer: ServerConfig? { backupServers.first }

    var backupDestinations: [BackupEngine.Destination] {
        backupServers.compactMap { server in
            servers.client(for: server).map {
                BackupEngine.Destination(server: server, client: $0)
            }
        }
    }

    var backupDestinationCount: Int { backupServers.count }

    var backupDestinationSummary: String {
        let names = backupServers.map(\.name)
        switch names.count {
        case 0: return "No destination"
        case 1: return names[0]
        default: return "\(names.count) buckets · \(names.joined(separator: " + "))"
        }
    }

    func isBackupDestination(_ server: ServerConfig) -> Bool {
        backupServers.contains { $0.id == server.id }
    }

    func addBackupDestination(_ server: ServerConfig) {
        guard !settings.backupServerIDs.contains(server.id) else { return }
        settings.backupServerIDs.append(server.id)
        scheduleBackgroundBackup()
    }

    func removeBackupDestination(_ server: ServerConfig) {
        // Keep one destination so a stray tap cannot silently turn backup off.
        guard settings.backupServerIDs.count > 1 else { return }
        settings.backupServerIDs.removeAll { $0 == server.id }
        scheduleBackgroundBackup()
    }

    func toggleBackupDestination(_ server: ServerConfig) {
        if isBackupDestination(server) {
            removeBackupDestination(server)
        } else {
            addBackupDestination(server)
        }
    }

    func startBackup(force: Bool = false) {
        guard !backupServers.isEmpty else {
            errorMessage = "Add a storage server first."
            return
        }
        let missing = backupServers.filter { servers.client(for: $0) == nil }
        if !missing.isEmpty {
            errorMessage = "\(missing.map(\.name).joined(separator: ", ")) missing an access key. Open Servers to fix it."
        }
        let destinations = backupDestinations
        guard !destinations.isEmpty else {
            errorMessage = "This server is missing its access key. Open Servers to fix it."
            return
        }
        backup.start(
            destinations: destinations,
            catalog: catalog,
            settings: settings,
            faceStore: faceStore,
            trigger: .manual,
            force: force
        )
        scheduleBackgroundBackup()
    }

    /// Finalizes uploads that already reached a bucket while the app was
    /// closed, without starting a new transfer.
    @discardableResult
    func resumePendingUploads() async -> Int {
        let destinations = backupDestinations
        guard !destinations.isEmpty else { return 0 }
        return await backup.resumePendingUploads(
            destinations: destinations,
            catalog: catalog
        )
    }

    /// Photos that are missing a copy in at least one selected bucket, or whose
    /// sidecar edit still has to reach every bucket.
    var photosPendingBackup: Int {
        let targets = backupServers
        guard !targets.isEmpty else { return 0 }
        return catalog.photos.filter { photo in
            guard photo.isLocal else { return false }
            return targets.contains { target in
                photo.copy(on: target.id) == nil || photo.sidecarDirtyAt != nil
            }
        }.count
    }

    /// Number of individual object copies still owed across all destinations.
    var copiesPendingBackup: Int {
        let targets = backupServers
        guard !targets.isEmpty else { return 0 }
        return catalog.photos.reduce(into: 0) { count, photo in
            guard photo.isLocal else { return }
            for target in targets where photo.copy(on: target.id) == nil || photo.sidecarDirtyAt != nil {
                count += 1
            }
        }
    }

    /// Ask iOS for a background processing window. Short delay while photos are
    /// waiting; a slow periodic check when everything is up to date.
    func scheduleBackgroundBackup() {
        guard settings.autoBackupEnabled, !backupServers.isEmpty else {
            BackupScheduler.cancel()
            #if os(iOS)
            backgroundBackupRequestedAt = nil
            #endif
            return
        }
        let pending = photosPendingBackup
        let delay: TimeInterval = pending > 0 ? 60 : 6 * 60 * 60
        BackupScheduler.schedule(after: delay)
        #if os(iOS)
        backgroundBackupRequestedAt = Date().addingTimeInterval(delay)
        #endif
    }

    func runAutoBackup(reason: String) async {
        guard settings.autoBackupEnabled else {
            scheduleBackgroundBackup()
            return
        }
        let isBackground = reason == "background" || reason == "background-events"
        if !isBackground {
            if let last = lastAutoBackupCheck, Date().timeIntervalSince(last) < 60 * 3 { return }
        }
        lastAutoBackupCheck = Date()
        let destinations = backupDestinations
        guard !destinations.isEmpty else {
            scheduleBackgroundBackup()
            return
        }
        guard !backup.isRunning else {
            scheduleBackgroundBackup()
            return
        }
        backup.start(
            destinations: destinations,
            catalog: catalog,
            settings: settings,
            faceStore: faceStore,
            trigger: isBackground ? .background : .automatic,
            // A background window is short and can be terminated; do a bounded
            // chunk split across destinations and let the next window continue.
            limit: isBackground ? 25 : nil
        )
        scheduleBackgroundBackup()
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
        if settings.backupServerIDs.isEmpty {
            settings.backupServerIDs = [config.id]
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
        settings.backupServerIDs = []
        images.clearMemory()
        atlases.clearAll()
        Task { await faceStore.deleteAll() }
        try? FileManager.default.removeItem(at: AppPaths.imageCache)
        try? FileManager.default.removeItem(at: AppPaths.thumbnailCache)
        showOnboarding = true
    }

    func removeServer(_ server: ServerConfig) {
        servers.remove(server)
        settings.backupServerIDs.removeAll { $0 == server.id }
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
        prefetchRemotePreviews()
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
            prefetchRemotePreviews()
        } catch {
            // Non-fatal: an empty bucket has no index yet.
        }
    }

    private var previewPrefetchTask: Task<Void, Never>?

    /// Pulls the low-resolution atlas for every remote-only photo once per
    /// session. At 64 px a sheet is ~20 KB for 36 photos, so a 100k library is
    /// a few tens of megabytes and after it lands the grid can scroll the
    /// whole library with no network at all. Metered links are left alone
    /// unless the person already allowed cellular backups.
    func prefetchRemotePreviews() {
        guard settings.atlasThumbnailsEnabled, previewPrefetchTask == nil else { return }
        let photos = catalog.photos.filter(\.isRemoteOnly)
        guard photos.count >= 30 else { return }
        let byServer = Dictionary(grouping: photos) { $0.serverID ?? $0.copies.first?.serverID }
        previewPrefetchTask = Task(priority: .utility) { [weak self] in
            // Let NWPathMonitor deliver its first path: starting before it
            // does would treat a cellular link as "unknown" and pull anyway.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            defer { self.previewPrefetchTask = nil }
            let snapshot = TransferNetworkMonitor.shared.current()
            if snapshot.isExpensive && !self.settings.backupOnCellular { return }
            for (serverID, group) in byServer {
                if Task.isCancelled { return }
                guard let server = self.servers.server(id: serverID),
                      let client = self.servers.client(for: server) else { continue }
                await self.atlases.preloadPreviews(
                    photos: group,
                    client: client,
                    prefix: server.normalizedPrefix
                )
            }
        }
    }

    /// Settings → Experimental. Turning it off makes every atlas path inert
    /// immediately; cached sheets stay on disk so turning it back on is cheap.
    func setAtlasThumbnailsEnabled(_ enabled: Bool) {
        settings.atlasThumbnailsEnabled = enabled
        images.atlasEnabled = enabled
        if enabled {
            prefetchRemotePreviews()
        } else {
            previewPrefetchTask?.cancel()
            previewPrefetchTask = nil
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
        let targets = backupServers
        if photo.isLocal,
           !targets.isEmpty,
           targets.contains(where: { photo.copy(on: $0.id) == nil }) {
            // One bucket is missing this photo, so the redundant copy is not
            // complete yet even though a copy already exists elsewhere.
            return .needsUpdate
        }
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
