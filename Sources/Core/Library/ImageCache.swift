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
        fullImages.countLimit = 3
        fullImages.totalCostLimit = 72 * 1024 * 1024
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
        onDegraded: (@MainActor (PlatformImage) -> Void)?
    ) async -> PlatformImage? {
        let image: PlatformImage?
        let keyString = cacheKey as String
        if let localIdentifier = photo.localIdentifier {
            image = await library.thumbnail(for: localIdentifier, targetSize: size) { [weak self] degraded in
                Task { @MainActor in
                    guard let self else { return }
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

        if let image {
            thumbnails.setObject(Box(image), forKey: cacheKey, cost: Self.cost(of: image))
            degradedThumbnails.removeObject(forKey: cacheKey)
            previewKeys[photo.id] = cacheKey
        }
        return image
    }

    func fullImage(for photo: PhotoItem) async -> PlatformImage? {
        let cacheKey = photo.id as NSString
        if let cached = fullImages.object(forKey: cacheKey) { return cached.image }
        if let task = fullInFlight[photo.id] { return await task.value }

        let task = Task<PlatformImage?, Never>(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            if let localIdentifier = photo.localIdentifier {
                return await self.library.fullImage(for: localIdentifier)
            }
            if let loader = self.remoteImageLoader {
                return await loader(photo)
            }
            return nil
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
            guard thumbnails.object(forKey: key(for: photo, size: size)) == nil else { continue }
            viewerPrefetch[photo.id] = Task(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                _ = await self?.thumbnail(for: photo, size: size)
                self?.viewerPrefetch[photo.id] = nil
            }
        }
    }

    func clearMemory() {
        thumbnails.removeAllObjects()
        degradedThumbnails.removeAllObjects()
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
        // Older buckets hold JPEG previews, newer ones hold HEIC. Use the key's
        // real extension for both the cache file and ImageIO's type sniffing
        // (ImageIO reads the bytes, so the name only has to be truthful).
        let extensionName = thumbnail
            ? (PreviewFormat.from(key: key)?.fileExtension ?? key.pathExtensionLower)
            : BackupEngine.fileExtension(for: photo)
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
