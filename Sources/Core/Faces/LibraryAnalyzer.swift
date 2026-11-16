import CoreLocation
import Foundation
import Observation

/// Reverse geocoding with an on-disk cache and polite throttling.
actor PlaceResolver {
    private var cache: [String: String]
    private var lastRequest: Date = .distantPast

    private struct CacheFile: Codable {
        var places: [String: String]
    }

    init() {
        if let file = JSONFile.read(CacheFile.self, from: AppPaths.geocodeCacheFile) {
            cache = file.places
        } else {
            cache = [:]
        }
    }

    private func key(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    func cachedPlace(latitude: Double, longitude: Double) -> String? {
        cache[key(latitude: latitude, longitude: longitude)]
    }

    func resolve(latitude: Double, longitude: Double) async -> String? {
        let cacheKey = key(latitude: latitude, longitude: longitude)
        if let existing = cache[cacheKey] { return existing }

        let wait = 1.1 - Date().timeIntervalSince(lastRequest)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastRequest = Date()

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current).first else {
            return nil
        }
        let pieces = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
        let name = pieces.isEmpty ? placemark.name : pieces.joined(separator: ", ")
        guard let name, !name.isEmpty else { return nil }
        cache[cacheKey] = name
        persist()
        return name
    }

    private func persist() {
        try? JSONFile.write(CacheFile(places: cache), to: AppPaths.geocodeCacheFile)
    }
}

/// Runs Vision over library photos in the background and folds new faces into
/// people. This is what powers the People tab.
@MainActor
@Observable
final class LibraryAnalyzer {
    var isRunning = false
    var completed = 0
    var total = 0
    var status = "Not analysed yet"
    var lastError: String?
    var lastRunAt: Date?

    private let library = PhotoLibraryService.shared

    var progress: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    func analyzeMissing(
        catalog: CatalogStore,
        settings: AppSettings,
        faceStore: FaceEmbeddingStore,
        places: PlaceResolver,
        limit: Int? = nil,
        onProgress: (() -> Void)? = nil
    ) async {
        guard !isRunning else { return }
        var queue = catalog.photos.filter { $0.isLocal && $0.analyzedAt == nil }
        queue.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        if let limit { queue = Array(queue.prefix(limit)) }
        guard settings.faceRecognitionEnabled else { return }
        guard !queue.isEmpty else {
            await cluster(catalog: catalog, faceStore: faceStore)
            return
        }

        isRunning = true
        lastError = nil
        total = queue.count
        completed = 0
        let analyzer = FaceAnalyzer()

        for photo in queue {
            if Task.isCancelled { break }
            status = "Finding faces in \(photo.filename)"
            defer {
                completed += 1
                onProgress?()
            }
            guard let localIdentifier = photo.localIdentifier else { continue }
            guard let image = await library.thumbnail(for: localIdentifier, targetSize: CGSize(width: 1600, height: 1600)),
                  let cgImage = ImageUtilities.cgImage(from: image) else { continue }

            let outcome = await analyzer.analyze(image: cgImage, embeddingStore: faceStore)
            catalog.applyFaceAnalysis(photoID: photo.id, faces: outcome.faces)

            if let coordinate = photo.metadata.coordinate, photo.metadata.placeName == nil,
               let place = await places.resolve(latitude: coordinate.latitude, longitude: coordinate.longitude) {
                catalog.mutatePhoto(photo.id) { $0.metadata.placeName = place }
            }
        }

        await cluster(catalog: catalog, faceStore: faceStore)
        isRunning = false
        status = completed == 0 ? "Nothing to analyse" : "Analysed \(completed) photo\(completed == 1 ? "" : "s")"
        lastRunAt = Date()
    }

    func analyze(
        photo: PhotoItem,
        catalog: CatalogStore,
        faceStore: FaceEmbeddingStore,
        places: PlaceResolver?
    ) async -> Bool {
        guard let localIdentifier = photo.localIdentifier else { return false }
        guard let image = await library.thumbnail(for: localIdentifier, targetSize: CGSize(width: 1600, height: 1600)),
              let cgImage = ImageUtilities.cgImage(from: image) else { return false }
        let outcome = await FaceAnalyzer().analyze(image: cgImage, embeddingStore: faceStore)
        catalog.applyFaceAnalysis(photoID: photo.id, faces: outcome.faces)
        if let coordinate = photo.metadata.coordinate, photo.metadata.placeName == nil,
           let place = await places?.resolve(latitude: coordinate.latitude, longitude: coordinate.longitude) {
            catalog.mutatePhoto(photo.id) { $0.metadata.placeName = place }
        }
        await cluster(catalog: catalog, faceStore: faceStore)
        return true
    }

    func cluster(catalog: CatalogStore, faceStore: FaceEmbeddingStore) async {
        status = "Grouping people"
        let result = await FaceClusterer().cluster(catalog: catalog, store: faceStore)
        if result.newPeople > 0 {
            status = "Grouped \(result.newPeople) new \(result.newPeople == 1 ? "person" : "people")"
        }
    }
}

/// Groups face feature prints into people, matching against names the user has
/// already given. Runs entirely on-device.
struct FaceClusterer {
    var threshold: Double = {
        if let raw = ProcessInfo.processInfo.environment["BACKU_FACE_THRESHOLD"], let value = Double(raw) {
            return value
        }
        return 0.30
    }()
    var petThreshold: Double = 0.26

    struct Result: Sendable {
        var newPeople = 0
        var assigned = 0
        var clusteringAvailable = true
    }

    @MainActor
    func cluster(catalog: CatalogStore, store: FaceEmbeddingStore) async -> Result {
        struct FaceRef {
            var photoID: String
            var face: PhotoFace
            var vector: [Float]
        }

        var profiles: [UUID: (kind: PhotoFace.Kind, vectors: [[Float]])] = [:]
        var unassigned: [FaceRef] = []

        for photo in catalog.photos {
            for face in photo.faces {
                guard let embeddingIndex = face.embeddingIndex,
                      let vector = await store.vector(at: embeddingIndex) else { continue }
                if let personID = face.personID {
                    var profile = profiles[personID] ?? (face.kind, [])
                    if profile.vectors.count < 12 {
                        profile.vectors.append(vector)
                        profiles[personID] = profile
                    }
                } else {
                    unassigned.append(FaceRef(photoID: photo.id, face: face, vector: vector))
                }
            }
        }

        guard !unassigned.isEmpty else { return Result() }

        // Some runtimes (notably the Simulator) hand back identical feature
        // prints for every image. Merging on those would collapse every face
        // into one person, so stay in manual-naming mode instead.
        let sample = unassigned.prefix(24).map(\.vector)
        var maximumDistance = 0.0
        if sample.count >= 3 {
            for i in sample.indices {
                for j in sample.indices where j > i {
                    maximumDistance = max(maximumDistance, VectorMath.distance(sample[i], sample[j]))
                }
            }
        }
        if sample.count >= 3 && maximumDistance < 0.01 {
            var result = Result()
            result.clusteringAvailable = false
            for ref in unassigned {
                let person = catalog.createPerson(
                    isPet: ref.face.kind == .pet,
                    coverPhotoID: ref.photoID,
                    coverFaceID: ref.face.id
                )
                catalog.assign(faceID: ref.face.id, in: ref.photoID, to: person.id, markDirty: false)
                result.newPeople += 1
            }
            return result
        }

        var result = Result()

        // Greedy assignment: named people first, then existing unnamed groups.
        var unnamedClusters: [(personID: UUID, vectors: [[Float]], kind: PhotoFace.Kind)] = profiles
            .filter { catalog.person(id: $0.key).map { !$0.isNamed } ?? false }
            .map { ($0.key, $0.value.vectors, $0.value.kind) }

        for ref in unassigned {
            let limit = ref.face.kind == .pet ? petThreshold : threshold
            var best: (personID: UUID, distance: Double)?

            for (personID, profile) in profiles where profile.kind == ref.face.kind {
                let distance = profile.vectors.map { VectorMath.distance($0, ref.vector) }.min() ?? .greatestFiniteMagnitude
                if distance < limit, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (personID, distance)
                }
            }

            if best == nil {
                for cluster in unnamedClusters where cluster.kind == ref.face.kind {
                    var clusterVectors = cluster.vectors
                    if clusterVectors.count > 8 { clusterVectors = Array(clusterVectors.suffix(8)) }
                    var clusterBest = Double.greatestFiniteMagnitude
                    for vector in clusterVectors {
                        clusterBest = min(clusterBest, VectorMath.distance(vector, ref.vector))
                    }
                    if clusterBest < limit, clusterBest < (best?.distance ?? .greatestFiniteMagnitude) {
                        best = (cluster.personID, clusterBest)
                    }
                }
            }

            if let best {
                catalog.assign(faceID: ref.face.id, in: ref.photoID, to: best.personID, markDirty: false)
                profiles[best.personID]?.vectors.append(ref.vector)
                if let index = unnamedClusters.firstIndex(where: { $0.personID == best.personID }) {
                    unnamedClusters[index].vectors.append(ref.vector)
                }
                result.assigned += 1
            } else {
                let person = catalog.createPerson(
                    isPet: ref.face.kind == .pet,
                    coverPhotoID: ref.photoID,
                    coverFaceID: ref.face.id
                )
                catalog.assign(faceID: ref.face.id, in: ref.photoID, to: person.id, markDirty: false)
                profiles[person.id] = (ref.face.kind, [ref.vector])
                unnamedClusters.append((person.id, [ref.vector], ref.face.kind))
                result.newPeople += 1
            }
        }

        await mergeSimilarPeople(catalog: catalog, clusters: unnamedClusters)
        return result
    }

    /// Unnamed groups that turn out to be the same person get folded together.
    @MainActor
    private func mergeSimilarPeople(
        catalog: CatalogStore,
        clusters: [(personID: UUID, vectors: [[Float]], kind: PhotoFace.Kind)]
    ) async {
        var remaining = clusters
        var merges: [(UUID, UUID)] = []
        while remaining.count > 1 {
            let first = remaining.removeFirst()
            guard catalog.person(id: first.personID)?.isNamed == false else { continue }
            guard let centroid = VectorMath.centroid(first.vectors) else { continue }
            for other in remaining {
                guard catalog.person(id: other.personID)?.isNamed == false else { continue }
                guard let otherCentroid = VectorMath.centroid(other.vectors),
                      other.kind == first.kind else { continue }
                if VectorMath.distance(centroid, otherCentroid) < threshold * 0.82 {
                    merges.append((other.personID, first.personID))
                    break
                }
            }
        }
        for (source, target) in merges {
            catalog.mergePeople(source, into: target)
        }
    }
}
