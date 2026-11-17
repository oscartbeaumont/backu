import Foundation
import ImageIO
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// Memory + disk cache for library thumbnails and remote originals.
///
/// Thumbnails are keyed by photo *and* pixel size so switching grid density
/// never serves an image decoded for another density. NSCache enforces a byte
/// cost, which keeps a large library from holding hundreds of decoded bitmaps
/// in memory. Concurrent requests for the same key share one in-flight task, so
/// a prefetch and a visible tile never download the same bytes twice.
@MainActor
@Observable
final class ImageCache {
    /// Set by AppModel; fetches a thumbnail or original from a server.
    var remoteThumbnailLoader: ((PhotoItem, CGSize) async -> PlatformImage?)?
    var remoteImageLoader: ((PhotoItem) async -> PlatformImage?)?

    private final class Box {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    private let thumbnails = NSCache<NSString, Box>()
    private let degradedThumbnails = NSCache<NSString, Box>()
    /// Viewer-size (1200px) thumbnails live in their own cache. They are an
    /// order of magnitude larger than grid tiles, so letting them into the
    /// shared cache evicts every grid thumbnail in the library and pushes the
    /// footprint up by ~100 MB while paging. Keeping them separate also means
    /// closing the viewer returns to a grid that is still warm.
    private let viewerThumbnails = NSCache<NSString, Box>()
    private let fullImages = NSCache<NSString, Box>()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private var fullInFlight: [String: Task<PlatformImage?, Never>] = [:]
    /// Last thumbnail key per photo, used by the viewer's instant preview.
    private var previewKeys: [String: NSString] = [:]
    private var viewerPrefetch: [String: Task<Void, Never>] = [:]
    private let library = PhotoLibraryService.shared

    init() {
        thumbnails.countLimit = 900
        thumbnails.totalCostLimit = 96 * 1024 * 1024
        degradedThumbnails.countLimit = 240
        degradedThumbnails.totalCostLimit = 12 * 1024 * 1024
        // Five pages (current plus two either side) is what the viewer keeps,
        // and six entries cover the page the viewer came from as well.
        viewerThumbnails.countLimit = 6
        viewerThumbnails.totalCostLimit = 36 * 1024 * 1024
        // Only the photo on screen is sharpened, so the previous photo's full
        // image is the only one worth keeping: more would evict useful tiles
        // and hold another 20 MB for a swipe that has not happened.
        fullImages.countLimit = 2
        fullImages.totalCostLimit = 52 * 1024 * 1024
    }

    private func key(for photo: PhotoItem, size: CGSize) -> NSString {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return "\(photo.id)|\(width)x\(height)" as NSString
    }

    /// Synchronous lookup for tiles that are about to appear. Never creates a
    /// request, so it is safe to call from `body`/`onAppear`.
    func cachedThumbnail(for photo: PhotoItem, size: CGSize) -> PlatformImage? {
        let cacheKey = key(for: photo, size: size)
        if let final = thumbnails.object(forKey: cacheKey) { return final.image }
        return degradedThumbnails.object(forKey: cacheKey)?.image
    }

    func cachedFinalThumbnail(for photo: PhotoItem, size: CGSize) -> PlatformImage? {
        thumbnails.object(forKey: key(for: photo, size: size))?.image
    }

    /// Any thumbnail already decoded for this photo, at any density. The viewer
    /// uses it as the instant underlay while the full image streams in.
    func cachedPreview(for photo: PhotoItem) -> PlatformImage? {
        guard let cacheKey = previewKeys[photo.id] else { return nil }
        return thumbnails.object(forKey: cacheKey)?.image ?? degradedThumbnails.object(forKey: cacheKey)?.image
    }

    func thumbnail(
        for photo: PhotoItem,
        size: CGSize,
        onDegraded: (@MainActor (PlatformImage) -> Void)? = nil
    ) async -> PlatformImage? {
        let cacheKey = key(for: photo, size: size)
        if let cached = thumbnails.object(forKey: cacheKey) { return cached.image }
        let identifier = cacheKey as String
        if let task = inFlight[identifier] { return await task.value }

        let task = Task<PlatformImage?, Never>(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            return await self.load(photo: photo, size: size, cacheKey: cacheKey, onDegraded: onDegraded)
        }
        inFlight[identifier] = task
        let image = await task.value
        inFlight[identifier] = nil
        return image
    }

    /// Viewer-sized thumbnail, cached apart from the grid's tiles. Sharing the
    /// same in-flight request means a prefetch and the page that needs it still
    /// decode once.
    func viewerThumbnail(for photo: PhotoItem, size: CGSize) async -> PlatformImage? {
        let cacheKey = key(for: photo, size: size)
        if let cached = viewerThumbnails.object(forKey: cacheKey) { return cached.image }
        let identifier = "viewer|\(cacheKey)"
        if let task = inFlight[identifier] { return await task.value }

        let task = Task<PlatformImage?, Never>(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            return await self.load(
                photo: photo,
                size: size,
                cacheKey: cacheKey,
                onDegraded: nil,
                storeInGridCache: false
            )
        }
        inFlight[identifier] = task
        let image = await task.value
        inFlight[identifier] = nil
        if let image {
            viewerThumbnails.setObject(Box(image), forKey: cacheKey, cost: Self.cost(of: image))
        }
        return image
    }

    func cachedViewerThumbnail(for photo: PhotoItem, size: CGSize) -> PlatformImage? {
        cachedThumbnail(for: photo, size: size)
            ?? viewerThumbnails.object(forKey: key(for: photo, size: size))?.image
    }

    func hasViewerThumbnail(for photo: PhotoItem, size: CGSize) -> Bool {
        cachedViewerThumbnail(for: photo, size: size) != nil
    }

    /// Background fill used by the remote prefetcher. Shares the normal request
    /// path so a tile that appears mid-flight simply awaits the same task.
    func prefetchThumbnail(for photo: PhotoItem, size: CGSize) async {
        guard thumbnails.object(forKey: key(for: photo, size: size)) == nil else { return }
        _ = await thumbnail(for: photo, size: size)
    }

    private func load(
        photo: PhotoItem,
        size: CGSize,
        cacheKey: NSString,
        onDegraded: (@MainActor (PlatformImage) -> Void)?,
        storeInGridCache: Bool = true
    ) async -> PlatformImage? {
        let image: PlatformImage?
        let keyString = cacheKey as String
        if let localIdentifier = photo.localIdentifier {
            image = await library.thumbnail(for: localIdentifier, targetSize: size) { [weak self] degraded in
                Task { @MainActor in
                    guard let self, storeInGridCache else { return }
                    let key = keyString as NSString
                    self.degradedThumbnails.setObject(Box(degraded), forKey: key, cost: Self.cost(of: degraded))
                    self.previewKeys[photo.id] = key
                    if self.thumbnails.object(forKey: key) == nil {
                        onDegraded?(degraded)
                    }
                }
            }
        } else if let loader = remoteThumbnailLoader {
            image = await loader(photo, size)
        } else {
            image = nil
        }

        guard let image else { return nil }
        let ready = await Self.displayReady(image)
        if storeInGridCache {
            thumbnails.setObject(Box(ready), forKey: cacheKey, cost: Self.cost(of: ready))
            degradedThumbnails.removeObject(forKey: cacheKey)
            previewKeys[photo.id] = cacheKey
        }
        return ready
    }

    /// Decodes the bitmap before it reaches a view. `UIImage` decodes lazily on
    /// first draw, which puts a multi-megabyte decode inside the next frame
    /// commit; doing it here moves that work to a background queue and keeps
    /// the swipe or the zoom transition at 120 Hz. The unprepared image is
    /// returned unchanged on failure so the viewer still shows something.
    private nonisolated static func displayReady(_ image: PlatformImage) async -> PlatformImage {
        #if canImport(UIKit)
        return await image.byPreparingForDisplay() ?? image
        #else
        return image
        #endif
    }

    /// Synchronous lookup for a photo the viewer has already sharpened. The
    /// viewer uses it to paint the full image the instant a page becomes
    /// current again, instead of showing the soft thumbnail and waiting out
    /// the full-load delay.
    func cachedFullImage(for photo: PhotoItem) -> PlatformImage? {
        fullImages.object(forKey: photo.id as NSString)?.image
    }

    func fullImage(for photo: PhotoItem) async -> PlatformImage? {
        let cacheKey = photo.id as NSString
        if let cached = cachedFullImage(for: photo) { return cached }
        if let task = fullInFlight[photo.id] { return await task.value }

        let task = Task<PlatformImage?, Never>(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let image: PlatformImage?
            if let localIdentifier = photo.localIdentifier {
                image = await self.library.fullImage(for: localIdentifier)
            } else if let loader = self.remoteImageLoader {
                image = await loader(photo)
            } else {
                image = nil
            }
            guard let image else { return nil }
            return await Self.displayReady(image)
        }
        fullInFlight[photo.id] = task
        let image = await task.value
        fullInFlight[photo.id] = nil
        if let image {
            fullImages.setObject(Box(image), forKey: cacheKey, cost: Self.cost(of: image))
        }
        return image
    }

    /// Warms the photos next to the viewer's current page at low priority.
    /// Tasks for pages that leave the window are cancelled.
    func prefetchViewerPreviews(for photos: [PhotoItem], size: CGSize) {
        let wanted = Set(photos.map(\.id))
        for (id, task) in viewerPrefetch where !wanted.contains(id) {
            task.cancel()
            viewerPrefetch[id] = nil
        }
        for photo in photos where viewerPrefetch[photo.id] == nil {
            guard !hasViewerThumbnail(for: photo, size: size) else { continue }
            let id = photo.id
            viewerPrefetch[id] = Task(priority: .utility) { [weak self] in
                // Registered before the cancellation check: a task cancelled
                // before it starts still runs, and it must clear its slot.
                // Otherwise the entry is never freed (and that photo could
                // never be prefetched again for the life of the viewer).
                defer { self?.viewerPrefetch[id] = nil }
                guard let self, !Task.isCancelled else { return }
                _ = await self.viewerThumbnail(for: photo, size: size)
            }
        }
    }

    func clearMemory() {
        thumbnails.removeAllObjects()
        degradedThumbnails.removeAllObjects()
        viewerThumbnails.removeAllObjects()
        fullImages.removeAllObjects()
        previewKeys.removeAll()
        faceCache.removeAll()
        for task in inFlight.values { task.cancel() }
        for task in fullInFlight.values { task.cancel() }
        for task in viewerPrefetch.values { task.cancel() }
        inFlight.removeAll()
        fullInFlight.removeAll()
        viewerPrefetch.removeAll()
    }

    private static func cost(of image: PlatformImage) -> Int {
        if let cgImage = ImageUtilities.cgImage(from: image) {
            return max(1, cgImage.width * cgImage.height * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }

    private var faceCache: [String: PlatformImage] = [:]

    func faceImage(photo: PhotoItem, face: PhotoFace, size: CGFloat = 900) async -> PlatformImage? {
        let cacheKey = "\(photo.id)-\(face.id)"
        if let cached = faceCache[cacheKey] { return cached }
        guard let source = await thumbnail(for: photo, size: CGSize(width: size, height: size)),
              let cropped = ImageUtilities.crop(source, to: face.rect) else { return nil }
        if faceCache.count > 400 { faceCache.removeAll() }
        faceCache[cacheKey] = cropped
        return cropped
    }
}

extension ImageUtilities {
    static func crop(_ image: PlatformImage, to rect: NormRect) -> PlatformImage? {
        guard let cgImage = cgImage(from: image) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var pixelRect = CGRect(
            x: rect.x * width,
            y: rect.y * height,
            width: rect.width * width,
            height: rect.height * height
        )
        pixelRect = pixelRect.insetBy(dx: -pixelRect.width * 0.22, dy: -pixelRect.height * 0.22)
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard pixelRect.width > 1, pixelRect.height > 1, let cropped = cgImage.cropping(to: pixelRect) else {
            return nil
        }
        return platformImage(from: cropped)
    }
}

enum RemoteAssetLoader {
    /// Downloads an object and caches it on disk keyed by ETag-ish path.
    /// Thumbnails stay in memory (they are tiny); originals stream to disk so a
    /// 4K video or a 48 MP photo never has to fit in RAM.
    static func load(photo: PhotoItem, server: ServerConfig, client: S3Client, thumbnail: Bool) async -> PlatformImage? {
        let copy = photo.copy(on: server.id)
        let key = thumbnail
            // Older indexes may have no thumbnail; fall back to the original
            // rather than leaving a permanent placeholder.
            ? (photo.remoteThumbnailKey ?? copy?.thumbnailKey ?? copy?.objectKey)
            : copy?.objectKey
        guard let key else { return nil }

        let safeName = SigV4Signer.sha256Hex(Data((server.id.uuidString + key).utf8))
        let extensionName = thumbnail ? "jpg" : BackupEngine.fileExtension(for: photo)
        let cacheURL = AppPaths.imageCache.appendingPathComponent("\(safeName).\(extensionName)")

        if let image = ImageUtilities.image(from: cacheURL) {
            return image
        }

        if thumbnail {
            guard let data = try? await client.getObject(key: key) else { return nil }
            try? data.write(to: cacheURL)
            return ImageUtilities.image(from: data)
        }

        let sizeHint = photo.copy(on: server.id)?.byteCount
        do {
            try await client.downloadObject(
                key: key,
                to: cacheURL,
                sizeHint: sizeHint
            )
        } catch {
            return nil
        }
        return ImageUtilities.image(from: cacheURL)
    }
}

extension ImageUtilities {
    static func image(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return platformImage(from: cgImage)
    }

    static func image(from url: URL) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return platformImage(from: cgImage)
    }
}
