import XCTest
import ImageIO

final class FaceAnalysisTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testVisionFindsFacesInFixtures() async throws {
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/library/IMG_4821.JPG")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Run `swift Tools/Fixtures/prepare-fixtures.swift` first")
        }
        let image = try XCTUnwrap(ImageMetadataReader.uprightCGImage(url: path, maxPixel: 1600))
        let store = FaceEmbeddingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let outcome = await FaceAnalyzer().analyze(image: image, embeddingStore: store)
        XCTAssertGreaterThan(outcome.faces.count, 0, "Vision found no faces in a clear portrait")

        let box = try XCTUnwrap(outcome.faces.first).rect
        XCTAssertGreaterThan(box.width, 0.05)
        XCTAssertGreaterThan(box.height, 0.05)
        XCTAssertLessThanOrEqual(box.x + box.width, 1.01)
        XCTAssertLessThanOrEqual(box.y + box.height, 1.01)
    }

    func testPetDetection() async throws {
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/library/IMG_6034.JPG")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Fixtures not prepared")
        }
        let image = try XCTUnwrap(ImageMetadataReader.uprightCGImage(url: path, maxPixel: 1600))
        let store = FaceEmbeddingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let outcome = await FaceAnalyzer().analyze(image: image, embeddingStore: store)
        XCTAssertTrue(outcome.faces.contains { $0.kind == .pet }, "No pet detected in a photo of a dog")
    }

    func testMetadataReaderReadsExifAndGPS() throws {
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/library/IMG_4821.JPG")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Fixtures not prepared")
        }
        let metadata = ImageMetadataReader.read(url: path)
        XCTAssertEqual(metadata.cameraMake, "Apple")
        XCTAssertEqual(metadata.cameraModel, "iPhone 17 Pro")
        XCTAssertEqual(metadata.iso, 64)
        XCTAssertEqual(metadata.latitude ?? 0, 51.5072, accuracy: 0.001)
        XCTAssertEqual(metadata.longitude ?? 0, -0.1276, accuracy: 0.001)
        XCTAssertNotNil(metadata.exposureDescription)
    }
}
