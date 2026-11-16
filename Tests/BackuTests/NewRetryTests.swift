import XCTest

final class NewRetryTests: XCTestCase {
    private func policy(
        attempts: Int = 5,
        base: TimeInterval = 0.001,
        maxDelay: TimeInterval = 1
    ) -> S3RetryPolicy {
        S3RetryPolicy(
            maxAttempts: attempts,
            baseDelay: base,
            multiplier: 2,
            maxDelay: maxDelay,
            random: { $0.upperBound }
        )
    }

    func testOnlyTransientStatusesAreRetryable() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(S3RetryPolicy.isRetryable(status: status), "\(status) should retry")
        }
        for status in [200, 301, 400, 401, 403, 404, 405, 409, 416, 501, 505] {
            XCTAssertFalse(S3RetryPolicy.isRetryable(status: status), "\(status) must not retry")
        }
    }

    func testTransportErrorsRetryButCancellationDoesNot() {
        XCTAssertTrue(S3RetryPolicy.isRetryable(error: URLError(.timedOut)))
        XCTAssertTrue(S3RetryPolicy.isRetryable(error: URLError(.networkConnectionLost)))
        XCTAssertFalse(S3RetryPolicy.isRetryable(error: CancellationError()))
        XCTAssertFalse(S3RetryPolicy.isRetryable(error: URLError(.cancelled)))
        XCTAssertFalse(
            S3RetryPolicy.isRetryable(
                error: S3Error.http(status: 403, code: "AccessDenied", message: nil, requestID: nil)
            )
        )
    }

    func testRunRetriesTransientFailuresThenSucceeds() async throws {
        var attempts = 0
        let value = try await policy().run {
            attempts += 1
            if attempts < 3 {
                throw S3Error.http(status: 503, code: "ServiceUnavailable", message: nil, requestID: nil)
            }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
    }

    func testRunGivesUpAfterMaxAttempts() async {
        var attempts = 0
        do {
            _ = try await policy(attempts: 4).run { () -> Int in
                attempts += 1
                throw S3Error.http(status: 500, code: "InternalError", message: nil, requestID: nil)
            }
            XCTFail("Expected the operation to fail")
        } catch {
            XCTAssertEqual(attempts, 4)
        }
    }

    func testRunDoesNotRetryPermanentErrors() async {
        var attempts = 0
        do {
            _ = try await policy().run { () -> Int in
                attempts += 1
                throw S3Error.http(status: 403, code: "AccessDenied", message: nil, requestID: nil)
            }
            XCTFail("Expected the operation to fail")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testFullJitterDelayIsCappedAndExponential() {
        let exponential = policy(attempts: 5, base: 0.2, maxDelay: 10)
        XCTAssertEqual(exponential.delay(forAttempt: 1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(exponential.delay(forAttempt: 2), 0.4, accuracy: 0.0001)
        XCTAssertEqual(exponential.delay(forAttempt: 3), 0.8, accuracy: 0.0001)
        XCTAssertEqual(exponential.delay(forAttempt: 4), 1.6, accuracy: 0.0001)

        let capped = policy(attempts: 10, base: 0.2, maxDelay: 10)
        XCTAssertEqual(capped.delay(forAttempt: 10), 10, accuracy: 0.0001)
    }

    func testRetryAfterSecondsAndHTTPDate() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "3"]
            )
        )
        let seconds = try XCTUnwrap(S3RetryHeaders.retryAfter(response))
        XCTAssertEqual(seconds, 3, accuracy: 0.01)

        let future = Date().addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dated = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Retry-After": formatter.string(from: future)]
            )
        )
        let dateDelay = try XCTUnwrap(S3RetryHeaders.retryAfter(dated))
        XCTAssertGreaterThan(dateDelay, 25)
        XCTAssertLessThanOrEqual(dateDelay, 31)
    }

    func testRetryAdviceDelaysTheNextAttempt() async {
        // Background URLSession part uploads surface `Retry-After` only through
        // the thrown status error; the retry loop must honour it.
        let policy = S3RetryPolicy(
            maxAttempts: 3,
            baseDelay: 0.001,
            multiplier: 2,
            maxDelay: 0.001,
            random: { _ in 0 }
        )
        var attempts = 0
        let started = Date()
        let value = try? await policy.run { () -> Int in
            attempts += 1
            if attempts == 1 {
                throw BackgroundUploader.HTTPStatusError(status: 429, retryAfter: 0.05)
            }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(attempts, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.045)
    }

    func testParallelTransfersRetryLongerThanMetadataRequests() {
        // A range or part is one of many requests; a single unlucky response
        // must not fail the object, so it gets a longer budget than a HEAD.
        XCTAssertGreaterThan(
            S3RetryPolicy.parallelTransfer.maxAttempts,
            S3RetryPolicy.default.maxAttempts
        )
        XCTAssertEqual(S3RetryPolicy.parallelTransfer.maxAttempts, 7)
    }

    func testCancellationStopsRetries() async {
        let policy = S3RetryPolicy(
            maxAttempts: 5,
            baseDelay: 2,
            multiplier: 2,
            maxDelay: 2
        )
        let task = Task { () -> Int in
            try await policy.run { () -> Int in
                throw S3Error.http(status: 503, code: "ServiceUnavailable", message: nil, requestID: nil)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancellation should have failed the retrying task")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
