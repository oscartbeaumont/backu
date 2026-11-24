import Foundation

/// Retry policy for S3 transfers: exponential backoff with full jitter, capped,
/// with `Retry-After` support. Only transient failures are retried; an access
/// denial or a missing key fails immediately.
struct S3RetryPolicy: Sendable {
    var maxAttempts: Int
    var baseDelay: TimeInterval
    var multiplier: Double
    var maxDelay: TimeInterval
    var random: @Sendable (ClosedRange<Double>) -> Double

    static let `default` = S3RetryPolicy(
        maxAttempts: 5,
        baseDelay: 0.2,
        multiplier: 2,
        maxDelay: 10
    )

    /// Parallel parts and ranges are one request among many, so a single
    /// unlucky request must not fail the whole transfer. At a 30% transient
    /// failure rate, five attempts fails roughly one request in 400; seven makes
    /// it one in 4000 while a genuinely dead link still gives up quickly.
    static let parallelTransfer = S3RetryPolicy(
        maxAttempts: 7,
        baseDelay: 0.2,
        multiplier: 2,
        maxDelay: 10
    )

    init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 0.2,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 10,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.random = random
    }

    /// 408 Request Timeout, 425 Too Early, 429 Slow Down, and the retryable 5xx
    /// family. 403/404 and every other 4xx are permanent for our operations.
    static func isRetryable(status: Int) -> Bool {
        switch status {
        case 408, 425, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    static func isRetryable(error: Error) -> Bool {
        if error is CancellationError { return false }
        if let s3 = error as? S3Error {
            switch s3 {
            case let .http(status, _, _, _):
                return isRetryable(status: status)
            case .transport(let underlying):
                return isRetryable(transport: underlying)
            case .decoding, .listTruncated, .invalidEndpoint, .missingCredentials:
                return false
            }
        }
        if let statusError = error as? any S3HTTPStatusProviding {
            return isRetryable(status: statusError.status)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return isRetryable(transport: error)
        }
        return false
    }

    private static func isRetryable(transport error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return true }
        switch nsError.code {
        case NSURLErrorCancelled,
             NSURLErrorBadURL,
             NSURLErrorUnsupportedURL,
             NSURLErrorUserAuthenticationRequired,
             NSURLErrorUserCancelledAuthentication,
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return false
        default:
            return true
        }
    }

    /// Full jitter: a uniform sample between zero and the capped exponential
    /// delay. This decorrelates parallel parts retrying after the same outage.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(maxAttempts, max(1, attempt))
        let ceiling = min(maxDelay, baseDelay * pow(multiplier, Double(exponent - 1)))
        guard ceiling > 0 else { return 0 }
        return random(0...ceiling)
    }

    func sleepBeforeRetry(attempt: Int, retryAfter: TimeInterval?) async throws {
        if Task.isCancelled { throw CancellationError() }
        let jittered = delay(forAttempt: attempt)
        let delay = max(jittered, retryAfter ?? 0)
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if Task.isCancelled { throw CancellationError() }
    }

    /// Runs `operation`, retrying transient failures. The operation is expected
    /// to throw `S3Error.http` for bad statuses so `Retry-After` can be read
    /// where the response is still available.
    @discardableResult
    func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                guard !(error is CancellationError),
                      attempt + 1 < maxAttempts,
                      Self.isRetryable(error: error) else {
                    throw error
                }
                attempt += 1
                let advice = (error as? any S3RetryAdviceProviding)?.retryAfter
                try await sleepBeforeRetry(attempt: attempt, retryAfter: advice)
            }
        }
    }
}

/// Errors that carry an HTTP status without importing the client's error type,
/// such as `BackgroundUploader.HTTPStatusError`.
protocol S3HTTPStatusProviding {
    var status: Int { get }
}

/// Errors that can still see a server's `Retry-After` header after the response
/// has been consumed, such as a background URLSession part upload.
protocol S3RetryAdviceProviding {
    var retryAfter: TimeInterval? { get }
}

enum S3RetryHeaders {
    /// Parses `Retry-After` as either delta-seconds or an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        formatterLock.lock()
        let date = httpDateFormatter.date(from: raw)
        formatterLock.unlock()
        guard let date else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static let formatterLock = NSLock()

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
