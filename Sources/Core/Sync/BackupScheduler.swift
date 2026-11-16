import Foundation

#if os(iOS)
import BackgroundTasks
#endif

/// Schedules best-effort automatic backups while Backu is not open.
enum BackupScheduler {
    static let identifier = "dev.oscartbeaumont.backu.backup"

    #if os(iOS)
    static func register(expire: @escaping () -> Void, handler: @escaping (@escaping () -> Void) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            task.expirationHandler = expire
            let completion = {
                task.setTaskCompleted(success: true)
                schedule()
            }
            handler(completion)
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 30)
        try? BGTaskScheduler.shared.submit(request)
    }
    #else
    static func register(expire: @escaping () -> Void, handler: @escaping (@escaping () -> Void) -> Void) {}
    static func schedule() {}
    #endif
}
