import CoreGraphics
import Foundation
import Photos

/// Which way the grid is travelling. The prefetch window leans forward so a
/// fling meets warm thumbnails, and still keeps a screen or two behind for the
/// flick back.
enum ScrollDirection {
    case forward
    case backward
}

/// Warms the thumbnails the grid is about to show.
///
/// Local assets go through `PHCachingImageManager`, the mechanism Photos itself
/// uses: it decodes into a bounded system cache and can serve the next screen
/// without a per-tile request. Remote-only photos are fetched separately with a
/// small concurrency limit so a scroll burst never saturates the network.
@MainActor
final class ThumbnailPrefetcher {
    private let library = PhotoLibraryService.shared
    private var manager: PHCachingImageManager { library.imageManager }

    private var assetCache: [String: PHAsset] = [:]
    private var cachingAssets: [PHAsset] = []
    private var cachingSize: CGSize = .zero

    private var remoteWindow: [PhotoItem] = []
    private var remoteSize: CGSize = .zero
    private weak var images: ImageCache?
    private var remoteTasks: [String: Task<Void, Never>] = [:]
    private let maxRemoteRequests = 3

    /// Local photos just beyond the viewport that are decoded into
    /// `ImageCache` rather than only into PhotoKit's caching manager. A
    /// `PHCachingImageManager` preheat still needs a request callback before a
    /// tile can draw it; pre-decoding into the app cache is what lets a newly
    /// realized tile paint in its *first* frame with no placeholder.
    private struct DecodeRequest {
        var photo: PhotoItem
        var size: CGSize
    }

    private var decodeQueue: [DecodeRequest] = []
    private var decodeTasks: [String: Task<Void, Never>] = [:]
    private let maxDecodeRequests = 3

    /// Screens kept warm behind the viewport, and ahead of it in the direction
    /// of travel. Ahead matters more during a fling; behind keeps a reversal
    /// from going blank.
    private let trailScreens = 2
    private let leadScreens = 3
    private let decodeScreens = 2

    /// Window of photos to keep warm, expanded by several screens on either
    /// side of the viewport, weighted towards the direction of travel.
    ///
    /// `perPhotoPixelSize` is for the full-width level, where every tile has a
    /// different height; without it the decode pump would warm a size no tile
    /// ever asks for and the cache entries would be unused.
    func update(
        photos: [PhotoItem],
        visibleRange: Range<Int>,
        itemsPerRow: Int,
        visibleRows: Int,
        targetPixelSize: CGSize,
        images: ImageCache,
        direction: ScrollDirection = .forward,
        perPhotoPixelSize: ((PhotoItem) -> CGSize)? = nil
    ) {
        guard !photos.isEmpty, targetPixelSize.width > 1, itemsPerRow > 0 else {
            stop()
            return
        }
        let rows = photos.count / max(1, itemsPerRow) + 1
        let firstRow = min(rows - 1, visibleRange.lowerBound / itemsPerRow)
        let lastRow = min(rows - 1, visibleRange.upperBound / itemsPerRow)
        let ahead = max(2, visibleRows) * leadScreens
        let behind = max(1, visibleRows) * trailScreens
        let lowerRow: Int
        let upperRow: Int
        switch direction {
        case .forward:
            lowerRow = max(0, firstRow - behind)
            upperRow = min(rows, lastRow + ahead)
        case .backward:
            lowerRow = max(0, firstRow - ahead)
            upperRow = min(rows, lastRow + behind)
        }
        let lower = min(photos.count, lowerRow * itemsPerRow)
        let upper = min(photos.count, upperRow * itemsPerRow)
        guard lower < upper else { return }
        let window = Array(photos[lower..<upper])

        updateLocal(window, targetPixelSize: targetPixelSize)
        updateRemote(window, targetPixelSize: targetPixelSize, images: images)
        prefetchDecodes(
            photos: photos,
            visibleRange: visibleRange,
            itemsPerRow: itemsPerRow,
            visibleRows: visibleRows,
            targetPixelSize: targetPixelSize,
            images: images,
            direction: direction,
            perPhotoPixelSize: perPhotoPixelSize
        )
    }

    func stop() {
        if !cachingAssets.isEmpty {
            manager.stopCachingImages(
                for: cachingAssets,
                targetSize: cachingSize,
                contentMode: .aspectFill,
                options: nil
            )
        }
        cachingAssets.removeAll()
        cachingSize = .zero
        for task in remoteTasks.values { task.cancel() }
        remoteTasks.removeAll()
        for task in decodeTasks.values { task.cancel() }
        decodeTasks.removeAll()
        decodeQueue.removeAll()
        remoteWindow = []
        images = nil
    }

    // MARK: - Local assets

    private func updateLocal(_ window: [PhotoItem], targetPixelSize: CGSize) {
        if targetPixelSize != cachingSize {
            if !cachingAssets.isEmpty {
                manager.stopCachingImages(
                    for: cachingAssets,
                    targetSize: cachingSize,
                    contentMode: .aspectFill,
                    options: nil
                )
            }
            cachingAssets.removeAll()
            cachingSize = targetPixelSize
        }

        let assets = resolveAssets(for: window)
        let wanted = Set(assets.map(\.localIdentifier))
        let removed = cachingAssets.filter { !wanted.contains($0.localIdentifier) }
        if !removed.isEmpty {
            manager.stopCachingImages(
                for: removed,
                targetSize: cachingSize,
                contentMode: .aspectFill,
                options: nil
            )
            cachingAssets.removeAll { !wanted.contains($0.localIdentifier) }
        }

        let cached = Set(cachingAssets.map(\.localIdentifier))
        let added = assets.filter { !cached.contains($0.localIdentifier) }
        guard !added.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        manager.startCachingImages(
            for: added,
            targetSize: cachingSize,
            contentMode: .aspectFill,
            options: options
        )
        cachingAssets.append(contentsOf: added)
    }

    private func resolveAssets(for photos: [PhotoItem]) -> [PHAsset] {
        var missing: [String] = []
        for photo in photos {
            guard let identifier = photo.localIdentifier else { continue }
            if assetCache[identifier] == nil { missing.append(identifier) }
        }
        if !missing.isEmpty {
            if assetCache.count > 1200 { assetCache.removeAll(keepingCapacity: true) }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
            fetched.enumerateObjects { [weak self] asset, _, _ in
                self?.assetCache[asset.localIdentifier] = asset
            }
        }
        return photos.compactMap { photo in
            photo.localIdentifier.flatMap { assetCache[$0] }
        }
    }

    // MARK: - Local pre-decode

    /// Decodes the next screen or two into the app's thumbnail cache. The
    /// caching manager below warms PhotoKit, but a tile can only paint
    /// synchronously from `ImageCache`, so this is the work that removes the
    /// blank first frame at the leading edge of a fling. Only the band just
    /// beyond the viewport is queued: the wider window stays with
    /// `PHCachingImageManager`, which is cheaper and bounded.
    private func prefetchDecodes(
        photos: [PhotoItem],
        visibleRange: Range<Int>,
        itemsPerRow: Int,
        visibleRows: Int,
        targetPixelSize: CGSize,
        images: ImageCache,
        direction: ScrollDirection,
        perPhotoPixelSize: ((PhotoItem) -> CGSize)?
    ) {
        // At the full-width level a single thumbnail is several megabytes, so
        // only the very next screen is decoded ahead. Multi-column tiles are
        // small enough to warm a couple of screens.
        let lead = itemsPerRow <= 1
            ? 2
            : max(itemsPerRow, visibleRows * itemsPerRow * decodeScreens)
        var candidates: [PhotoItem] = []
        switch direction {
        case .forward:
            let start = min(photos.count, visibleRange.upperBound)
            let end = min(photos.count, start + lead)
            if start < end { candidates = Array(photos[start..<end]) }
        case .backward:
            let end = max(0, visibleRange.lowerBound)
            let start = max(0, end - lead)
            if start < end { candidates = Array(photos[start..<end].reversed()) }
        }
        decodeQueue = candidates.map { photo in
            DecodeRequest(photo: photo, size: perPhotoPixelSize?(photo) ?? targetPixelSize)
        }
        pumpDecode(images: images)
    }

    private func pumpDecode(images: ImageCache) {
        while decodeTasks.count < maxDecodeRequests, !decodeQueue.isEmpty {
            let request = decodeQueue.removeFirst()
            let photo = request.photo
            let size = request.size
            guard size.width > 1, photo.localIdentifier != nil else { continue }
            guard decodeTasks[photo.id] == nil else { continue }
            guard images.cachedFinalThumbnail(for: photo, size: size) == nil else { continue }
            decodeTasks[photo.id] = Task(priority: .utility) { [weak self] in
                await images.prefetchThumbnail(for: photo, size: size)
                guard let self else { return }
                self.decodeTasks[photo.id] = nil
                self.pumpDecode(images: images)
            }
        }
    }

    // MARK: - Remote assets

    private func updateRemote(_ window: [PhotoItem], targetPixelSize: CGSize, images: ImageCache) {
        self.images = images
        remoteSize = targetPixelSize
        remoteWindow = window

        // Atlases turn a screen of 15 requests into one sheet. Photos that
        // predate the atlas (or whose publish was interrupted) keep the
        // per-photo pump, so a half-migrated bucket still warms everything.
        let remote = window.filter(\.isRemoteOnly)
        let atlasPhotos = remote.filter { images.hasAtlas(for: $0) }
        if !atlasPhotos.isEmpty {
            images.prepareAtlas(photos: atlasPhotos, level: .grid)
            images.prepareAtlas(photos: atlasPhotos, level: .preview)
        }
        let wanted = Set(remote.filter { !images.hasAtlas(for: $0) }.map(\.id))
        for (id, task) in remoteTasks where !wanted.contains(id) {
            task.cancel()
            remoteTasks[id] = nil
        }
        pumpRemote()
    }

    private func pumpRemote() {
        guard let images, remoteSize.width > 1 else { return }
        for photo in remoteWindow where photo.isRemoteOnly {
            guard remoteTasks.count < maxRemoteRequests else { break }
            guard remoteTasks[photo.id] == nil else { continue }
            guard images.cachedFinalThumbnail(for: photo, size: remoteSize) == nil else { continue }
            let size = remoteSize
            remoteTasks[photo.id] = Task(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                await images.prefetchThumbnail(for: photo, size: size)
                guard let self else { return }
                self.remoteTasks[photo.id] = nil
                self.pumpRemote()
            }
        }
    }
}
