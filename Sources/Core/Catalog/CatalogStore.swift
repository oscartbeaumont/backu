import Foundation
import Observation

struct CatalogSnapshot: Codable {
    var version: Int
    var savedAt: Date
    var lastScanAt: Date?
    var photos: [PhotoItem]
    var people: [Person]
}

struct LibraryStats: Sendable {
    var totalPhotos: Int = 0
    var videos: Int = 0
    var localPhotos: Int = 0
    var remoteOnly: Int = 0
    var backedUp: Int = 0
    var tagged: Int = 0
    var namedPeople: Int = 0
    var faces: Int = 0
    var oldest: Date?
    var newest: Date?

    var backedUpFraction: Double {
        totalPhotos == 0 ? 0 : Double(backedUp) / Double(totalPhotos)
    }
}

@MainActor
@Observable
final class CatalogStore {
    private(set) var photos: [PhotoItem] = []
    private(set) var people: [Person] = []
    private(set) var lastScanAt: Date?
    private(set) var version = 0
    /// Set when catalog.json existed but could not be decoded. Writes are
    /// blocked so a bad read cannot destroy the user's tags and people.
    private(set) var loadFailure: String?

    private var photoByID: [String: PhotoItem] = [:]
    private var personByID: [UUID: Person] = [:]
    private var index: SearchIndex?
    private var indexVersion = -1
    private var saveTask: Task<Void, Never>?
    private var needsSort = false

    init(loadFromDisk: Bool = true) {
        if loadFromDisk {
            load()
        }
    }

    // MARK: - Persistence

    func load() {
        let file = AppPaths.catalogFile
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let snapshot = JSONFile.read(CatalogSnapshot.self, from: file) else {
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("catalog-corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: backup)
            loadFailure = "Your library index could not be read. Backu kept a copy at \(backup.lastPathComponent) and will not overwrite it until you reset the index."
            return
        }
        photos = snapshot.photos
        people = snapshot.people
        lastScanAt = snapshot.lastScanAt
        rebuildLookups()
        bump()
    }

    func clearLoadFailure() {
        loadFailure = nil
    }

    private func rebuildLookups() {
        photoByID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        personByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func saveSoon() {
        guard loadFailure == nil else { return }
        saveTask?.cancel()
        let snapshot = snapshot()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            Self.write(snapshot)
        }
    }

    /// Writes synchronously so the newest snapshot is on disk before the app is
    /// suspended. A serial queue guarantees snapshots land in submission order.
    func saveNow() {
        guard loadFailure == nil else { return }
        saveTask?.cancel()
        Self.write(snapshot())
    }

    private func snapshot() -> CatalogSnapshot {
        CatalogSnapshot(version: 1, savedAt: Date(), lastScanAt: lastScanAt, photos: photos, people: people)
    }

    private static let writeQueue = DispatchQueue(label: "dev.oscartbeaumont.backu.catalog-write", qos: .utility)

    private static func write(_ snapshot: CatalogSnapshot) {
        writeQueue.sync {
            try? JSONFile.write(snapshot, to: AppPaths.catalogFile)
        }
    }

    private func bump() {
        version &+= 1
        index = nil
    }

    // MARK: - Queries

    func photo(id: String) -> PhotoItem? { photoByID[id] }

    func person(id: UUID?) -> Person? {
        guard let id else { return nil }
        return personByID[id]
    }

    var namedPeople: [Person] {
        people.filter(\.isNamed).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var unnamedPeople: [Person] {
        people.filter { !$0.isNamed && !$0.isHidden }.sorted { $0.faceCount > $1.faceCount }
    }

    func photos(of personID: UUID) -> [PhotoItem] {
        photos.filter { photo in photo.faces.contains { $0.personID == personID } }
            .sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
    }

    func face(photoID: String, faceID: UUID) -> PhotoFace? {
        photoByID[photoID]?.faces.first { $0.id == faceID }
    }

    func photo(forFaceID faceID: UUID) -> PhotoItem? {
        photos.first { photo in photo.faces.contains { $0.id == faceID } }
    }

    func stats() -> LibraryStats {
        var stats = LibraryStats()
        stats.totalPhotos = photos.count
        for photo in photos {
            if photo.isVideo { stats.videos += 1 }
            if photo.isLocal { stats.localPhotos += 1 }
            if photo.isRemoteOnly { stats.remoteOnly += 1 }
            if photo.isBackedUp { stats.backedUp += 1 }
            if !photo.tags.isEmpty { stats.tagged += 1 }
            stats.faces += photo.faces.count
            if let date = photo.takenAt {
                if stats.oldest == nil || date < stats.oldest! { stats.oldest = date }
                if stats.newest == nil || date > stats.newest! { stats.newest = date }
            }
        }
        stats.namedPeople = people.filter(\.isNamed).count
        return stats
    }

    func search(_ query: SearchQuery) -> [PhotoItem] {
        ensureIndex()
        guard let index else { return [] }
        let ids = index.search(query)
        return photos
            .filter { ids.contains($0.id) }
            .sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
    }

    func facets(for ids: Set<String>) -> SearchIndex.Facets {
        ensureIndex()
        return index?.facets(limitedTo: ids, people: people) ?? SearchIndex.Facets()
    }

    func allIDs() -> Set<String> {
        Set(photos.map(\.id))
    }

    private func ensureIndex() {
        guard index == nil || indexVersion != version else { return }
        index = SearchIndex(photos: photos, people: personByID)
        indexVersion = version
    }

    // MARK: - Library merge

    /// Merges a fresh library scan without clobbering anything the user has
    /// added (tags, names, upload records, analysis results).
    @discardableResult
    func mergeScanned(_ scanned: [PhotoItem], removingMissing: Bool = true) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        let scannedIDs = Set(scanned.map(\.id))

        for photo in scanned {
            if var existing = photoByID[photo.id] {
                // PhotoKit still knows this asset: re-adopt it after an earlier
                // scan (limited access, videos disabled) dropped the link.
                existing.localIdentifier = photo.localIdentifier
                existing.filename = photo.filename
                existing.takenAt = photo.takenAt
                existing.addedAt = photo.addedAt
                existing.modifiedAt = photo.modifiedAt
                existing.isVideo = photo.isVideo
                // isFavorite is app-owned once a photo is imported; a rescan
                // must not undo a heart the user tapped in Backu.
                existing.pixelWidth = photo.pixelWidth
                existing.pixelHeight = photo.pixelHeight
                existing.duration = photo.duration
                existing.metadata.uti = photo.metadata.uti ?? existing.metadata.uti
                existing.metadata.fileExtension = photo.metadata.fileExtension ?? existing.metadata.fileExtension
                if !photo.metadata.hasLocation, existing.metadata.hasLocation {
                    // keep a previously extracted location
                } else if photo.metadata.hasLocation {
                    existing.metadata.latitude = photo.metadata.latitude
                    existing.metadata.longitude = photo.metadata.longitude
                    existing.metadata.altitude = photo.metadata.altitude
                }
                upsertInMemory(existing)
                updated += 1
            } else {
                upsertInMemory(photo)
                added += 1
            }
        }

        if removingMissing && !scanned.isEmpty {
            var survivors: [PhotoItem] = []
            survivors.reserveCapacity(photos.count)
            for var photo in photos {
                if photo.localIdentifier != nil && !scannedIDs.contains(photo.id) {
                    if photo.copies.isEmpty {
                        continue
                    }
                    photo.localIdentifier = nil
                    photo.remoteThumbnailKey = photo.remoteThumbnailKey ?? photo.copies.first?.thumbnailKey
                    photo.serverID = photo.copies.first?.serverID
                }
                survivors.append(photo)
            }
            photos = survivors
            rebuildLookups()
        }

        sortIfNeeded()
        lastScanAt = Date()
        bump()
        saveSoon()
        return (added, updated)
    }

    private func upsertInMemory(_ photo: PhotoItem) {
        if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[index] = photo
        } else {
            photos.append(photo)
            needsSort = true
        }
        photoByID[photo.id] = photo
    }

    private func sortIfNeeded() {
        guard needsSort else { return }
        photos.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        needsSort = false
    }

    func removeAll() {
        photos = []
        people = []
        rebuildLookups()
        bump()
        saveNow()
    }

    // MARK: - Mutation

    func mutatePhoto(_ id: String, _ body: (inout PhotoItem) -> Void) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        body(&photos[index])
        photoByID[id] = photos[index]
        bump()
        saveSoon()
    }

    func setFavorite(_ id: String, isFavorite: Bool) {
        mutatePhoto(id) { $0.isFavorite = isFavorite }
    }

    func addTag(_ tag: String, to id: String) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        mutatePhoto(id) { photo in
            if !photo.tags.contains(cleaned) { photo.tags.append(cleaned) }
            photo.sidecarDirtyAt = Date()
        }
    }

    func removeTag(_ tag: String, from id: String) {
        mutatePhoto(id) { photo in
            photo.tags.removeAll { $0 == tag }
            photo.sidecarDirtyAt = Date()
        }
    }

    func removeFace(photoID: String, faceID: UUID) {
        mutatePhoto(photoID) { photo in
            photo.faces.removeAll { $0.id == faceID }
            photo.sidecarDirtyAt = Date()
        }
        recomputePeopleCounts()
        bump()
    }

    func setTags(_ tags: [String], for id: String) {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        mutatePhoto(id) {
            $0.tags = Array(Set(cleaned)).sorted()
            $0.sidecarDirtyAt = Date()
        }
    }

    func allTags() -> [String] {
        var counts: [String: Int] = [:]
        for photo in photos {
            for tag in photo.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Faces and people

    func applyFaceAnalysis(photoID: String, faces: [PhotoFace], metadata: PhotoMetadata? = nil) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        // Preserve names the user already assigned by matching face geometry.
        var existingFaces = photos[index].faces
        for face in faces {
            if let matchIndex = existingFaces.firstIndex(where: { existing in
                abs(existing.rect.x - face.rect.x) < 0.06
                    && abs(existing.rect.y - face.rect.y) < 0.06
                    && existing.kind == face.kind
            }) {
                existingFaces[matchIndex] = PhotoFace(
                    id: existingFaces[matchIndex].id,
                    personID: existingFaces[matchIndex].personID,
                    kind: face.kind,
                    rect: face.rect,
                    quality: face.quality,
                    embeddingIndex: face.embeddingIndex ?? existingFaces[matchIndex].embeddingIndex
                )
            } else {
                existingFaces.append(face)
            }
        }
        photos[index].faces = existingFaces
        photos[index].analyzedAt = Date()
        if let metadata { photos[index].metadata = metadata }
        photoByID[photoID] = photos[index]
        recomputePeopleCounts()
        bump()
        saveSoon()
    }

    func createPerson(name: String? = nil, isPet: Bool = false, coverPhotoID: String? = nil, coverFaceID: UUID? = nil) -> Person {
        let person = Person(
            name: name,
            isPet: isPet,
            coverPhotoID: coverPhotoID,
            coverFaceID: coverFaceID,
            lastSeenAt: Date()
        )
        people.append(person)
        personByID[person.id] = person
        bump()
        saveSoon()
        return person
    }

    func renamePerson(_ id: UUID, to name: String) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        people[index].name = trimmed.isEmpty ? nil : trimmed
        personByID[id] = people[index]
        markSidecarsDirty(forPerson: id)
        bump()
        saveSoon()
    }

    /// Any photo containing this person needs its sidecar rewritten.
    private func markSidecarsDirty(forPerson id: UUID) {
        for index in photos.indices where photos[index].faces.contains(where: { $0.personID == id }) {
            photos[index].sidecarDirtyAt = Date()
        }
    }

    func setPet(_ id: UUID, isPet: Bool) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        people[index].isPet = isPet
        personByID[id] = people[index]
        markSidecarsDirty(forPerson: id)
        bump()
        saveSoon()
    }

    func assign(faceID: UUID, in photoID: String, to personID: UUID?, markDirty: Bool = true) {
        guard let photoIndex = photos.firstIndex(where: { $0.id == photoID }),
              let faceIndex = photos[photoIndex].faces.firstIndex(where: { $0.id == faceID }) else { return }
        let previousPerson = photos[photoIndex].faces[faceIndex].personID
        photos[photoIndex].faces[faceIndex].personID = personID
        photoByID[photoID] = photos[photoIndex]

        if let previousPerson, previousPerson != personID {
            recount(previousPerson)
        }
        if let personID {
            if let personIndex = people.firstIndex(where: { $0.id == personID }) {
                let face = photos[photoIndex].faces[faceIndex]
                if people[personIndex].coverFaceID == nil {
                    people[personIndex].coverFaceID = face.id
                    people[personIndex].coverPhotoID = photoID
                }
                people[personIndex].lastSeenAt = Date()
                personByID[personID] = people[personIndex]
            }
            recount(personID)
        }
        if markDirty { photos[photoIndex].sidecarDirtyAt = Date() }
        bump()
        saveSoon()
    }

    func assign(personID: UUID, toFacesIn photoID: String) {
        guard let photoIndex = photos.firstIndex(where: { $0.id == photoID }) else { return }
        for faceIndex in photos[photoIndex].faces.indices {
            photos[photoIndex].faces[faceIndex].personID = personID
        }
        photoByID[photoID] = photos[photoIndex]
        if let personIndex = people.firstIndex(where: { $0.id == personID }) {
            if let first = photos[photoIndex].faces.first {
                people[personIndex].coverFaceID = people[personIndex].coverFaceID ?? first.id
                people[personIndex].coverPhotoID = people[personIndex].coverPhotoID ?? photoID
            }
            personByID[personID] = people[personIndex]
        }
        recount(personID)
        bump()
        saveSoon()
    }

    func deletePerson(_ id: UUID) {
        people.removeAll { $0.id == id }
        personByID[id] = nil
        for index in photos.indices {
            var changed = false
            for faceIndex in photos[index].faces.indices where photos[index].faces[faceIndex].personID == id {
                photos[index].faces[faceIndex].personID = nil
                changed = true
            }
            if changed { photos[index].sidecarDirtyAt = Date() }
        }
        rebuildLookups()
        bump()
        saveSoon()
    }

    func mergePeople(_ source: UUID, into target: UUID) {
        guard source != target else { return }
        for index in photos.indices {
            var changed = false
            for faceIndex in photos[index].faces.indices where photos[index].faces[faceIndex].personID == source {
                photos[index].faces[faceIndex].personID = target
                changed = true
            }
            if changed { photos[index].sidecarDirtyAt = Date() }
        }
        people.removeAll { $0.id == source }
        personByID[source] = nil
        rebuildLookups()
        recount(target)
        bump()
        saveSoon()
    }

    private func recount(_ personID: UUID) {
        guard let index = people.firstIndex(where: { $0.id == personID }) else { return }
        let count = photos.reduce(0) { partial, photo in
            partial + photo.faces.filter { $0.personID == personID }.count
        }
        people[index].faceCount = count
        personByID[personID] = people[index]
    }

    private func recomputePeopleCounts() {
        var counts: [UUID: Int] = [:]
        for photo in photos {
            for face in photo.faces {
                if let personID = face.personID { counts[personID, default: 0] += 1 }
            }
        }
        for index in people.indices {
            people[index].faceCount = counts[people[index].id] ?? 0
        }
        personByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Upload records

    func recordUpload(copy: PhotoCopy, for photoID: String) {
        mutatePhoto(photoID) { photo in
            photo.copies.removeAll { $0.serverID == copy.serverID && $0.objectKey == copy.objectKey }
            photo.copies.append(copy)
            photo.remoteThumbnailKey = copy.thumbnailKey ?? photo.remoteThumbnailKey
            if photo.localIdentifier == nil { photo.serverID = copy.serverID }
        }
    }

    func removeCopy(serverID: UUID, from photoID: String) {
        var shouldDrop = false
        mutatePhoto(photoID) { photo in
            photo.copies.removeAll { $0.serverID == serverID }
            shouldDrop = photo.localIdentifier == nil && photo.copies.isEmpty
        }
        if shouldDrop {
            photos.removeAll { $0.id == photoID }
            photoByID[photoID] = nil
            bump()
            saveSoon()
        }
    }

    // MARK: - Remote index import

    func mergePersonRecords(_ records: [Person]) {
        var changed = false
        for person in records where personByID[person.id] == nil {
            people.append(person)
            personByID[person.id] = person
            changed = true
        }
        if changed {
            bump()
            saveSoon()
        }
    }

    func removeServerCopies(_ serverID: UUID) {
        var changed = false
        for index in photos.indices {
            let before = photos[index].copies.count
            photos[index].copies.removeAll { $0.serverID == serverID }
            if photos[index].copies.count != before { changed = true }
        }
        let ghosts = photos.filter { $0.localIdentifier == nil && $0.copies.isEmpty }
        if !ghosts.isEmpty {
            photos.removeAll { $0.localIdentifier == nil && $0.copies.isEmpty }
            rebuildLookups()
            changed = true
        }
        if changed {
            bump()
            saveSoon()
        }
    }

    func importRemotePhotos(_ remote: [PhotoItem]) -> Int {
        var imported = 0
        var byHash: [String: String] = [:]
        for photo in photos {
            if let sha = photo.sha256, byHash[sha] == nil {
                byHash[sha] = photo.id
            }
        }

        for item in remote {
            if let sha = item.sha256, let localID = byHash[sha] {
                if var local = photoByID[localID] {
                    for copy in item.copies where !local.copies.contains(where: { $0.serverID == copy.serverID }) {
                        local.copies.append(copy)
                    }
                    local.remoteThumbnailKey = local.remoteThumbnailKey ?? item.remoteThumbnailKey
                    upsertInMemory(local)
                }
                continue
            }
            if let sha = item.sha256, byHash[sha] != nil {
                // The same bytes are already here (perhaps under another
                // device's identifier); fold the new copy into that photo.
                if let existingID = byHash[sha], var existing = photoByID[existingID] {
                    for copy in item.copies where !existing.copies.contains(where: { $0.serverID == copy.serverID }) {
                        existing.copies.append(copy)
                    }
                    existing.remoteThumbnailKey = existing.remoteThumbnailKey ?? item.remoteThumbnailKey
                    upsertInMemory(existing)
                }
                continue
            }
            if photoByID[item.id] == nil {
                var item = item
                item.localIdentifier = nil
                upsertInMemory(item)
                if let sha = item.sha256 { byHash[sha] = item.id }
                imported += 1
            }
        }
        if imported > 0 {
            sortIfNeeded()
            bump()
            saveSoon()
        }
        return imported
    }
}
