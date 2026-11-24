import Foundation

#if canImport(Darwin)
import Darwin
#endif

// Standalone benchmark for Backu's S3 transfer layer.
//
// It is compiled with swiftc against the app's real sources, so the numbers come
// from the same signer and client the app ships:
//
//     swiftc -O -o /tmp/backu-bench \
//       Sources/Core/Models/StorageProvider.swift \
//       Sources/Core/Models/ServerConfig.swift \
//       Sources/Core/S3/*.swift Tools/Benchmark/main.swift
//
// Tools/Benchmark/run.sh builds it and runs the matrix against the mock bucket.

struct Options {
    /// Required. The harness never guesses a host, so a run can only measure the
    /// mock that was named for it.
    var endpoint = ProcessInfo.processInfo.environment["BACKU_BENCH_ENDPOINT"]
        .flatMap(URL.init(string:))
    var bucket = "backu-test"
    var accessKey = "testkey"
    var secret = "testsecret"
    var region = "us-east-1"
    var profile = "shaped"
    var mode = "baseline"
    var sizes = [4, 32, 128]
    var runs = 3
    var warmups = 1
    /// 0 means "let TransferTuning decide".
    var concurrency = 0
    /// 0 means "let TransferTuning decide".
    var partSizeMB = 0
    /// 0 means "let the planner derive it from physical memory".
    var memoryBudgetMB = 0
    var network = "wifi"
    var pass = "pass3"
    var output: String?
    var prefix = "bench"

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            func value() -> String {
                index += 1
                return index < arguments.count ? arguments[index] : ""
            }
            switch name {
            case "--endpoint":
                if let url = URL(string: value()) { options.endpoint = url }
            case "--bucket": options.bucket = value()
            case "--access-key": options.accessKey = value()
            case "--secret": options.secret = value()
            case "--region": options.region = value()
            case "--profile": options.profile = value()
            case "--mode": options.mode = value()
            case "--sizes":
                options.sizes = value().split(separator: ",").compactMap { Int($0) }
            case "--runs": options.runs = max(1, Int(value()) ?? 3)
            case "--warmups": options.warmups = max(0, Int(value()) ?? 1)
            case "--concurrency": options.concurrency = max(0, Int(value()) ?? 0)
            case "--part-size-mb": options.partSizeMB = max(0, Int(value()) ?? 0)
            case "--memory-budget-mb": options.memoryBudgetMB = max(0, Int(value()) ?? 0)
            case "--network": options.network = value()
            case "--pass": options.pass = value()
            case "--output": options.output = value()
            case "--prefix": options.prefix = value()
            case "--help", "-h":
                print(Options.help)
                exit(0)
            default:
                print("Unknown option \(name)\n")
                print(Options.help)
                exit(2)
            }
            index += 1
        }
        return options
    }

    static let help = """
    Usage: backu-bench --profile NAME [options]

      --endpoint URL        the mock to measure (or BACKU_BENCH_ENDPOINT)
      --bucket NAME         default backu-test
      --access-key KEY      default testkey
      --secret SECRET       default testsecret
      --region REGION       default us-east-1
      --profile NAME        label written to the report (shaped, loopback)
      --mode MODE           baseline, new or both (default baseline)
      --sizes LIST          comma-separated MiB sizes (default 4,32,128)
      --runs N              measured runs (default 3)
      --warmups N           warm-up runs (default 1)
      --concurrency N       0 = adaptive (default), >0 forces a cap
      --part-size-mb N      0 = adaptive (default), >0 forces a part size
      --memory-budget-mb N  0 = derive from RAM (default), >0 overrides the
                            in-flight part payload budget (debugging aid)
      --network NAME        wifi, wired, cellular, expensive, constrained or unknown
      --pass NAME           results prefix (default pass3)
      --output PATH         JSON report path
      --prefix KEY          object key prefix (default bench)
    """
}

struct Sample: Codable {
    var elapsedSeconds: Double
    var megabytesPerSecond: Double
    var requests: Int
    var retries: Int
    var partSizeBytes: Int64?
    var concurrency: Int?
    var partCount: Int?
    var parallel: Bool?
    /// Peak physical footprint during this transfer, from a 25 ms sampler.
    var peakFootprintBytes: Int64?
}

struct Scenario: Codable {
    var profile: String
    var operation: String
    var sizeMB: Int
    var mode: String
    var medianMegabytesPerSecond: Double
    var medianElapsedSeconds: Double
    var requests: Int
    var retries: Int
    var partSizeBytes: Int64?
    var concurrency: Int?
    var partCount: Int?
    var reason: String?
    var peakFootprintBytes: Int64?
    var samples: [Sample]
}

struct Report: Codable {
    var schema: String
    var generatedAt: String
    var profile: String
    var endpoint: String
    var mode: String
    var network: String
    var sizesMB: [Int]
    var runs: Int
    var warmups: Int
    var concurrency: Int
    var partSizeMB: Int
    var memoryBudgetMB: Int
    var scenarios: [Scenario]
}

func makeFile(at url: URL, bytes: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

func megabytes(_ bytes: Int) -> Double {
    Double(bytes) / (1024 * 1024)
}

/// Internal (anonymous) memory: what the app itself allocated. File-backed
/// pages, such as a mapped part file, are reclaimable and are excluded, so this
/// is the number that decides whether a phone gets killed under pressure.
func internalMemory() -> Int64 {
    #if canImport(Darwin)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int64(bitPattern: info.internal)
    #else
    return 0
    #endif
}

/// Samples memory while one transfer runs so the report can prove the payload
/// budget instead of asserting it.
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var task: Task<Void, Never>?

    func start() {
        peak = internalMemory()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard let self, !Task.isCancelled else { return }
                self.record(internalMemory())
            }
        }
    }

    /// Kept synchronous so the sampler never touches `NSLock` from an async
    /// context.
    private func record(_ value: Int64) {
        lock.lock()
        peak = max(peak, value)
        lock.unlock()
    }

    func stop() -> Int64 {
        task?.cancel()
        task = nil
        record(internalMemory())
        lock.lock()
        let result = peak
        lock.unlock()
        return result
    }
}

func describe(_ scenario: Scenario) -> String {
    let plan: String
    if let partSize = scenario.partSizeBytes, let concurrency = scenario.concurrency {
        plan = String(
            format: "  parts=%.2fMiB x%d (%d)",
            Double(partSize) / (1024 * 1024),
            concurrency,
            scenario.partCount ?? 0
        )
    } else {
        plan = ""
    }
    let memory: String
    if let peak = scenario.peakFootprintBytes, peak > 0 {
        memory = String(format: "  peak=%4.0fMiB", Double(peak) / (1024 * 1024))
    } else {
        memory = ""
    }
    return String(
        format: "%-9s %-9s %5d MiB  %8.2f MB/s  %7.2fs  req=%-4d retry=%-3d%@%@",
        (scenario.mode as NSString).utf8String!,
        (scenario.operation as NSString).utf8String!,
        scenario.sizeMB,
        scenario.medianMegabytesPerSecond,
        scenario.medianElapsedSeconds,
        scenario.requests,
        scenario.retries,
        plan,
        memory
    )
}

func snapshot(for network: String) -> NetworkSnapshot {
    var value = NetworkSnapshot()
    value.hasPath = true
    switch network {
    case "wired": value.kind = .wired
    case "wifi": value.kind = .wifi
    case "cellular":
        value.kind = .cellular
        value.isExpensive = true
    case "expensive":
        value.kind = .expensive
        value.isExpensive = true
    case "constrained":
        value.kind = .constrained
        value.isConstrained = true
    default: value.kind = .unknown
    }
    return value
}

final class PlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: TransferPlan?

    func set(_ value: TransferPlan) {
        lock.lock()
        plan = value
        lock.unlock()
    }

    func take() -> TransferPlan? {
        lock.lock()
        defer { lock.unlock() }
        let value = plan
        plan = nil
        return value
    }
}

/// The results file names the mock a run measured by port rather than by URL.
/// Every profile runs against the bundled MockS3, and a URL in a committed
/// result file reads as a staging backend to a release-source scan.
func recordedEndpoint(_ url: URL) -> String {
    "mock on port \(url.port ?? 0)"
}

func run() async -> Int32 {
    let options = Options.parse(CommandLine.arguments)
    guard let endpoint = options.endpoint else {
        print("--endpoint is required: name the mock this run should measure.")
        return 2
    }
    guard options.mode == "baseline" || options.mode == "new" || options.mode == "both" else {
        print("--mode must be baseline, new or both")
        return 2
    }
    guard !options.sizes.isEmpty && options.sizes.allSatisfy({ $0 > 0 }) else {
        print("--sizes must contain positive MiB values")
        return 2
    }

    let connection = S3Connection(
        endpoint: endpoint,
        region: options.region,
        bucket: options.bucket,
        pathStyle: true
    )
    let credentials = S3Credentials(accessKeyID: options.accessKey, secretAccessKey: options.secret)
    let metrics = S3Metrics()
    let client = S3Client(connection: connection, credentials: credentials, metrics: metrics)
    let link = snapshot(for: options.network)
    // In-memory history: each benchmark process starts cold, exactly like a
    // fresh install. The warm-up run is what seeds the EWMA.
    let tuning = TransferTuning(
        store: TransferTuningStore(persistence: .memory),
        networkProvider: { link }
    )

    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("backu-bench-\(options.profile)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

    var report = Report(
        schema: "backu.benchmark.v2",
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        profile: options.profile,
        endpoint: recordedEndpoint(endpoint),
        mode: options.mode,
        network: options.network,
        sizesMB: options.sizes,
        runs: options.runs,
        warmups: options.warmups,
        concurrency: options.concurrency,
        partSizeMB: options.partSizeMB,
        memoryBudgetMB: options.memoryBudgetMB,
        scenarios: []
    )

    let modes = options.mode == "both" ? ["baseline", "new"] : [options.mode]

    for sizeMB in options.sizes {
        let bytes = sizeMB * 1024 * 1024
        let source = workDirectory.appendingPathComponent("source-\(sizeMB).bin")
        do {
            try makeFile(at: source, bytes: bytes)
        } catch {
            print("Could not create \(sizeMB) MiB source: \(error)")
            return 1
        }

        let seedKey = "\(options.prefix)/objects/\(sizeMB).bin"
        do {
            _ = try await client.putFile(key: seedKey, fileURL: source, contentType: "application/octet-stream")
        } catch {
            print("Could not seed \(seedKey): \(error)")
            return 1
        }

        for mode in modes {
            for operation in ["upload", "download"] {
                var samples: [Sample] = []
                var lastPlan: TransferPlan?
                for runIndex in 0..<(options.warmups + options.runs) {
                    let measured = runIndex >= options.warmups
                    let planBox = PlanBox()
                    metrics.reset()
                    let sampler = MemorySampler()
                    sampler.start()
                    let started = Date()
                    do {
                        if operation == "upload" {
                            try await upload(
                                options: options,
                                client: client,
                                tuning: tuning,
                                source: source,
                                sizeMB: sizeMB,
                                mode: mode,
                                runIndex: runIndex,
                                workDirectory: workDirectory,
                                planBox: planBox
                            )
                        } else {
                            try await download(
                                options: options,
                                client: client,
                                tuning: tuning,
                                key: seedKey,
                                sizeMB: sizeMB,
                                mode: mode,
                                runIndex: runIndex,
                                workDirectory: workDirectory,
                                planBox: planBox
                            )
                        }
                    } catch {
                        print("\(mode) \(operation) \(sizeMB) MiB failed: \(error)")
                        return 1
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    let peakFootprint = sampler.stop()
                    let snapshot = metrics.snapshot()
                    let plan = planBox.take()
                    if let plan { lastPlan = plan }
                    if measured {
                        samples.append(
                            Sample(
                                elapsedSeconds: elapsed,
                                megabytesPerSecond: megabytes(bytes) / elapsed,
                                requests: snapshot.requests,
                                retries: snapshot.retries,
                                partSizeBytes: plan?.partSize,
                                concurrency: plan?.concurrency,
                                partCount: plan?.partCount,
                                parallel: plan?.parallel,
                                peakFootprintBytes: peakFootprint
                            )
                        )
                    }
                }
                let scenario = Scenario(
                    profile: options.profile,
                    operation: operation,
                    sizeMB: sizeMB,
                    mode: mode,
                    medianMegabytesPerSecond: median(samples.map(\.megabytesPerSecond)),
                    medianElapsedSeconds: median(samples.map(\.elapsedSeconds)),
                    requests: samples.map(\.requests).max() ?? 0,
                    retries: samples.map(\.retries).max() ?? 0,
                    partSizeBytes: lastPlan?.partSize,
                    concurrency: lastPlan?.concurrency,
                    partCount: lastPlan?.partCount,
                    reason: lastPlan?.reason,
                    peakFootprintBytes: samples.compactMap(\.peakFootprintBytes).max(),
                    samples: samples
                )
                report.scenarios.append(scenario)
                print(describe(scenario))
            }
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(report)
    let output = options.output ?? defaultOutputPath(options: options)
    let outputURL = URL(fileURLWithPath: output)
    try? FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try data.write(to: outputURL)
        print("\nJSON: \(outputURL.path)")
    } catch {
        print("Could not write \(outputURL.path): \(error)")
        return 1
    }
    return 0
}

func defaultOutputPath(options: Options) -> String {
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    return "Tools/Benchmark/results/\(options.pass)-\(options.profile)-\(stamp).json"
}

func upload(
    options: Options,
    client: S3Client,
    tuning: TransferTuning,
    source: URL,
    sizeMB: Int,
    mode: String,
    runIndex: Int,
    workDirectory: URL,
    planBox: PlanBox
) async throws {
    let key = "\(options.prefix)/upload/\(sizeMB)/\(mode)-\(runIndex).bin"
    if mode == "baseline" {
        _ = try await client.putFile(key: key, fileURL: source, contentType: "application/octet-stream")
        return
    }
    let uploader = MultipartUploader(
        client: client,
        partSize: options.partSizeMB > 0 ? options.partSizeMB * 1024 * 1024 : nil,
        concurrency: options.concurrency > 0 ? options.concurrency : nil,
        threshold: MultipartUploader.defaultThreshold,
        tuning: tuning,
        // Keep the benchmark's upload journal next to its own scratch files
        // instead of the app's Application Support copy.
        journal: MultipartUploadJournal(fileURL: workDirectory.appendingPathComponent("upload-journal.json")),
        memoryBudget: options.memoryBudgetMB > 0 ? Int64(options.memoryBudgetMB) * 1024 * 1024 : nil,
        onPlan: { plan in planBox.set(plan) }
    )
    _ = try await uploader.upload(fileURL: source, key: key, contentType: "application/octet-stream")
}

func download(
    options: Options,
    client: S3Client,
    tuning: TransferTuning,
    key: String,
    sizeMB: Int,
    mode: String,
    runIndex: Int,
    workDirectory: URL,
    planBox: PlanBox
) async throws {
    let destination = workDirectory.appendingPathComponent("download-\(sizeMB)-\(mode)-\(runIndex).bin")
    try? FileManager.default.removeItem(at: destination)
    if mode == "baseline" {
        let data = try await client.getObject(key: key)
        guard data.count == sizeMB * 1024 * 1024 else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "size mismatch"])
        }
        try data.write(to: destination)
        return
    }
    try await client.downloadObject(
        key: key,
        to: destination,
        sizeHint: Int64(sizeMB * 1024 * 1024),
        concurrency: options.concurrency,
        tuning: tuning,
        onPlan: { plan in planBox.set(plan) }
    )
}

exit(await run())
