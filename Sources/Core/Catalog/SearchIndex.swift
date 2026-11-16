import Foundation

enum MediaFilter: String, CaseIterable, Sendable {
    case all
    case photos
    case videos
}

struct SearchQuery: Equatable, Sendable {
    var text: String = ""
    var personIDs: Set<UUID> = []
    var tags: Set<String> = []
    var cameras: Set<String> = []
    var favoritesOnly: Bool = false
    var locatedOnly: Bool = false
    var media: MediaFilter = .all
    var serverID: UUID?
    var year: Int?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && personIDs.isEmpty
            && tags.isEmpty
            && cameras.isEmpty
            && !favoritesOnly
            && !locatedOnly
            && media == .all
            && serverID == nil
            && year == nil
    }

    var activeFilterCount: Int {
        var count = 0
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        count += personIDs.count + tags.count + cameras.count
        if favoritesOnly { count += 1 }
        if locatedOnly { count += 1 }
        if media != .all { count += 1 }
        if serverID != nil { count += 1 }
        if year != nil { count += 1 }
        return count
    }
}

/// An in-memory inverted-ish index. Rebuilt when the catalog changes, so
/// keystrokes never touch the network or the disk.
struct SearchIndex {
    struct Entry: Sendable {
        var id: String
        var tokens: [String]
        var tags: Set<String>
        var cameras: Set<String>
        var personIDs: Set<UUID>
        var takenAt: Date?
        var isFavorite: Bool
        var isVideo: Bool
        var hasLocation: Bool
        var serverIDs: Set<UUID>
        var year: Int?
    }

    var entries: [Entry] = []
    private var byID: [String: Entry] = [:]

    init(photos: [PhotoItem], people: [UUID: Person]) {
        entries.reserveCapacity(photos.count)
        for photo in photos {
            let entry = Entry(
                id: photo.id,
                tokens: Self.tokens(for: photo, people: people),
                tags: Set(photo.tags.map { $0.lowercased() }),
                cameras: Set([photo.metadata.cameraDescription?.lowercased(), photo.metadata.lensModel?.lowercased()].compactMap { $0 }),
                personIDs: Set(photo.faces.compactMap(\.personID)),
                takenAt: photo.takenAt,
                isFavorite: photo.isFavorite,
                isVideo: photo.isVideo,
                hasLocation: photo.metadata.hasLocation,
                serverIDs: Set(photo.copies.map(\.serverID)),
                year: photo.captureYear
            )
            entries.append(entry)
            byID[photo.id] = entry
        }
    }

    static func tokens(for photo: PhotoItem, people: [UUID: Person]) -> [String] {
        var text = photo.filename + " "
        if let place = photo.metadata.placeName { text += place + " " }
        if let camera = photo.metadata.cameraDescription { text += camera + " " }
        if let lens = photo.metadata.lensModel { text += lens + " " }
        if !photo.tags.isEmpty { text += photo.tags.joined(separator: " ") + " " }
        for face in photo.faces {
            if let personID = face.personID, let person = people[personID] {
                text += person.displayName + " "
            }
        }
        if let year = photo.captureYear { text += String(year) }
        if photo.isVideo { text += "video movie " }
        if photo.isFavorite { text += "favorite " }
        if photo.metadata.hasLocation { text += "located " }

        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func matches(_ entry: Entry, query: SearchQuery, terms: [String]) -> Bool {
        if query.media == .photos && entry.isVideo { return false }
        if query.media == .videos && !entry.isVideo { return false }
        if query.favoritesOnly && !entry.isFavorite { return false }
        if query.locatedOnly && !entry.hasLocation { return false }
        if let year = query.year, entry.year != year { return false }
        if let serverID = query.serverID, !entry.serverIDs.contains(serverID) { return false }
        if !query.personIDs.isEmpty && !query.personIDs.isSubset(of: entry.personIDs) { return false }
        if !query.tags.isEmpty && !query.tags.isSubset(of: entry.tags) { return false }
        if !query.cameras.isEmpty && query.cameras.isDisjoint(with: entry.cameras) { return false }

        for term in terms {
            if term.count == 4, Int(term) != nil {
                if entry.year == Int(term) { continue }
            }
            if entry.tokens.contains(where: { $0.hasPrefix(term) }) { continue }
            // Prefix match against multi-word tags so "new y" finds "New York".
            if entry.tags.contains(where: { $0.split(separator: " ").contains(where: { $0.hasPrefix(term) }) }) { continue }
            return false
        }
        return true
    }

    func search(_ query: SearchQuery) -> Set<String> {
        let terms = query.text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var result = Set<String>()
        for entry in entries where matches(entry, query: query, terms: terms) {
            result.insert(entry.id)
        }
        return result
    }

    func entry(for id: String) -> Entry? { byID[id] }

    struct Facets: Sendable {
        var tags: [(value: String, count: Int)] = []
        var cameras: [(value: String, count: Int)] = []
        var people: [(id: UUID, count: Int)] = []
        var years: [(year: Int, count: Int)] = []
    }

    func facets(limitedTo ids: Set<String>, people: [Person]) -> Facets {
        var tagCounts: [String: Int] = [:]
        var cameraCounts: [String: Int] = [:]
        var personCounts: [UUID: Int] = [:]
        var yearCounts: [Int: Int] = [:]

        for entry in entries where ids.contains(entry.id) {
            for tag in entry.tags { tagCounts[tag, default: 0] += 1 }
            for camera in entry.cameras { cameraCounts[camera, default: 0] += 1 }
            for person in entry.personIDs { personCounts[person, default: 0] += 1 }
            if let year = entry.year { yearCounts[year, default: 0] += 1 }
        }

        return Facets(
            tags: tagCounts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) },
            cameras: cameraCounts.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) },
            people: personCounts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) },
            years: yearCounts.sorted { $0.key > $1.key }.prefix(8).map { ($0.key, $0.value) }
        )
    }
}
