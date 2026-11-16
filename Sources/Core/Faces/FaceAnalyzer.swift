import CoreGraphics
import Foundation
import ImageIO
import CoreML
import Vision
import os

/// Finds faces and pets with Vision and turns each into a feature print so the
/// app can group them into people on-device.
struct FaceAnalyzer: Sendable {
    private let logger = Logger(subsystem: "dev.oscartbeaumont.backu", category: "faces")

    /// Ignore faces smaller than this fraction of the image's short edge.
    var minimumFaceFraction: Double = 0.035
    var maximumAnalysisPixel: Int = 1600

    struct Outcome: Sendable {
        var faces: [PhotoFace]
        var imageSize: CGSize
    }

    func analyze(imageURL: URL, embeddingStore: FaceEmbeddingStore) async -> Outcome {
        guard let image = ImageMetadataReader.uprightCGImage(url: imageURL, maxPixel: maximumAnalysisPixel) else {
            return Outcome(faces: [], imageSize: .zero)
        }
        return await analyze(image: image, embeddingStore: embeddingStore)
    }

    func analyze(image: CGImage, embeddingStore: FaceEmbeddingStore) async -> Outcome {
        let size = CGSize(width: image.width, height: image.height)
        let handler = ImageRequestHandler(image)
        var results: [PhotoFace] = []

        let observations = await Self.detectFaces(handler: handler, logger: logger)
        do {
            for observation in observations {
                let box = observation.boundingBox.cgRect
                let shortEdge = min(box.width, box.height)
                guard shortEdge >= minimumFaceFraction else { continue }
                let rect = NormRect(
                    visionX: box.origin.x,
                    visionY: box.origin.y,
                    visionWidth: box.width,
                    visionHeight: box.height
                )
                var embeddingIndex: Int?
                if let vector = await featurePrint(for: rect, in: image) {
                    let index = await embeddingStore.append(vector)
                    embeddingIndex = index >= 0 ? index : nil
                }
                results.append(
                    PhotoFace(
                        kind: .person,
                        rect: rect,
                        quality: Double(observation.confidence),
                        embeddingIndex: embeddingIndex
                    )
                )
            }
        }

        let animals = await Self.detectAnimals(handler: handler, logger: logger)
        do {
            for observation in animals {
                let box = observation.boundingBox.cgRect
                let shortEdge = min(box.width, box.height)
                guard shortEdge >= minimumFaceFraction else { continue }
                guard let label = observation.labels.first, label.confidence > 0.35 else { continue }
                let rect = NormRect(
                    visionX: box.origin.x,
                    visionY: box.origin.y,
                    visionWidth: box.width,
                    visionHeight: box.height
                )
                var embeddingIndex: Int?
                if let vector = await featurePrint(for: rect, in: image) {
                    let index = await embeddingStore.append(vector)
                    embeddingIndex = index >= 0 ? index : nil
                }
                results.append(
                    PhotoFace(
                        kind: .pet,
                        rect: rect,
                        quality: Double(label.confidence),
                        embeddingIndex: embeddingIndex
                    )
                )
            }
        }

        logger.info("Analyzed image \(size.width, privacy: .public)x\(size.height, privacy: .public): \(results.count, privacy: .public) regions")
        return Outcome(faces: results, imageSize: size)
    }

    /// Crops the face (with a little context) and computes a feature print.
    private func featurePrint(for rect: NormRect, in image: CGImage) async -> [Float]? {
        let padded = rect.inset(by: 0.28)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // NormRect is already in top-left space, which is what CGImage cropping uses.
        let pixelRect = CGRect(
            x: padded.x * width,
            y: padded.y * height,
            width: padded.width * width,
            height: padded.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 12, pixelRect.height >= 12,
              let crop = image.cropping(to: pixelRect) else { return nil }

        let handler = ImageRequestHandler(crop)
        var request = GenerateImageFeaturePrintRequest()
        do {
            let observation = try await handler.perform(request)
            return Self.floatVector(from: observation)
        } catch {
            guard let cpu = Self.cpuDevice else { return nil }
            request.setComputeDevice(cpu, for: .main)
            guard let observation = try? await handler.perform(request) else { return nil }
            return Self.floatVector(from: observation)
        }
    }

    static var cpuDevice: MLComputeDevice? {
        MLComputeDevice.allComputeDevices.first { device in
            if case .cpu = device { return true }
            return false
        }
    }

    /// Some simulators and older GPUs cannot build a default inference context.
    /// Retrying on the CPU keeps face indexing working everywhere.
    static func detectFaces(handler: ImageRequestHandler, logger: Logger) async -> [FaceObservation] {
        var request = DetectFaceRectanglesRequest()
        do {
            return try await handler.perform(request)
        } catch {
            logger.error("Face detection failed (\(error.localizedDescription, privacy: .public)); retrying on CPU")
            guard let cpu = cpuDevice else { return [] }
            request.setComputeDevice(cpu, for: .main)
            return (try? await handler.perform(request)) ?? []
        }
    }

    static func detectAnimals(handler: ImageRequestHandler, logger: Logger) async -> [RecognizedObjectObservation] {
        var request = RecognizeAnimalsRequest()
        do {
            return try await handler.perform(request)
        } catch {
            logger.error("Animal detection failed (\(error.localizedDescription, privacy: .public)); retrying on CPU")
            guard let cpu = cpuDevice else { return [] }
            request.setComputeDevice(cpu, for: .main)
            return (try? await handler.perform(request)) ?? []
        }
    }

    static func floatVector(from observation: FeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        let bytes = observation.data
        if bytes.count == count * 4 {
            return bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
                return Array(UnsafeBufferPointer(start: base, count: count))
            }
        }
        if bytes.count == count * 8 {
            return bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Double.self) else { return nil }
                return Array(UnsafeBufferPointer(start: base, count: count)).map { Float($0) }
            }
        }
        return nil
    }
}
