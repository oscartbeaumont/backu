import Foundation

#if os(iOS)
import BackgroundTasks
#endif

/// Schedules best-effort automatic backups while Backu is not in the foreground.
enum BackupScheduler {
    static let identifier = "dev.oscartbeaumont.backu.backup"

    #if os(iOS)
    /// The handler receives a one-shot completion. The scheduler guards against
    /// calling `setTaskCompleted` twice if iOS expires the task while the run is
    /// still winding down.
    static func register(
        expire: @escaping () -> Void,
        handler: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            var finished = false
            let complete: (Bool) -> Void = { success in
                guard !finished else { return }
                finished = true
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = {
                expire()
                complete(false)
            }
            handler { success in complete(success) }
        }
    }

    /// Cancels the pending request (a running task is unaffected) and asks iOS
    /// for a new processing window. Pass a short delay when photos are waiting.
    static func schedule(after delay: TimeInterval = 30 * 60) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(60, delay))
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    #else
    static func register(
        expire: @escaping () -> Void,
        handler: @escaping (@escaping (Bool) -> Void) -> Void
    ) {}
    static func schedule(after delay: TimeInterval = 30 * 60) {}
    static func cancel() {}
    #endif
}
