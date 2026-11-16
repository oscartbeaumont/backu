import Foundation
import ImageIO
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// Memory + disk cache for library thumbnails and remote originals.
@MainActor
@Observable
final class ImageCache {
    /// Set by AppModel; fetches a thumbnail or original from a server.
    var remoteThumbnailLoader: ((PhotoItem, CGSize) async -> PlatformImage?)?
    var remoteImageLoader: ((PhotoItem) async -> PlatformImage?)?

    private var memory: [String: PlatformImage] = [:]
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private let library = PhotoLibraryService.shared
    private let limit = 320

    private func key(for photo: PhotoItem, size: CGSize) -> String {
        "\(photo.id)-\(Int(size.width))x\(Int(size.height))"
    }

    func cachedThumbnail(for photo: PhotoItem, size: CGSize) -> PlatformImage? {
        memory[key(for: photo, size: size)]
    }

    func thumbnail(for photo: PhotoItem, size: CGSize) async -> PlatformImage? {
        let cacheKey = key(for: photo, size: size)
        if let cached = memory[cacheKey] { return cached }
        if let task = inFlight[cacheKey] { return await task.value }

        let task = Task<PlatformImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image: PlatformImage?
            if let localIdentifier = photo.localIdentifier {
                image = await self.library.thumbnail(for: localIdentifier, targetSize: size)
            } else if let loader = self.remoteThumbnailLoader {
                image = await loader(photo, size)
            } else {
                image = nil
            }
            return image
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image {
            if memory.count > limit { memory.removeAll() }
            memory[cacheKey] = image
        }
        return image
    }

    func fullImage(for photo: PhotoItem) async -> PlatformImage? {
        if let localIdentifier = photo.localIdentifier {
            return await library.fullImage(for: localIdentifier)
        }
        if let loader = remoteImageLoader {
            return await loader(photo)
        }
        return nil
    }

    func clearMemory() {
        memory.removeAll()
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
    static func load(photo: PhotoItem, server: ServerConfig, client: S3Client, thumbnail: Bool) async -> PlatformImage? {
        let key = thumbnail
            ? (photo.remoteThumbnailKey ?? photo.copy(on: server.id)?.thumbnailKey)
            : photo.copy(on: server.id)?.objectKey
        guard let key else { return nil }

        let safeName = SigV4Signer.sha256Hex(Data((server.id.uuidString + key).utf8))
        let extensionName = thumbnail ? "jpg" : BackupEngine.fileExtension(for: photo)
        let cacheURL = AppPaths.imageCache.appendingPathComponent("\(safeName).\(extensionName)")
        if let data = try? Data(contentsOf: cacheURL), let image = ImageUtilities.image(from: data) {
            return image
        }

        guard let data = try? await client.getObject(key: key) else { return nil }
        try? data.write(to: cacheURL)
        return ImageUtilities.image(from: data)
    }
}

extension ImageUtilities {
    static func image(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return platformImage(from: cgImage)
    }
}
