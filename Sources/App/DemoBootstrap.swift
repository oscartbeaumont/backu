#if DEBUG
import Foundation

/// Test-only seam used by the UI test suite and by `scripts/demo.sh`. It lets a
/// launch environment seed servers and settings so flows can be exercised
/// without typing credentials on a simulator keyboard.
@MainActor
enum DemoBootstrap {
    struct Payload: Decodable {
        struct Server: Decodable {
            var name: String
            var provider: String?
            var endpoint: String?
            var region: String?
            var bucket: String
            var accessKeyID: String
            var secretAccessKey: String
            var pathStyle: Bool?
            var prefix: String?
        }

        struct Settings: Decodable {
            var autoBackupEnabled: Bool?
            var backupOnCellular: Bool?
            var faceRecognitionEnabled: Bool?
            var gridColumns: Int?
            var hasCompletedOnboarding: Bool?
            var showRemoteOnlyPhotos: Bool?
            /// Test-only: mark every bootstrapped server as a backup destination.
            var backupAllServers: Bool?
        }

        var servers: [Server]?
        var settings: Settings?
        var backup: Bool?
        var scan: Bool?
    }

    static func applyIfRequested(app: AppModel) {
        guard let raw = ProcessInfo.processInfo.environment["BACKU_BOOTSTRAP"],
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        if let settings = payload.settings {
            if let value = settings.autoBackupEnabled { app.settings.autoBackupEnabled = value }
            if let value = settings.backupOnCellular { app.settings.backupOnCellular = value }
            if let value = settings.faceRecognitionEnabled { app.settings.faceRecognitionEnabled = value }
            if let value = settings.gridColumns { app.settings.gridColumns = value }
            if let value = settings.showRemoteOnlyPhotos { app.settings.showRemoteOnlyPhotos = value }
            if let value = settings.hasCompletedOnboarding { app.settings.hasCompletedOnboarding = value }
        }

        for server in payload.servers ?? [] {
            guard app.servers.servers.contains(where: { $0.bucket == server.bucket && $0.endpoint == (server.endpoint ?? "") }) == false else { continue }
            let provider = StorageProvider(rawValue: server.provider ?? "custom") ?? .custom
            let config = ServerConfig(
                name: server.name,
                provider: provider,
                endpoint: server.endpoint ?? "",
                region: server.region ?? provider.defaultRegion,
                bucket: server.bucket,
                accessKeyID: server.accessKeyID,
                prefix: server.prefix ?? "Backu",
                pathStyle: server.pathStyle ?? provider.defaultPathStyle,
                lastVerifiedAt: Date()
            )
            let credentials = S3Credentials(
                accessKeyID: server.accessKeyID,
                secretAccessKey: server.secretAccessKey
            )
            app.servers.add(config, credentials: credentials)
            if app.settings.backupServerIDs.isEmpty {
                app.settings.backupServerIDs = [config.id]
            }
        }

        if payload.settings?.backupAllServers == true {
            app.settings.backupServerIDs = app.servers.servers.map(\.id)
        }

        if !app.servers.servers.isEmpty {
            app.showOnboarding = false
            app.settings.hasCompletedOnboarding = true
        }

        if payload.backup == true {
            app.settings.autoBackupEnabled = true
        }
    }

    static func wipeIfRequested() {
        guard ProcessInfo.processInfo.environment["BACKU_RESET"] == "1" else { return }
        try? FileManager.default.removeItem(at: AppPaths.supportDirectory)
        Keychain.deleteAll()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
    }
}
#endif
