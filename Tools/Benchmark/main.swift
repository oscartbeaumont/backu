import Foundation

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
    var endpoint = URL(string: "http://127.0.0.1:9101")!
    var bucket = "backu-test"
    var accessKey = "testkey"
    var secret = "testsecret"
    var region = "us-east-1"
    var profile = "shaped"
    var mode = "baseline"
    var sizes = [4, 32, 128]
    var runs = 3
    var warmups = 1
    var concurrency = 4
    var partSizeMB = 8
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
            case "--concurrency": options.concurrency = max(1, Int(value()) ?? 4)
            case "--part-size-mb": options.partSizeMB = max(5, Int(value()) ?? 8)
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

      --endpoint URL        default http://127.0.0.1:9101
      --bucket NAME         default backu-test
      --access-key KEY      default testkey
      --secret SECRET       default testsecret
      --region REGION       default us-east-1
      --profile NAME        label written to the report (shaped, localhost)
      --mode MODE           baseline, new or both (default baseline)
      --sizes LIST          comma-separated MiB sizes (default 4,32,128)
      --runs N              measured runs (default 3)
      --warmups N           warm-up runs (default 1)
      --concurrency N       parallel parts/ranges (default 4)
      --part-size-mb N      multipart part size (default 8)
      --output PATH         JSON report path
      --prefix KEY          object key prefix (default bench)
    """
}

struct Sample: Codable {
    var elapsedSeconds: Double
    var megabytesPerSecond: Double
    var requests: Int
    var retries: Int
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
    var samples: [Sample]
}

struct Report: Codable {
    var schema: String
    var generatedAt: String
    var profile: String
    var endpoint: String
    var mode: String
    var sizesMB: [Int]
    var runs: Int
    var warmups: Int
    var concurrency: Int
    var partSizeMB: Int
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

func describe(_ scenario: Scenario) -> String {
    String(
        format: "%-9s %-9s %5d MiB  %8.2f MB/s  %7.2fs  req=%-4d retry=%d",
        (scenario.mode as NSString).utf8String!,
        (scenario.operation as NSString).utf8String!,
        scenario.sizeMB,
        scenario.medianMegabytesPerSecond,
        scenario.medianElapsedSeconds,
        scenario.requests,
        scenario.retries
    )
}

func run() async -> Int32 {
    let options = Options.parse(CommandLine.arguments)
    guard options.mode == "baseline" || options.mode == "new" || options.mode == "both" else {
        print("--mode must be baseline, new or both")
        return 2
    }

    let connection = S3Connection(
        endpoint: options.endpoint,
        region: options.region,
        bucket: options.bucket,
        pathStyle: true
    )
    let credentials = S3Credentials(accessKeyID: options.accessKey, secretAccessKey: options.secret)
    let metrics = S3Metrics()
    let client = S3Client(connection: connection, credentials: credentials, metrics: metrics)

    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("backu-bench-\(options.profile)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

    var report = Report(
        schema: "backu.benchmark.v1",
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        profile: options.profile,
        endpoint: options.endpoint.absoluteString,
        mode: options.mode,
        sizesMB: options.sizes,
        runs: options.runs,
        warmups: options.warmups,
        concurrency: options.concurrency,
        partSizeMB: options.partSizeMB,
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
                for runIndex in 0..<(options.warmups + options.runs) {
                    let measured = runIndex >= options.warmups
                    metrics.reset()
                    let started = Date()
                    do {
                        if operation == "upload" {
                            try await upload(
                                options: options,
                                client: client,
                                source: source,
                                sizeMB: sizeMB,
                                mode: mode,
                                runIndex: runIndex
                            )
                        } else {
                            try await download(
                                options: options,
                                client: client,
                                key: seedKey,
                                sizeMB: sizeMB,
                                mode: mode,
                                runIndex: runIndex,
                                workDirectory: workDirectory
                            )
                        }
                    } catch {
                        print("\(mode) \(operation) \(sizeMB) MiB failed: \(error)")
                        return 1
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    let snapshot = metrics.snapshot()
                    if measured {
                        samples.append(
                            Sample(
                                elapsedSeconds: elapsed,
                                megabytesPerSecond: megabytes(bytes) / elapsed,
                                requests: snapshot.requests,
                                retries: snapshot.retries
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
    return "Tools/Benchmark/results/pass1-\(options.profile)-\(stamp).json"
}

func upload(
    options: Options,
    client: S3Client,
    source: URL,
    sizeMB: Int,
    mode: String,
    runIndex: Int
) async throws {
    let key = "\(options.prefix)/upload/\(sizeMB)/\(mode)-\(runIndex).bin"
    if mode == "baseline" {
        _ = try await client.putFile(key: key, fileURL: source, contentType: "application/octet-stream")
        return
    }
    let uploader = MultipartUploader(
        client: client,
        partSize: options.partSizeMB * 1024 * 1024,
        concurrency: options.concurrency,
        threshold: MultipartUploader.defaultThreshold
    )
    _ = try await uploader.upload(fileURL: source, key: key, contentType: "application/octet-stream")
}

func download(
    options: Options,
    client: S3Client,
    key: String,
    sizeMB: Int,
    mode: String,
    runIndex: Int,
    workDirectory: URL
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
        concurrency: options.concurrency
    )
}

exit(await run())
