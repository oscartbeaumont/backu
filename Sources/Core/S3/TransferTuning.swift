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
    /// Uploads only: parts are staged in the temporary directory instead of
    /// being held in memory, because `concurrency * partSize` exceeds the
    /// payload budget. Streaming from disk keeps the plan (and therefore the
    /// throughput) while bounding peak memory.
    var stagesParts: Bool = false

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
    /// A share of the object worth one connection. Uploads cannot go below the
    /// 5 MiB S3 minimum, so a 32 MiB upload feeds 7 lanes (6 x 5 MiB + 2 MiB).
    /// Downloads use 4 MiB ranges: small enough that a 32 MiB object fills 8
    /// connections, large enough that request overhead stays negligible.
    static let uploadWorkPerConnection = minimumUploadPartSize
    static let downloadWorkPerConnection: Int64 = 4 * 1024 * 1024
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
    /// Connections a first (unmeasured) transfer may use. Going beyond this is
    /// only worth it once the previous transfer proved the link still scales.
    static let unmeasuredConcurrencyCeiling = 8
    /// How many connections a proven-scaling transfer adds, and how many each
    /// failed transfer gives back.
    static let concurrencyStep = 2
    /// A transfer at this concurrency counts as evidence that the link
    /// tolerated a wide fan-out.
    static let evidenceConcurrency = unmeasuredConcurrencyCeiling
    /// The latest transfer must stay within this fraction of the best
    /// throughput and best per-connection throughput ever seen, otherwise more
    /// connections are not helping and the plan stops growing.
    static let scalingTolerance = 0.85
    /// Peak part payload the direct (in-memory) transport may hold.
    static func memoryBudget(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int64 {
        let ramShare = Int64(clamping: physicalMemory / 16)
        return min(96 * 1024 * 1024, max(8 * 1024 * 1024, ramShare))
    }

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
        /// Upper bound for this plan. `TransferTuning` raises it to
        /// `connectionBudget` once the previous transfer showed linear scaling.
        var concurrencyCeiling: Int = TransferPlanner.unmeasuredConcurrencyCeiling
        /// Consecutive failed transfers; each one gives back a growth step.
        var concurrencyPenalty: Int = 0
        /// Peak payload budget; upload parts are staged to disk above this.
        var memoryBudget: Int64 = TransferPlanner.memoryBudget()

        init(
            size: Int64,
            direction: TransferDirection,
            network: NetworkSnapshot = .unknown,
            throughput: Double? = nil,
            measuredConcurrency: Int? = nil,
            latency: TimeInterval? = nil,
            minimumLatencyForParallel: TimeInterval = 0.008,
            concurrencyCap: Int? = nil,
            concurrencyCeiling: Int = TransferPlanner.unmeasuredConcurrencyCeiling,
            concurrencyPenalty: Int = 0,
            memoryBudget: Int64 = TransferPlanner.memoryBudget()
        ) {
            self.size = size
            self.direction = direction
            self.network = network
            self.throughput = throughput
            self.measuredConcurrency = measuredConcurrency
            self.latency = latency
            self.minimumLatencyForParallel = minimumLatencyForParallel
            self.concurrencyCap = concurrencyCap
            self.concurrencyCeiling = concurrencyCeiling
            self.concurrencyPenalty = concurrencyPenalty
            self.memoryBudget = memoryBudget
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
        let workPerConnection = isDownload ? downloadWorkPerConnection : uploadWorkPerConnection
        let allowance = max(1, min(input.concurrencyCeiling, connectionBudget))

        var concurrency = desiredConcurrency(
            direction: input.direction,
            network: input.network,
            size: size,
            ceiling: allowance
        )
        if input.concurrencyPenalty > 0 {
            // A flaky link does not need fewer bytes in flight, it needs fewer
            // sockets competing. Back off one growth step per failure.
            concurrency = max(1, concurrency - concurrencyStep * input.concurrencyPenalty)
        }
        if let cap = input.concurrencyCap, cap > 0 {
            concurrency = min(concurrency, cap)
        }
        concurrency = max(1, min(concurrency, allowance))

        // Do not plan more connections than the object can feed with useful
        // chunks. The ceiling (not the floor) is what matters: only the last
        // part may be smaller than 5 MiB, so a 32 MiB upload feeds 7 lanes.
        let feedable = Int(max(1, ceilDiv(size, workPerConnection)))
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

        // At least the planned number of parts for a file that can support it,
        // but never so small that a non-final upload part breaks the 5 MiB rule.
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

        // Balance the waves. If the ideal part size would need more parts than
        // there are connections, growing the parts until the count is a multiple
        // of the connection count removes the idle tail wave (a 100 MiB upload
        // at 8 connections becomes 8 x 12.5 MiB instead of 13 x 8 MiB, where the
        // last wave only has five sockets busy).
        let wanted = max(1, wantedParts)
        let unalignedParts = Int(ceilDiv(size, partSize))
        if wanted > 1, unalignedParts > wanted {
            let waves = max(1, unalignedParts / wanted)
            let balancedParts = waves * wanted
            let balancedPartSize = ceilDiv(size, Int64(balancedParts))
            if balancedPartSize > partSize {
                partSize = balancedPartSize
            }
        }

        let partCount = Int(ceilDiv(size, partSize))
        var effectiveConcurrency = max(1, min(concurrency, partCount))

        // Keep every planned connection inside the payload budget. Downloads
        // stream straight to disk, so only the upload path can stage. URLSession
        // keeps its own copy of each in-memory body while it sends it, so the
        // real peak is about twice the part payload — budget for both.
        var stagesParts = false
        if !isDownload, Int64(effectiveConcurrency) * partSize * 2 > input.memoryBudget {
            // Prefer moving the payload to disk over collapsing the plan: fewer
            // connections cost far more time than writing parts we were going
            // to send anyway. Only shrink the plan if a single part alone is
            // over budget, which the 64 MiB ceiling makes unlikely.
            stagesParts = true
            if partSize * 2 > input.memoryBudget {
                let reduced = max(1, Int(input.memoryBudget / (partSize * 2)))
                effectiveConcurrency = min(effectiveConcurrency, reduced)
            }
        }

        let throughputDescription = perConnection.map {
            String(format: "%.1f MB/s/connection", $0 / 1_000_000)
        } ?? "no history"
        let staging = stagesParts ? ", staged parts" : ""
        let reason = "\(network.displayName), \(throughputDescription), \(partCount) part\(partCount == 1 ? "" : "s") of \(megabytes(partSize)) MiB\(staging)"

        return TransferPlan(
            direction: input.direction,
            partSize: partSize,
            concurrency: effectiveConcurrency,
            partCount: partCount,
            parallel: isDownload ? partCount > 1 : true,
            network: network,
            estimatedBytesPerSecond: input.throughput,
            reason: reason,
            stagesParts: stagesParts
        )
    }

    static func desiredConcurrency(
        direction: TransferDirection,
        network: NetworkSnapshot,
        size: Int64,
        ceiling: Int = TransferPlanner.unmeasuredConcurrencyCeiling
    ) -> Int {
        let allowance = max(1, min(ceiling, connectionBudget))
        switch network.kind {
        case .wired, .wifi, .unknown:
            // Wired and Wi-Fi are unmetered and the link scales with sockets,
            // so fill the allowance. The feedable clamp keeps small objects
            // from opening sockets they cannot use.
            return allowance
        case .cellular:
            // Four streams fills a typical mobile link without inviting
            // bufferbloat; more is usually counter-productive on radio.
            return min(4, allowance)
        case .expensive:
            return min(3, allowance)
        case .constrained:
            return min(2, allowance)
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
    /// Aggregate bytes per second at `concurrency`, smoothed with an EWMA.
    var throughput: Double
    var concurrency: Int
    /// Best aggregate throughput ever seen for this server and direction.
    var peakThroughput: Double?
    /// Best aggregate throughput divided by the concurrency it was measured at.
    /// A falling per-connection figure is the signal that more sockets are
    /// stealing from each other rather than adding capacity.
    var peakPerConnection: Double?
    /// Raw (unsmoothed) rate of the most recent transfer. The EWMA above is for
    /// part sizing; scaling decisions must compare like with like.
    var lastObservedThroughput: Double?

    init(
        throughput: Double,
        concurrency: Int,
        peakThroughput: Double? = nil,
        peakPerConnection: Double? = nil,
        lastObservedThroughput: Double? = nil
    ) {
        self.throughput = throughput
        self.concurrency = concurrency
        self.peakThroughput = peakThroughput
        self.peakPerConnection = peakPerConnection
        self.lastObservedThroughput = lastObservedThroughput
    }
}

struct TransferTuningState: Codable, Equatable, Sendable {
    var network: NetworkKind
    var upload: TransferSample?
    var download: TransferSample?
    /// Consecutive failed transfers. Each one costs the next plan a growth step,
    /// so a flaky link falls back to fewer sockets instead of retrying a wide
    /// fan-out that keeps timing out.
    var uploadFailures: Int? = nil
    var downloadFailures: Int? = nil
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
        concurrencyCap: Int? = nil,
        memoryBudget: Int64 = TransferPlanner.memoryBudget()
    ) -> TransferPlan {
        let network = networkProvider()
        let state = stateForPlanning(serverKey: serverKey, network: network)
        let sample = direction == .upload ? state?.upload : state?.download
        let failures = (direction == .upload ? state?.uploadFailures : state?.downloadFailures) ?? 0
        return TransferPlanner.plan(
            TransferPlanner.Input(
                size: size,
                direction: direction,
                network: network,
                throughput: sample?.throughput,
                measuredConcurrency: sample?.concurrency,
                latency: latency,
                minimumLatencyForParallel: minimumLatencyForParallel,
                concurrencyCap: concurrencyCap,
                concurrencyCeiling: concurrencyCeiling(for: sample, network: network),
                concurrencyPenalty: failures,
                memoryBudget: memoryBudget
            )
        )
    }

    /// The last transfer is the evidence for the next one. Only a transfer that
    /// already used a wide fan-out, kept its per-connection throughput near the
    /// best ever seen and matched its best aggregate throughput proves that the
    /// link still scales; only then may the plan use more than the unmeasured
    /// ceiling (up to the connection budget).
    private func concurrencyCeiling(for sample: TransferSample?, network: NetworkSnapshot) -> Int {
        guard let sample,
              sample.concurrency >= TransferPlanner.evidenceConcurrency,
              network.kind == .wired || network.kind == .wifi || network.kind == .unknown
        else {
            return TransferPlanner.unmeasuredConcurrencyCeiling
        }
        let latest = sample.lastObservedThroughput ?? sample.throughput
        let perConnection = latest / Double(max(1, sample.concurrency))
        if let peakPerConnection = sample.peakPerConnection,
           perConnection < peakPerConnection * TransferPlanner.scalingTolerance {
            return TransferPlanner.unmeasuredConcurrencyCeiling
        }
        if let peakThroughput = sample.peakThroughput,
           latest < peakThroughput * TransferPlanner.scalingTolerance {
            return TransferPlanner.unmeasuredConcurrencyCeiling
        }
        return min(
            TransferPlanner.connectionBudget,
            sample.concurrency + TransferPlanner.concurrencyStep
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
        let observedPerConnection = observed / Double(max(1, plan.concurrency))
        let peakThroughput = max(previous?.peakThroughput ?? 0, observed)
        let peakPerConnection = max(previous?.peakPerConnection ?? 0, observedPerConnection)
        let sample = TransferSample(
            throughput: throughput,
            concurrency: max(1, plan.concurrency),
            peakThroughput: peakThroughput,
            peakPerConnection: peakPerConnection,
            lastObservedThroughput: observed
        )
        if direction == .upload {
            state.upload = sample
            state.uploadFailures = 0
        } else {
            state.download = sample
            state.downloadFailures = 0
        }
        state.network = network.kind
        store.setState(state, for: serverKey)
    }

    /// A transfer that exhausted its retries. The next plan gives back a growth
    /// step and stops trusting the wide fan-out until a success resets it.
    func penalise(serverKey: String, direction: TransferDirection) {
        let network = networkProvider()
        var state = stateForPlanning(serverKey: serverKey, network: network)
            ?? TransferTuningState(network: network.kind)
        let failures = (direction == .upload ? state.uploadFailures : state.downloadFailures) ?? 0
        let next = min(failures + 1, TransferPlanner.connectionBudget)
        if direction == .upload {
            state.uploadFailures = next
        } else {
            state.downloadFailures = next
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
