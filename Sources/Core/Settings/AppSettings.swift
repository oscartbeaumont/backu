import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var autoBackupEnabled: Bool {
        didSet { defaults.set(autoBackupEnabled, forKey: Keys.autoBackup) }
    }
    var backupOnCellular: Bool {
        didSet { defaults.set(backupOnCellular, forKey: Keys.cellular) }
    }
    /// Buckets that receive a copy of every photo. Empty falls back to the
    /// first enabled server, matching installs created before redundancy.
    var backupServerIDs: [UUID] {
        didSet { defaults.set(backupServerIDs.map(\.uuidString), forKey: Keys.servers) }
    }
    var includeVideos: Bool {
        didSet { defaults.set(includeVideos, forKey: Keys.videos) }
    }
    var includeScreenshots: Bool {
        didSet { defaults.set(includeScreenshots, forKey: Keys.screenshots) }
    }
    var faceRecognitionEnabled: Bool {
        didSet { defaults.set(faceRecognitionEnabled, forKey: Keys.faces) }
    }
    var gridColumns: Int {
        didSet { defaults.set(gridColumns, forKey: Keys.columns) }
    }
    var showRemoteOnlyPhotos: Bool {
        didSet { defaults.set(showRemoteOnlyPhotos, forKey: Keys.remoteOnly) }
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let autoBackup = "autoBackupEnabled"
        static let cellular = "backupOnCellular"
        static let server = "backupServerID"
        static let servers = "backupServerIDs"
        static let videos = "includeVideos"
        static let screenshots = "includeScreenshots"
        static let faces = "faceRecognitionEnabled"
        static let columns = "gridColumns"
        static let remoteOnly = "showRemoteOnlyPhotos"
        static let onboarded = "hasCompletedOnboarding"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoBackupEnabled = defaults.object(forKey: Keys.autoBackup) as? Bool ?? false
        backupOnCellular = defaults.object(forKey: Keys.cellular) as? Bool ?? false
        let migratedIDs: [UUID]
        if let raw = defaults.array(forKey: Keys.servers) as? [String] {
            migratedIDs = raw.compactMap(UUID.init(uuidString:))
        } else if let raw = defaults.string(forKey: Keys.server),
                  let id = UUID(uuidString: raw) {
            migratedIDs = [id]
        } else {
            migratedIDs = []
        }
        backupServerIDs = migratedIDs
        // Persist the migrated form so later launches read one representation.
        if defaults.array(forKey: Keys.servers) == nil {
            defaults.set(migratedIDs.map(\.uuidString), forKey: Keys.servers)
        }
        includeVideos = defaults.object(forKey: Keys.videos) as? Bool ?? true
        includeScreenshots = defaults.object(forKey: Keys.screenshots) as? Bool ?? false
        faceRecognitionEnabled = defaults.object(forKey: Keys.faces) as? Bool ?? true
        let columns = defaults.object(forKey: Keys.columns) as? Int ?? 3
        gridColumns = min(max(columns, 1), 8)
        showRemoteOnlyPhotos = defaults.object(forKey: Keys.remoteOnly) as? Bool ?? true
        hasCompletedOnboarding = defaults.object(forKey: Keys.onboarded) as? Bool ?? false
    }
}
