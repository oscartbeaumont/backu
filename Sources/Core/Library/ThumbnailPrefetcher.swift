import CoreGraphics
import Foundation
import Photos

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

    /// Window of photos to keep warm, expanded by `visibleRows` screens on
    /// either side of the viewport.
    func update(
        photos: [PhotoItem],
        visibleRange: Range<Int>,
        itemsPerRow: Int,
        visibleRows: Int,
        targetPixelSize: CGSize,
        images: ImageCache
    ) {
        guard !photos.isEmpty, targetPixelSize.width > 1, itemsPerRow > 0 else {
            stop()
            return
        }
        let rows = photos.count / max(1, itemsPerRow) + 1
        let firstRow = min(rows - 1, visibleRange.lowerBound / itemsPerRow)
        let lastRow = min(rows - 1, visibleRange.upperBound / itemsPerRow)
        let lowerRow = max(0, firstRow - visibleRows * 2)
        let upperRow = min(rows, lastRow + visibleRows * 3)
        let lower = min(photos.count, lowerRow * itemsPerRow)
        let upper = min(photos.count, upperRow * itemsPerRow)
        guard lower < upper else { return }
        let window = Array(photos[lower..<upper])

        updateLocal(window, targetPixelSize: targetPixelSize)
        updateRemote(window, targetPixelSize: targetPixelSize, images: images)
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

    // MARK: - Remote assets

    private func updateRemote(_ window: [PhotoItem], targetPixelSize: CGSize, images: ImageCache) {
        self.images = images
        remoteSize = targetPixelSize
        remoteWindow = window

        let wanted = Set(window.filter(\.isRemoteOnly).map(\.id))
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
