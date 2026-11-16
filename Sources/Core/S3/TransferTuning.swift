import Foundation

#if canImport(Network)
import Network
#endif

// MARK: - Network awareness

enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
}

/// The link shape that matters for transfer tuning. `constrained` covers Low
/// Data Mode and similar policies; `expensive` covers metered links that are not
/// cellular (a personal hotspot presented as Wi-Fi, for example).
enum NetworkKind: String, Codable, Sendable, CaseIterable {
    case wired
    case wifi
    case cellular
    case expensive
    case constrained
    case unknown

    var displayName: String { rawValue }
}

struct NetworkSnapshot: Equatable, Sendable {
    var kind: NetworkKind = .unknown
    var isExpensive = false
    var isConstrained = false
    var hasPath = false

    static let unknown = NetworkSnapshot()
}

/// Observes `NWPathMonitor` and exposes a value snapshot. When Network is
/// unavailable (or the monitor has not delivered a path yet) the snapshot is
/// `.unknown`, which still produces a safe, working plan.
final class TransferNetworkMonitor: @unchecked Sendable {
    static let shared = TransferNetworkMonitor()

    private let lock = NSLock()
    private var snapshot: NetworkSnapshot = .unknown
    private var started = false
    private let queue = DispatchQueue(label: "dev.oscartbeaumont.backu.transfer-network", qos: .utility)

    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    init() {}

    func current() -> NetworkSnapshot {
        lock.lock()
        let value = snapshot
        lock.unlock()
        startIfNeeded()
        return value
    }

    /// Test seam: lets the planner be exercised without a real interface.
    func setSnapshotForTesting(_ value: NetworkSnapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func startIfNeeded() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(path)
        }
        monitor.start(queue: queue)
        lock.lock()
        self.monitor = monitor
        lock.unlock()
        #endif
    }

    deinit {
        #if canImport(Network)
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
        #endif
    }

    #if canImport(Network)
    private func apply(_ path: NWPath) {
        var next = NetworkSnapshot()
        guard path.status == .satisfied else {
            lock.lock()
            snapshot = next
            lock.unlock()
            return
        }
        next.hasPath = true
        next.isExpensive = path.isExpensive
        next.isConstrained = path.isConstrained
        if path.isConstrained {
            next.kind = .constrained
        } else if path.usesInterfaceType(.cellular) {
            next.kind = .cellular
        } else if path.isExpensive {
            next.kind = .expensive
        } else if path.usesInterfaceType(.wiredEthernet) {
            next.kind = .wired
        } else if path.usesInterfaceType(.wifi) {
            next.kind = .wifi
        } else {
            next.kind = .unknown
        }
        lock.lock()
        snapshot = next
        lock.unlock()
    }
    #endif
}

// MARK: - Plan

struct TransferPlan: Equatable, Sendable {
    var direction: TransferDirection
    var partSize: Int64
    var concurrency: Int
    var partCount: Int
    /// Downloads only: false keeps the single-stream path (small objects and
    /// low-RTT links, where extra requests cost more than they win).
    var parallel: Bool
    var network: NetworkKind
    /// Aggregate bytes/second from the last comparable transfer, if known.
    var estimatedBytesPerSecond: Double?
    var reason: String

    var isSingleStream: Bool { concurrency <= 1 || !parallel }

    static func single(
        _ direction: TransferDirection,
        size: Int64,
        network: NetworkKind,
        reason: String
    ) -> TransferPlan {
        TransferPlan(
            direction: direction,
            partSize: max(size, 0),
            concurrency: 1,
            partCount: size > 0 ? 1 : 0,
            parallel: false,
            network: network,
            estimatedBytesPerSecond: nil,
            reason: reason
        )
    }
}

/// Pure decisions about part size, range count and concurrency. No I/O and no
/// globals, so the rules are directly testable.
struct TransferPlanner: Sendable {
    /// S3 requires every part except the last to be at least 5 MiB.
    static let minimumUploadPartSize: Int64 = 5 * 1024 * 1024
    /// Ranges have no S3 minimum; 1 MiB keeps small parallel downloads useful.
    static let minimumDownloadRangeSize: Int64 = 1024 * 1024
    static let maximumPartSize: Int64 = 64 * 1024 * 1024
    static let maximumParts = 10_000
    static let uploadMultipartThreshold: Int64 = 16 * 1024 * 1024
    static let downloadParallelThreshold: Int64 = 8 * 1024 * 1024
    /// Aim for a part that takes roughly this long on one connection. Larger
    /// parts save requests; smaller parts keep every connection busy.
    static let targetSecondsPerUnit: Double = 8
    /// Hard ceiling across both directions, matching the client's URLSession
    /// pool. More sockets than this just queue.
    static let connectionBudget = 10

    struct Input: Sendable {
        var size: Int64
        var direction: TransferDirection
        var network: NetworkSnapshot
        /// Aggregate throughput observed at `measuredConcurrency`, bytes/second.
        var throughput: Double?
        var measuredConcurrency: Int?
        var latency: TimeInterval?
        var minimumLatencyForParallel: TimeInterval = 0.008
        /// Caller-supplied upper bound (`concurrency:` on the old APIs).
        var concurrencyCap: Int?

        init(
            size: Int64,
            direction: TransferDirection,
            network: NetworkSnapshot = .unknown,
            throughput: Double? = nil,
            measuredConcurrency: Int? = nil,
            latency: TimeInterval? = nil,
            minimumLatencyForParallel: TimeInterval = 0.008,
            concurrencyCap: Int? = nil
        ) {
            self.size = size
            self.direction = direction
            self.network = network
            self.throughput = throughput
            self.measuredConcurrency = measuredConcurrency
            self.latency = latency
            self.minimumLatencyForParallel = minimumLatencyForParallel
            self.concurrencyCap = concurrencyCap
        }
    }

    static func plan(_ input: Input) -> TransferPlan {
        let size = max(0, input.size)
        let network = input.network.kind
        let isDownload = input.direction == .download

        guard size > 0 else {
            return .single(input.direction, size: 0, network: network, reason: "empty object")
        }

        if isDownload {
            let threshold = downloadParallelThreshold
            guard size >= threshold else {
                return .single(input.direction, size: size, network: network, reason: "below \(megabytes(threshold)) MiB parallel threshold")
            }
            guard let latency = input.latency,
                  latency >= max(0, input.minimumLatencyForParallel) else {
                return .single(input.direction, size: size, network: network, reason: "low round-trip link")
            }
        } else if size < uploadMultipartThreshold {
            return .single(input.direction, size: size, network: network, reason: "single PUT")
        }

        let minimumUnit = isDownload ? minimumDownloadRangeSize : minimumUploadPartSize
        var concurrency = desiredConcurrency(
            direction: input.direction,
            network: input.network,
            size: size
        )
        if let cap = input.concurrencyCap, cap > 0 {
            concurrency = min(concurrency, cap)
        }
        concurrency = max(1, min(concurrency, connectionBudget))

        // Do not plan more connections than the object can feed with useful
        // chunks. This is what turns 32 MiB into six ~5.3 MiB parts instead of
        // one part per connection with an idle tail.
        let feedable = Int(max(1, size / minimumUnit))
        let wantedParts = max(1, min(concurrency, feedable))
        concurrency = min(concurrency, wantedParts)

        let perConnection = perConnectionThroughput(
            input.throughput,
            concurrency: input.measuredConcurrency ?? concurrency
        )
        // Without history, 8 MiB is a safe middle ground: it is S3's default
        // part size and finishes in a couple of seconds on almost any link.
        let ideal = perConnection.map { Int64(targetSecondsPerUnit * $0) } ?? (8 * 1024 * 1024)
        var partSize = min(ideal, maximumPartSize)
        partSize = max(partSize, minimumUnit)

        // At least the planned number of parts for a file that can support it.
        let maximumForConcurrency = ceilDiv(size, Int64(max(wantedParts, 1)))
        partSize = min(partSize, maximumForConcurrency)
        partSize = max(partSize, minimumUnit)

        // S3 caps multipart uploads at 10,000 parts; never exceed that, even if
        // it means parts larger than the normal ceiling.
        let minimumForPartCap = ceilDiv(size, Int64(maximumParts))
        if minimumForPartCap > partSize {
            partSize = minimumForPartCap
        }
        partSize = max(partSize, 1)

        let partCount = Int(ceilDiv(size, partSize))
        let effectiveConcurrency = max(1, min(concurrency, partCount))

        let throughputDescription = perConnection.map {
            String(format: "%.1f MB/s/connection", $0 / 1_000_000)
        } ?? "no history"
        let reason = "\(network.displayName), \(throughputDescription), \(partCount) part\(partCount == 1 ? "" : "s") of \(megabytes(partSize)) MiB"

        return TransferPlan(
            direction: input.direction,
            partSize: partSize,
            concurrency: effectiveConcurrency,
            partCount: partCount,
            parallel: isDownload ? partCount > 1 : true,
            network: network,
            estimatedBytesPerSecond: input.throughput,
            reason: reason
        )
    }

    static func desiredConcurrency(
        direction: TransferDirection,
        network: NetworkSnapshot,
        size: Int64
    ) -> Int {
        let large = size >= 64 * 1024 * 1024
        switch network.kind {
        case .wired:
            return 8
        case .wifi, .unknown:
            return large ? 8 : 6
        case .cellular:
            // Four streams fills a typical mobile link without inviting
            // bufferbloat; more is usually counter-productive on radio.
            return 4
        case .expensive:
            return 3
        case .constrained:
            return 2
        }
    }

    private static func perConnectionThroughput(_ aggregate: Double?, concurrency: Int) -> Double? {
        guard let aggregate, aggregate > 0 else { return nil }
        return aggregate / Double(max(1, concurrency))
    }

    static func ceilDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        guard divisor > 0 else { return value }
        return (value + divisor - 1) / divisor
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Per-server memory

struct TransferSample: Codable, Equatable, Sendable {
    /// Aggregate bytes per second at `concurrency`.
    var throughput: Double
    var concurrency: Int
}

struct TransferTuningState: Codable, Equatable, Sendable {
    var network: NetworkKind
    var upload: TransferSample?
    var download: TransferSample?
}

/// Small, lock-guarded store keyed by endpoint + bucket. Persisting the EWMA
/// means the first transfer after launch already uses sane part sizes instead
/// of starting from a guess.
final class TransferTuningStore: @unchecked Sendable {
    enum Persistence {
        case memory
        case userDefaults(UserDefaults, key: String)
    }

    private let lock = NSLock()
    private let persistence: Persistence
    private var states: [String: TransferTuningState] = [:]
    /// `UserDefaults` can block for milliseconds; never charge that to the
    /// transfer that just finished. Writes are serialised and last-write-wins.
    private let persistenceQueue = DispatchQueue(
        label: "dev.oscartbeaumont.backu.transfer-tuning-persist",
        qos: .utility
    )

    init(persistence: Persistence = .memory) {
        self.persistence = persistence
        self.states = Self.load(persistence)
    }

    func state(for key: String) -> TransferTuningState? {
        lock.lock()
        defer { lock.unlock() }
        return states[key]
    }

    func setState(_ state: TransferTuningState?, for key: String) {
        lock.lock()
        if let state {
            states[key] = state
        } else {
            states.removeValue(forKey: key)
        }
        let snapshot = states
        lock.unlock()
        persist(snapshot)
    }

    func reset() {
        lock.lock()
        states.removeAll()
        lock.unlock()
        persist([:])
    }

    /// Waits for pending asynchronous writes. Used by tests and by the app on
    /// background/termination so the next launch starts tuned.
    func flushPersistence() {
        persistenceQueue.sync {}
    }

    private func persist(_ snapshot: [String: TransferTuningState]) {
        guard case let .userDefaults(defaults, key) = persistence else { return }
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private static func load(_ persistence: Persistence) -> [String: TransferTuningState] {
        guard case let .userDefaults(defaults, key) = persistence,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: TransferTuningState].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

/// Combines the planner with the per-server history and the current link.
struct TransferTuning: Sendable {
    var store: TransferTuningStore
    var networkProvider: @Sendable () -> NetworkSnapshot

    static let shared = TransferTuning(
        store: TransferTuningStore(
            persistence: .userDefaults(.standard, key: "backu.transfer.tuning.v1")
        ),
        networkProvider: { TransferNetworkMonitor.shared.current() }
    )

    static let inMemory = TransferTuning(
        store: TransferTuningStore(persistence: .memory),
        networkProvider: { .unknown }
    )

    init(store: TransferTuningStore, networkProvider: @escaping @Sendable () -> NetworkSnapshot) {
        self.store = store
        self.networkProvider = networkProvider
    }

    var currentNetwork: NetworkSnapshot {
        networkProvider()
    }

    func plan(
        serverKey: String,
        direction: TransferDirection,
        size: Int64,
        latency: TimeInterval? = nil,
        minimumLatencyForParallel: TimeInterval = 0.008,
        concurrencyCap: Int? = nil
    ) -> TransferPlan {
        let network = networkProvider()
        let state = stateForPlanning(serverKey: serverKey, network: network)
        let sample = direction == .upload ? state?.upload : state?.download
        return TransferPlanner.plan(
            TransferPlanner.Input(
                size: size,
                direction: direction,
                network: network,
                throughput: sample?.throughput,
                measuredConcurrency: sample?.concurrency,
                latency: latency,
                minimumLatencyForParallel: minimumLatencyForParallel,
                concurrencyCap: concurrencyCap
            )
        )
    }

    /// Feed the result of a finished transfer back in. `seconds` should cover
    /// the whole operation, including request setup, because that is what the
    /// user waits for.
    func record(
        serverKey: String,
        direction: TransferDirection,
        bytes: Int64,
        seconds: TimeInterval,
        plan: TransferPlan
    ) {
        guard bytes > 0, seconds > 0 else { return }
        let network = networkProvider()
        let observed = Double(bytes) / seconds
        var state = stateForPlanning(serverKey: serverKey, network: network)
            ?? TransferTuningState(network: network.kind)
        let previous = direction == .upload ? state.upload : state.download
        let alpha = previous == nil ? 1.0 : 0.35
        let throughput = previous.map { $0.throughput * (1 - alpha) + observed * alpha } ?? observed
        let sample = TransferSample(
            throughput: throughput,
            concurrency: max(1, plan.concurrency)
        )
        if direction == .upload {
            state.upload = sample
        } else {
            state.download = sample
        }
        state.network = network.kind
        store.setState(state, for: serverKey)
    }

    func reset(serverKey: String) {
        store.setState(nil, for: serverKey)
    }

    private func stateForPlanning(serverKey: String, network: NetworkSnapshot) -> TransferTuningState? {
        guard let state = store.state(for: serverKey) else { return nil }
        // A link change invalidates throughput measured on the old link, but not
        // the fact that this server is reachable. Drop the samples, keep going
        // with the conservative defaults for the new type.
        if state.network != network.kind {
            let reset = TransferTuningState(network: network.kind)
            store.setState(reset, for: serverKey)
            return reset
        }
        return state
    }
}

extension S3Connection {
    /// Endpoint + bucket, stable across launches and independent of the display
    /// name or credentials.
    var transferTuningKey: String {
        let host = endpoint?.host ?? "unknown"
        let port = endpoint?.port.map { ":\($0)" } ?? ""
        let path = endpoint?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let suffix = path.isEmpty ? "" : "/\(path)"
        return "\(host)\(port)\(suffix)/\(bucket)"
    }
}
