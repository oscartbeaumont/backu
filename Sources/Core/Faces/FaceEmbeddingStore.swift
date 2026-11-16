import Foundation

/// Append-only store for face feature vectors. Deliberately separate from the
/// catalog so biometric data stays on the device and the JSON stays small.
actor FaceEmbeddingStore {
    static let dimension = 2048

    private var offsets: [Int] = []
    private var endOffset = 8
    private var handle: FileHandle?
    private let url: URL
    private var cachedData: Data?

    init(url: URL = AppPaths.embeddingsFile) {
        self.url = url
        loadOffsets()
    }

    private func loadOffsets() {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return }
        var cursor = 8
        while cursor + 4 <= data.count {
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) })
            let next = cursor + 4 + length * 4
            guard length > 0, length <= Self.dimension, next <= data.count else { break }
            offsets.append(cursor + 4)
            cursor = next
        }
        endOffset = cursor
    }

    private func fileHandle() -> FileHandle? {
        if let handle { return handle }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            var header = Data("BKUV".utf8)
            header.append(contentsOf: [0, 0, 0, 1])
            FileManager.default.createFile(atPath: url.path, contents: header)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        do {
            try handle.seek(toOffset: UInt64(endOffset))
        } catch {
            return nil
        }
        self.handle = handle
        return handle
    }

    @discardableResult
    func append(_ vector: [Float]) -> Int {
        guard let handle = fileHandle() else { return -1 }
        var payload = Data(capacity: vector.count * 4 + 4)
        let count = UInt32(vector.count)
        withUnsafeBytes(of: count) { payload.append(contentsOf: $0) }
        for value in vector {
            withUnsafeBytes(of: value.bitPattern) { payload.append(contentsOf: $0) }
        }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            return -1
        }
        offsets.append(endOffset + 4)
        endOffset += payload.count
        cachedData = nil
        scheduleFlush()
        return offsets.count - 1
    }

    func vector(at index: Int) -> [Float]? {
        guard offsets.indices.contains(index), let data = loadData() else { return nil }
        let start = offsets[index]
        guard start + 4 <= data.count else { return nil }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start - 4, as: UInt32.self) })
        guard count > 0, count <= Self.dimension, start + count * 4 <= data.count else { return nil }
        var vector = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                vector[index] = raw.loadUnaligned(fromByteOffset: start + index * 4, as: Float.self)
            }
        }
        return vector
    }

    private func loadData() -> Data? {
        if let cachedData { return cachedData }
        cachedData = try? Data(contentsOf: url, options: .mappedIfSafe)
        return cachedData
    }

    var count: Int { offsets.count }

    private func scheduleFlush() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            try? handle?.synchronize()
        }
    }

    func flush() {
        try? handle?.synchronize()
        cachedData = nil
    }

    /// Used by "Reset library index" so biometric data really is removed.
    func deleteAll() {
        try? handle?.close()
        handle = nil
        offsets = []
        endOffset = 8
        cachedData = nil
        try? FileManager.default.removeItem(at: url)
    }
}

enum VectorMath {
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
        var sum: Double = 0
        for index in 0..<lhs.count {
            let delta = Double(lhs[index] - rhs[index])
            sum += delta * delta
        }
        return sqrt(sum)
    }

    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var result = [Float](repeating: 0, count: first.count)
        var used = 0
        for vector in vectors where vector.count == first.count {
            used += 1
            for index in 0..<first.count {
                result[index] += vector[index]
            }
        }
        guard used > 0 else { return nil }
        for index in 0..<result.count {
            result[index] /= Float(used)
        }
        return result
    }
}
