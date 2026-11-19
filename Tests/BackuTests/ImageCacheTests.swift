import CoreGraphics
import XCTest

/// The grid and the viewer share `ImageCache`, but not their reuse rules.
///
/// A grid tile may be served the last density it was decoded at while the new
/// density loads. The viewer must not: `cachedViewerThumbnail` answers "is a
/// 1200 px preview already here?", and `prefetchViewerPreviews` skips photos
/// where that is true. If grid-density fallback leaked into it, visiting the
/// grid would make every photo look prefetched and the viewer would stop
/// warming its neighbours.
@MainActor
final class ImageCacheTests: XCTestCase {
    private func solidImage(side: Int) -> PlatformImage {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ImageUtilities.platformImage(from: context.makeImage()!)
    }

    private func photo() -> PhotoItem {
        PhotoItem(id: "asset:test-photo", localIdentifier: "test-photo", filename: "IMG_0001.JPG")
    }

    func testGridDensityFallbackDoesNotLookLikeAViewerPreview() {
        let cache = ImageCache()
        let photo = photo()
        let gridSize = CGSize(width: 384, height: 384)
        let viewerSize = CGSize(width: 1200, height: 1200)

        cache.seedThumbnailForTesting(solidImage(side: 8), for: photo, size: gridSize)

        // The tile path intentionally reuses the last decoded density...
        XCTAssertNotNil(
            cache.cachedThumbnailEntry(for: photo, size: viewerSize),
            "The grid fallback should still serve a tile at a new density"
        )
        // ...but the viewer must only report exact sizes.
        XCTAssertNil(
            cache.cachedViewerThumbnail(for: photo, size: viewerSize),
            "A grid-sized bitmap must not count as a cached viewer preview"
        )
        XCTAssertFalse(
            cache.hasViewerThumbnail(for: photo, size: viewerSize),
            "The viewer prefetcher would skip a neighbour that only has a grid thumbnail"
        )
        XCTAssertNotNil(
            cache.cachedViewerThumbnail(for: photo, size: gridSize),
            "An exact-size grid entry is still valid for the viewer underlay"
        )
    }

    func testExactDensityStillWins() {
        let cache = ImageCache()
        let photo = photo()
        let size = CGSize(width: 402, height: 402)
        cache.seedThumbnailForTesting(solidImage(side: 8), for: photo, size: size)

        let entry = cache.cachedThumbnailEntry(for: photo, size: size)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.isFinal, true)
        XCTAssertNotNil(cache.cachedViewerThumbnail(for: photo, size: size))
    }
}
