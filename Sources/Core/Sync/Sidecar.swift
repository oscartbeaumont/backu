import Foundation
import UniformTypeIdentifiers

/// Everything Backu writes next to a photo in the bucket. Human-readable JSON so
/// a bucket remains useful without the app.
struct SidecarDocument: Codable, Sendable {
    struct Dimensions: Codable, Sendable {
        var width: Int
        var height: Int
    }

    struct CameraInfo: Codable, Sendable {
        var make: String?
        var model: String?
        var lens: String?
        var iso: Int?
        var aperture: Double?
        var shutterSpeed: Double?
        var focalLength: Double?
    }

    struct LocationInfo: Codable, Sendable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
        var place: String?
    }

    struct PersonRef: Codable, Sendable {
        var id: UUID
        var name: String?
        var isPet: Bool
    }

    struct FaceInfo: Codable, Sendable {
        var id: UUID
        var personID: UUID?
        var kind: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var schema: String = "backu.photo.v1"
    var id: String
    var filename: String
    var capturedAt: Date?
    var backedUpAt: Date
    var width: Int
    var height: Int
    var isVideo: Bool
    var duration: Double?
    var favorite: Bool
    var tags: [String]
    var people: [PersonRef]
    var faces: [FaceInfo]
    var camera: CameraInfo
    var location: LocationInfo?
    var sha256: String?
    /// Immutable atlas group and cell, copied so a bucket can be repaired from
    /// sidecars alone. The app browses from `index.json`.
    var atlasGroup: String?
    var atlasCell: Int?
    var device: String
    var app: String

    static func make(
        photo: PhotoItem,
        people: [UUID: Person],
        device: String,
        sha256: String?,
        serverID: UUID? = nil
    ) -> SidecarDocument {
        let atlasCopy = serverID.flatMap { id in photo.copies.first { $0.serverID == id } }
            ?? photo.copies.first { $0.atlasGroup != nil }
        let referenced = Set(photo.faces.compactMap(\.personID))
        return SidecarDocument(
            id: photo.id,
            filename: photo.filename,
            capturedAt: photo.takenAt,
            backedUpAt: Date(),
            width: photo.pixelWidth,
            height: photo.pixelHeight,
            isVideo: photo.isVideo,
            duration: photo.duration,
            favorite: photo.isFavorite,
            tags: photo.tags,
            people: referenced.compactMap { id in
                guard let person = people[id] else { return nil }
                return PersonRef(id: id, name: person.name, isPet: person.isPet)
            },
            faces: photo.faces.map { face in
                FaceInfo(
                    id: face.id,
                    personID: face.personID,
                    kind: face.kind.rawValue,
                    x: face.rect.x,
                    y: face.rect.y,
                    width: face.rect.width,
                    height: face.rect.height
                )
            },
            camera: CameraInfo(
                make: photo.metadata.cameraMake,
                model: photo.metadata.cameraModel,
                lens: photo.metadata.lensModel,
                iso: photo.metadata.iso,
                aperture: photo.metadata.fNumber,
                shutterSpeed: photo.metadata.exposureTime,
                focalLength: photo.metadata.focalLength
            ),
            location: photo.metadata.coordinate.map {
                LocationInfo(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    altitude: photo.metadata.altitude,
                    place: photo.metadata.placeName
                )
            },
            sha256: sha256,
            atlasGroup: atlasCopy?.atlasGroup,
            atlasCell: atlasCopy?.atlasCell,
            device: device,
            app: "Backu 1.0"
        )
    }

    func data() throws -> Data {
        try JSONFile.encoder(pretty: true).encode(self)
    }
}

/// The shared index that makes a bucket searchable without listing every object.
struct RemoteIndexDocument: Codable, Sendable {
    struct PersonEntry: Codable, Sendable {
        var id: UUID
        var name: String?
        var isPet: Bool
        var faceCount: Int
        var coverThumbnail: String?
    }

    struct FaceEntry: Codable, Sendable {
        var id: UUID
        var personID: UUID?
        var kind: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct PhotoEntry: Codable, Sendable {
        var id: String
        var key: String
        var sidecarKey: String
        var thumbnailKey: String?
        var atlasGroup: String?
        var atlasCell: Int?
        var sha256: String?
        var filename: String
        var capturedAt: Date?
        var width: Int
        var height: Int
        var isVideo: Bool
        var duration: Double?
        var favorite: Bool
        var tags: [String]
        var personIDs: [UUID]
        var camera: String?
        var lens: String?
        var place: String?
        var latitude: Double?
        var longitude: Double?
        var uti: String?
        var byteCount: Int64
        var faces: [FaceEntry]?
    }

    var schema: String = "backu.index.v1"
    var updatedAt: Date
    var device: String
    var people: [PersonEntry]
    var photos: [PhotoEntry]

    var isEmpty: Bool { photos.isEmpty && people.isEmpty }

    static func make(
        photos: [PhotoItem],
        people: [Person],
        serverID: UUID,
        device: String
    ) -> RemoteIndexDocument {
        var seenHashes = Set<String>()
        let relevant = photos
            .filter { photo in photo.copies.contains { $0.serverID == serverID } }
            .filter { photo in
                guard let sha = photo.sha256 else { return true }
                return seenHashes.insert(sha).inserted
            }
        let referencedPeople = Set(relevant.flatMap { $0.faces.compactMap(\.personID) })
        return RemoteIndexDocument(
            updatedAt: Date(),
            device: device,
            people: people
                .filter { referencedPeople.contains($0.id) }
                .map { person in
                    PersonEntry(
                        id: person.id,
                        name: person.name,
                        isPet: person.isPet,
                        faceCount: person.faceCount,
                        coverThumbnail: nil
                    )
                },
            photos: relevant.compactMap { photo -> PhotoEntry? in
                guard let copy = photo.copy(on: serverID) else { return nil }
                return PhotoEntry(
                    id: photo.id,
                    key: copy.objectKey,
                    sidecarKey: copy.sidecarKey,
                    thumbnailKey: copy.thumbnailKey,
                    atlasGroup: copy.atlasGroup,
                    atlasCell: copy.atlasCell,
                    sha256: photo.sha256,
                    filename: photo.filename,
                    capturedAt: photo.takenAt,
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    isVideo: photo.isVideo,
                    duration: photo.duration,
                    favorite: photo.isFavorite,
                    tags: photo.tags,
                    personIDs: Array(Set(photo.faces.compactMap(\.personID))),
                    camera: photo.metadata.cameraDescription,
                    lens: photo.metadata.lensModel,
                    place: photo.metadata.placeName,
                    latitude: photo.metadata.latitude,
                    longitude: photo.metadata.longitude,
                    uti: photo.metadata.uti,
                    byteCount: copy.byteCount,
                    faces: photo.faces.map { face in
                        FaceEntry(
                            id: face.id,
                            personID: face.personID,
                            kind: face.kind.rawValue,
                            x: face.rect.x,
                            y: face.rect.y,
                            width: face.rect.width,
                            height: face.rect.height
                        )
                    }
                )
            }
        )
    }

    func photoItems(serverID: UUID) -> [PhotoItem] {
        let personMap = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return photos.map { entry in
            var metadata = PhotoMetadata()
            metadata.cameraModel = entry.camera
            metadata.lensModel = entry.lens
            metadata.placeName = entry.place
            metadata.latitude = entry.latitude
            metadata.longitude = entry.longitude
            metadata.uti = entry.uti
            if let uti = entry.uti, let type = UTTypeShim.fileExtension(for: uti) {
                metadata.fileExtension = type
            }

            let copy = PhotoCopy(
                serverID: serverID,
                objectKey: entry.key,
                sidecarKey: entry.sidecarKey,
                thumbnailKey: entry.thumbnailKey,
                uploadedAt: Date(),
                byteCount: entry.byteCount,
                etag: nil,
                sha256: entry.sha256,
                atlasGroup: entry.atlasGroup,
                atlasCell: entry.atlasCell
            )

            let faces: [PhotoFace] = (entry.faces ?? []).compactMap { face in
                if let personID = face.personID, personMap[personID] == nil { return nil }
                return PhotoFace(
                    id: face.id,
                    personID: face.personID,
                    kind: PhotoFace.Kind(rawValue: face.kind) ?? .person,
                    rect: NormRect(x: face.x, y: face.y, width: face.width, height: face.height)
                )
            }

            return PhotoItem(
                id: "remote:\(entry.id)",
                localIdentifier: nil,
                filename: entry.filename,
                takenAt: entry.capturedAt,
                isVideo: entry.isVideo,
                isFavorite: entry.favorite,
                pixelWidth: entry.width,
                pixelHeight: entry.height,
                duration: entry.duration,
                tags: entry.tags,
                metadata: metadata,
                faces: faces,
                copies: [copy],
                sha256: entry.sha256,
                remoteThumbnailKey: entry.thumbnailKey,
                serverID: serverID
            )
        }
    }

    var personRecords: [Person] {
        people.map { Person(id: $0.id, name: $0.name, isPet: $0.isPet, faceCount: $0.faceCount) }
    }
}

enum UTTypeShim {
    static func mimeType(for uti: String) -> String {
        UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func fileExtension(for uti: String) -> String? {
        UTType(uti)?.preferredFilenameExtension
    }

    static func uti(forExtension pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.identifier
    }
}
