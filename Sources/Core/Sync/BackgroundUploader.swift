import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Uploads large files through a background URLSession so a backup keeps going
/// when Backu leaves the foreground. Errors are reported as HTTP status codes;
/// small metadata writes go through the regular client instead.
final class BackgroundUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let sessionIdentifier = "dev.oscartbeaumont.backu.uploads"

    /// Set by the app delegate so iOS can resume events after relaunch.
    static var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var continuations: [String: CheckedContinuation<Int, Error>] = [:]
    private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]
    private var session: URLSession?
    private var sessionAllowsCellular = false
    private var nextJobID = 0

    struct HTTPStatusError: LocalizedError {
        var status: Int
        var errorDescription: String? {
            switch status {
            case 401, 403: return "The storage service rejected the upload (HTTP \(status)). Check the key permissions."
            case 404: return "The bucket or folder was not found (HTTP 404)."
            case 507: return "The bucket is out of space (HTTP 507)."
            default: return "Upload failed with HTTP \(status)."
            }
        }
    }

    /// Recreates the session when the network policy changes.
    func configure(allowsCellular: Bool) {
        lock.lock()
        let pending = !continuations.isEmpty
        if session != nil && sessionAllowsCellular == allowsCellular { lock.unlock(); return }
        if pending { lock.unlock(); return }
        session?.invalidateAndCancel()
        session = nil
        sessionAllowsCellular = allowsCellular
        lock.unlock()
    }

    private var usesForegroundSession: Bool {
        #if targetEnvironment(simulator)
        // The Simulator's background session daemon is unreliable, and tests
        // need deterministic transfers. Real devices use a background session.
        return true
        #else
        return ProcessInfo.processInfo.environment["BACKU_FOREGROUND_UPLOADS"] == "1"
        #endif
    }

    private func makeSession() -> URLSession {
        let configuration: URLSessionConfiguration
        if usesForegroundSession {
            configuration = URLSessionConfiguration.default
        } else {
            configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        }
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = sessionAllowsCellular
        configuration.allowsExpensiveNetworkAccess = sessionAllowsCellular
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func currentSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let created = makeSession()
        session = created
        return created
    }

    @discardableResult
    func upload(
        fileURL: URL,
        request: URLRequest,
        allowsCellular: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        configure(allowsCellular: allowsCellular)
        let session = currentSession()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            nextJobID += 1
            let jobID = "job-\(nextJobID)"
            continuations[jobID] = continuation
            progressHandlers[jobID] = progress
            lock.unlock()

            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.taskDescription = jobID
            task.resume()
        }
    }

    func cancelAll() {
        lock.lock()
        let handlers = continuations
        continuations.removeAll()
        progressHandlers.removeAll()
        lock.unlock()
        for (_, continuation) in handlers {
            continuation.resume(throwing: CancellationError())
        }
        currentSession().getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// Called when the app is dismissed while background transfers are in flight.
    func handleEvents(completionHandler: @escaping () -> Void) {
        Self.backgroundCompletionHandler = completionHandler
        _ = currentSession()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let jobID = task.taskDescription else { return }
        let fraction = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0
        lock.lock()
        let handler = progressHandlers[jobID]
        lock.unlock()
        handler?(min(max(fraction, 0), 1))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobID = task.taskDescription else { return }
        lock.lock()
        let continuation = continuations.removeValue(forKey: jobID)
        progressHandlers[jobID] = nil
        lock.unlock()
        guard let continuation else { return }

        if let error {
            continuation.resume(throwing: error)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if (200..<300).contains(status) {
            continuation.resume(returning: status)
        } else {
            continuation.resume(throwing: HTTPStatusError(status: status))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = Self.backgroundCompletionHandler
            Self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}

enum DeviceInfo {
    static var name: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    static var model: String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }
}
