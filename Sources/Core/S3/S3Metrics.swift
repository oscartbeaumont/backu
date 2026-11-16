import Foundation

/// Thread-safe counters for one client. The app ignores them; the benchmark
/// uses them to prove how many HTTP requests and retries a transfer took.
final class S3Metrics: @unchecked Sendable {
    struct Snapshot: Sendable, Codable, Equatable {
        var requests: Int
        var retries: Int
        var transportFailures: Int
        var retryableResponses: Int
    }

    private let lock = NSLock()
    private var requests = 0
    private var retries = 0
    private var transportFailures = 0
    private var retryableResponses = 0

    init() {}

    func recordRequest() {
        lock.lock()
        requests += 1
        lock.unlock()
    }

    func recordRetry() {
        lock.lock()
        retries += 1
        lock.unlock()
    }

    func recordTransportFailure() {
        lock.lock()
        transportFailures += 1
        lock.unlock()
    }

    func recordRetryableResponse() {
        lock.lock()
        retryableResponses += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            requests: requests,
            retries: retries,
            transportFailures: transportFailures,
            retryableResponses: retryableResponses
        )
    }

    func reset() {
        lock.lock()
        requests = 0
        retries = 0
        transportFailures = 0
        retryableResponses = 0
        lock.unlock()
    }
}
