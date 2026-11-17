import CoreGraphics
import Foundation
import Observation

/// Local mirror of the immutable atlases in a bucket.
///
/// Two levels are fetched from the same group:
///
/// - **preview** (64 px) is pulled for the whole library and kept on disk. It
///   is what a tile paints while scrolling, before any per-tile request.
/// - **grid** (384 px) is the final tile. Sheets are fetched when the viewport
///   approaches their photos and evicted as decoded memory fills.
///
/// Sheets are content-addressed, so a cache entry never goes stale: the only
/// invalidation is eviction. A photo with no pointer (an older upload, or one
/// whose sheet upload failed) simply falls back to the per-photo thumbnail, so
/// a half-finished publish can never hide a photo.
@MainActor
@Observable
final class AtlasStore {
    private struct Key: Hashable {
        var group: String
        var level: ThumbnailAtlas.Level
    }

    private struct Entry {
        var sheet: AtlasDecodedSheet
        var cost: Int
    }

    /// Decoded sheets are large: one 6×6 grid sheet is 2304² × 4 B ≈ 21 MB.
    /// Four covers the current screen, the next one and one behind; previews
    /// are 384² ≈ 0.6 MB and are kept for far more of the library.
    private let gridMemoryLimit = 3
    private let previewMemoryLimit = 24

    private var decoded: [Key: Entry] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<AtlasDecodedSheet?, Never>] = [:]
    /// Groups that failed to download. Retried after a cooldown instead of on
    /// every tile that scrolls past.
    private var failedAt: [Key: Date] = [:]
    private var pending: [Key] = []
    private var active = 0
    private let maxConcurrent = 4
    private let directory: URL

    /// Test seam: requests counted by group + level.
    private(set) var downloads = 0
    private(set) var diskHits = 0

    init(directory: URL = AppPaths.atlasCache) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Pointers

    /// The pointer for the server that holds the photo. Local photos also have
    /// copies, and every destination writes its own group, so the copy must
    /// match rather than be "any".
    static func pointer(for photo: PhotoItem, serverID: UUID?) -> AtlasPointer? {
        if let serverID, let copy = photo.copies.first(where: { $0.serverID == serverID }) {
            return copy.atlasPointer
        }
        if let copy = photo.copies.first(where: { $0.atlasGroup != nil }) {
            return copy.atlasPointer
        }
        return nil
    }

    func pointer(for photo: PhotoItem) -> AtlasPointer? {
        Self.pointer(for: photo, serverID: photo.serverID ?? photo.copies.first?.serverID)
    }

    // MARK: - Synchronous lookups

    /// A tile that is decoded and ready to draw in this frame. Safe to call
    /// from `body`/`onAppear`.
    func cachedTile(for photo: PhotoItem, level: ThumbnailAtlas.Level) -> PlatformImage? {
        guard let pointer = pointer(for: photo) else { return nil }
        let key = Key(group: pointer.group, level: level)
        guard let entry = decoded[key], let tile = entry.sheet.tile(pointer.cell) else { return nil }
        touch(key)
        return ImageUtilities.platformImage(from: tile)
    }

    func hasSheet(group: String, level: ThumbnailAtlas.Level) -> Bool {
        let key = Key(group: group, level: level)
        if decoded[key] != nil { return true }
        return FileManager.default.fileExists(atPath: diskURL(group: group, level: level).path)
    }

    // MARK: - Asynchronous loading

    /// The tile for a photo, decoding from memory or disk and downloading the
    /// sheet when neither has it. Returns nil when the photo has no atlas or
    /// the download fails, so the caller can fall back to the 900 px thumbnail.
    func tile(
        for photo: PhotoItem,
        level: ThumbnailAtlas.Level,
        client: S3Client?,
        prefix: String = ""
    ) async -> PlatformImage? {
        guard let pointer = pointer(for: photo) else { return nil }
        guard let sheet = await sheet(
            group: pointer.group,
            level: level,
            client: client,
            prefix: prefix
        ) else {
            return nil
        }
        guard let tile = sheet.tile(pointer.cell) else { return nil }
        return ImageUtilities.platformImage(from: tile)
    }

    /// Starts downloading the sheets a window of photos needs, without
    /// blocking. Used by the prefetcher so a scroll arrives to warm sheets.
    func prepare(
        photos: [PhotoItem],
        level: ThumbnailAtlas.Level,
        client: S3Client?,
        prefix: String = ""
    ) {
        guard client != nil else { return }
        var seen = Set<String>()
        for photo in photos {
            guard let pointer = pointer(for: photo), seen.insert(pointer.group).inserted else { continue }
            enqueue(Key(group: pointer.group, level: level), client: client, prefix: prefix, priority: .utility)
        }
    }

    /// Pulls every preview sheet for a library, four at a time, skipping the
    /// ones already on disk. This is the one-time cost that makes later
    /// scrolling instant and offline.
    func preloadPreviews(
        photos: [PhotoItem],
        client: S3Client?,
        prefix: String = "",
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async {
        guard let client else { return }
        var groups: [String] = []
        var seen = Set<String>()
        for photo in photos {
            guard let pointer = pointer(for: photo), seen.insert(pointer.group).inserted else { continue }
            groups.append(pointer.group)
        }
        let missing = groups.filter { !hasSheet(group: $0, level: .preview) }
        guard !missing.isEmpty else { return }

        var done = 0
        let batchSize = maxConcurrent
        var index = 0
        while index < missing.count {
            let batch = missing[index..<min(missing.count, index + batchSize)]
            await withTaskGroup(of: Void.self) { group in
                for next in batch {
                    group.addTask { @MainActor in
                        _ = await self.sheet(group: next, level: .preview, client: client, prefix: prefix)
                    }
                }
            }
            done += batch.count
            progress?(done, missing.count)
            index += batchSize
        }
    }

    private func sheet(
        group: String,
        level: ThumbnailAtlas.Level,
        client: S3Client?,
        prefix: String
    ) async -> AtlasDecodedSheet? {
        let key = Key(group: group, level: level)
        if let entry = decoded[key] {
            touch(key)
            return entry.sheet
        }
        if let cooldown = failedAt[key], Date().timeIntervalSince(cooldown) < 30 {
            return nil
        }

        if let task = inFlight[key] {
            return await task.value
        }

        // Already on disk: decode without touching the network.
        let url = diskURL(group: group, level: level)
        if FileManager.default.fileExists(atPath: url.path) {
            let task = Task<AtlasDecodedSheet?, Never>.detached(priority: .userInitiated) {
                AtlasDecoder.decode(url: url, group: group, level: level)
            }
            inFlight[key] = task
            let cachedSheet = await task.value
            inFlight[key] = nil
            if let cachedSheet {
                store(cachedSheet, key: key)
                diskHits += 1
                return cachedSheet
            }
            // A truncated file from a previous crash: fetch it again.
            try? FileManager.default.removeItem(at: url)
        }

        guard let client else { return nil }
        downloads += 1
        // Detached, not `Task {}`: this class is @MainActor, and a 2304² HEIC
        // decode is 20-30 ms — exactly the hitch the atlas exists to avoid.
        let task = Task<AtlasDecodedSheet?, Never>.detached(
            priority: level == .grid ? .userInitiated : .utility
        ) {
            let objectKey = S3Client.join(prefix, ThumbnailAtlas.key(level: level, group: group))
            guard let data = try? await client.getObject(key: objectKey) else { return nil }
            guard let sheet = AtlasDecoder.decode(data: data, group: group, level: level) else {
                return nil
            }
            try? data.write(to: url, options: .atomic)
            return sheet
        }
        inFlight[key] = task
        let downloaded = await task.value
        inFlight[key] = nil
        if let downloaded {
            store(downloaded, key: key)
        } else {
            failedAt[key] = Date()
        }
        return downloaded
    }

    private func store(_ sheet: AtlasDecodedSheet, key: Key) {
        let width = sheet.image.width
        let height = sheet.image.height
        decoded[key] = Entry(sheet: sheet, cost: width * height * 4)
        touch(key)
        evictIfNeeded(level: key.level)
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded(level: ThumbnailAtlas.Level) {
        let limit = level == .grid ? gridMemoryLimit : previewMemoryLimit
        let keys = order.filter { $0.level == level }
        guard keys.count > limit else { return }
        for key in keys.prefix(keys.count - limit) where inFlight[key] == nil {
            decoded[key] = nil
            order.removeAll { $0 == key }
        }
    }

    private func diskURL(group: String, level: ThumbnailAtlas.Level) -> URL {
        directory.appendingPathComponent("\(level.rawValue)-\(group).\(level.codec.filenameExtension)")
    }

    // MARK: - Queueing

    private func enqueue(_ key: Key, client: S3Client?, prefix: String, priority: TaskPriority) {
        if decoded[key] != nil || inFlight[key] != nil || pending.contains(key) { return }
        if let at = failedAt[key], Date().timeIntervalSince(at) < 30 { return }
        pending.append(key)
        pump(client: client, prefix: prefix)
    }

    private func pump(client: S3Client?, prefix: String = "") {
        guard let client else { return }
        while active < maxConcurrent, !pending.isEmpty {
            let key = pending.removeFirst()
            if decoded[key] != nil || inFlight[key] != nil { continue }
            active += 1
            Task(priority: key.level == .grid ? .utility : .utility) { [weak self] in
                guard let self else { return }
                _ = await self.sheet(group: key.group, level: key.level, client: client, prefix: prefix)
                self.active = max(0, self.active - 1)
                self.pump(client: client, prefix: prefix)
            }
        }
    }

    func clearMemory() {
        decoded.removeAll()
        order.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        pending.removeAll()
    }

    func clearAll() {
        clearMemory()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        failedAt.removeAll()
    }
}
