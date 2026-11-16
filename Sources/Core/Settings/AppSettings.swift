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
    var backupServerID: UUID? {
        didSet { defaults.set(backupServerID?.uuidString, forKey: Keys.server) }
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
        if let raw = defaults.string(forKey: Keys.server) {
            backupServerID = UUID(uuidString: raw)
        } else {
            backupServerID = nil
        }
        includeVideos = defaults.object(forKey: Keys.videos) as? Bool ?? true
        includeScreenshots = defaults.object(forKey: Keys.screenshots) as? Bool ?? false
        faceRecognitionEnabled = defaults.object(forKey: Keys.faces) as? Bool ?? true
        let columns = defaults.object(forKey: Keys.columns) as? Int ?? 3
        gridColumns = min(max(columns, 2), 8)
        showRemoteOnlyPhotos = defaults.object(forKey: Keys.remoteOnly) as? Bool ?? true
        hasCompletedOnboarding = defaults.object(forKey: Keys.onboarded) as? Bool ?? false
    }
}
