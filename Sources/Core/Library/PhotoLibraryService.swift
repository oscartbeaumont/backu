import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct ExportedAsset: Sendable {
    var url: URL
    var filename: String
    var uti: String
    var isTemporary: Bool = true
}

struct LibraryScanOptions: Sendable {
    var includeVideos: Bool = true
    var includeScreenshots: Bool = false
    var limit: Int? = nil
}

/// Thin async wrapper around PhotoKit. Scans are metadata-only and cheap; the
/// expensive work (EXIF, faces, originals) happens later and lazily.
final class PhotoLibraryService: @unchecked Sendable {
    static let shared = PhotoLibraryService()

    private let imageManager = PHImageManager.default()
    private let resourceManager = PHAssetResourceManager.default()

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - Scanning

    func scan(_ options: LibraryScanOptions = LibraryScanOptions()) async -> [PhotoItem] {
        await Task.detached(priority: .userInitiated) {
            var items: [PhotoItem] = []
            let fetch = PHAsset.fetchAssets(with: nil)
            let count = options.limit.map { min($0, fetch.count) } ?? fetch.count
            items.reserveCapacity(count)

            fetch.enumerateObjects { asset, index, stop in
                if items.count >= count {
                    stop.pointee = true
                    return
                }
                if asset.mediaType == .video && !options.includeVideos { return }
                if asset.mediaType == .audio { return }
                if !options.includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
                if let item = Self.makeItem(from: asset) {
                    items.append(item)
                }
            }
            items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
            return items
        }.value
    }

    private static func makeItem(from asset: PHAsset) -> PhotoItem? {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
        let filename = primary?.originalFilename ?? "IMG_\(asset.localIdentifier.prefix(6))"
        let uti = primary?.uniformTypeIdentifier

        var metadata = PhotoMetadata()
        metadata.uti = uti
        if let uti, let type = UTType(uti) {
            metadata.fileExtension = type.preferredFilenameExtension
        }
        if let location = asset.location {
            metadata.latitude = location.coordinate.latitude
            metadata.longitude = location.coordinate.longitude
            metadata.altitude = location.altitude
        }

        return PhotoItem(
            id: "asset:" + asset.localIdentifier,
            localIdentifier: asset.localIdentifier,
            filename: filename,
            takenAt: asset.creationDate,
            addedAt: asset.modificationDate,
            modifiedAt: asset.modificationDate,
            isVideo: asset.mediaType == .video,
            isFavorite: asset.isFavorite,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.mediaType == .video ? asset.duration : nil,
            metadata: metadata
        )
    }

    // MARK: - Images

    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> PlatformImage? {
        guard let asset = asset(for: localIdentifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await requestImage(asset: asset, targetSize: targetSize, options: options)
    }

    func fullImage(for localIdentifier: String, maxPixel: CGFloat = 2400) async -> PlatformImage? {        guard let asset = asset(for: localIdentifier) else { return nil }
        let scale = asset.pixelWidth > 0 ? min(1, maxPixel / CGFloat(max(asset.pixelWidth, asset.pixelHeight))) : 1
        let size = CGSize(
            width: max(1, CGFloat(asset.pixelWidth) * scale),
            height: max(1, CGFloat(asset.pixelHeight) * scale)
        )
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return await requestImage(asset: asset, targetSize: size, options: options)
    }

    private func requestImage(asset: PHAsset, targetSize: CGSize, options: PHImageRequestOptions) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate()
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled && image == nil { gate.resume { continuation.resume(returning: nil) } }
                gate.resume { continuation.resume(returning: image) }
            }
        }
    }

    // MARK: - Originals

    /// Writes the original bytes to a temporary file, which is what we upload.
    func exportOriginal(for localIdentifier: String) async throws -> ExportedAsset? {
        guard let asset = asset(for: localIdentifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredType: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .photo
        let candidates = [
            resources.first { $0.type == preferredType },
            resources.first { $0.type == .photo || $0.type == .video },
            resources.first
        ].compactMap { $0 }
        guard let resource = candidates.first else { return nil }

        let filename = resource.originalFilename
        let extensionPart = (filename as NSString).pathExtension
        let directory = AppPaths.stagingDirectory
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(extensionPart.isEmpty ? "bin" : extensionPart)")
        try? FileManager.default.removeItem(at: destination)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            resourceManager.writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return ExportedAsset(
            url: destination,
            filename: filename,
            uti: resource.uniformTypeIdentifier
        )
    }

    func changeObserverStream() -> AsyncStream<Void> {        AsyncStream { continuation in
            let observer = PhotoLibraryChangeObserver {
                continuation.yield()
            }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    #if os(iOS)
    func saveToLibrary(data: Data, filename: String, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: isVideo ? .video : .photo, data: data, options: options)
        }
    }
    #endif
}

private final class PhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler()
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private var hasResumed = false
    private let lock = NSLock()

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        body()
    }
}
