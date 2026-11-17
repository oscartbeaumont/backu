import XCTest
import CoreGraphics
import ImageIO

final class PreviewCodecTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors: [CGColor] = [
            CGColor(red: 0.12, green: 0.28, blue: 0.55, alpha: 1),
            CGColor(red: 0.82, green: 0.55, blue: 0.18, alpha: 1),
            CGColor(red: 0.24, green: 0.62, blue: 0.31, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(
                x: CGFloat(index) * CGFloat(width) / 3,
                y: 0,
                width: CGFloat(width) / 3,
                height: CGFloat(height)
            ))
        }
        // A few edges and a gradient give the encoder something to compress.
        context.setFillColor(CGColor(gray: 1, alpha: 0.6))
        for step in stride(from: 0, to: width, by: max(1, width / 24)) {
            context.fill(CGRect(x: CGFloat(step), y: 0, width: 3, height: CGFloat(height)))
        }
        return context.makeImage()
    }

    func testEncodesADecodablePreviewAtTheRequestedSize() throws {
        let image = try XCTUnwrap(makeImage(width: 1600, height: 1200))
        let preview = try XCTUnwrap(PreviewCodec.encode(image: image, format: .preferred, quality: 0.8))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, preview.format.utType.identifier)

        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 900)
        XCTAssertEqual(decoded.height, 675)
    }

    func testHEICPreviewIsSmallerThanJPEGForTheSamePhoto() throws {
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/library/IMG_4821.JPG")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Run `swift Tools/Fixtures/prepare-fixtures.swift` first")
        }
        let heic = try XCTUnwrap(PreviewCodec.encode(url: path, format: .heic, quality: 0.8))
        let jpeg = try XCTUnwrap(PreviewCodec.encode(url: path, format: .jpeg, quality: 0.8))
        XCTAssertLessThan(heic.data.count, jpeg.data.count)
        XCTAssertNotNil(CGImageSourceCreateWithData(heic.data as CFData, nil))
    }

    func testStoredPreviewFormatComesFromTheKey() {
        XCTAssertEqual(PreviewFormat.from(key: ".backu/thumbs/abc.heic"), .heic)
        XCTAssertEqual(PreviewFormat.from(key: ".backu/thumbs/abc.HEIF"), .heic)
        XCTAssertEqual(PreviewFormat.from(key: ".backu/thumbs/abc.jpg"), .jpeg)
        XCTAssertEqual(PreviewFormat.from(key: ".backu/thumbs/abc.jpeg"), .jpeg)
        XCTAssertNil(PreviewFormat.from(key: ".backu/thumbs/abc.png"))
    }

    func testPreferredFormatCanBeWrittenOnThisOS() {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        XCTAssertTrue(writable.contains(PreviewFormat.preferred.utType.identifier))
    }

    func testPreferredFormatIsHEICWhenAvailable() {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if writable.contains(PreviewFormat.heic.utType.identifier) {
            XCTAssertEqual(PreviewFormat.preferred, .heic)
        } else {
            XCTAssertEqual(PreviewFormat.preferred, .jpeg)
        }
    }
}
