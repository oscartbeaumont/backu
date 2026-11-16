import XCTest

final class SearchIndexTests: XCTestCase {
    private func makePhoto(
        id: String,
        filename: String,
        tags: [String] = [],
        camera: String? = nil,
        place: String? = nil,
        year: Int = 2024,
        favorite: Bool = false,
        video: Bool = false,
        people: [UUID] = []
    ) -> PhotoItem {
        var metadata = PhotoMetadata()
        metadata.cameraModel = camera
        metadata.placeName = place
        let faces = people.map { PhotoFace(personID: $0, rect: NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) }
        var components = DateComponents()
        components.year = year
        components.month = 6
        components.day = 12
        return PhotoItem(
            id: id,
            localIdentifier: id,
            filename: filename,
            takenAt: Calendar(identifier: .gregorian).date(from: components),
            isVideo: video,
            isFavorite: favorite,
            pixelWidth: 4000,
            pixelHeight: 3000,
            tags: tags,
            metadata: metadata,
            faces: faces
        )
    }

    func testPrefixSearchAndFilters() {
        let oscar = Person(name: "Oscar")
        let maple = Person(name: "Maple", isPet: true)
        let people = [oscar.id: oscar, maple.id: maple]

        let photos = [
            makePhoto(id: "1", filename: "IMG_1001.HEIC", tags: ["sunset", "new york"], camera: "iPhone 17 Pro", place: "New York", people: [oscar.id]),
            makePhoto(id: "2", filename: "IMG_1002.JPG", tags: ["dog"], camera: "Sony A7", year: 2022, people: [maple.id]),
            makePhoto(id: "3", filename: "VID_2001.MOV", year: 2024, video: true),
            makePhoto(id: "4", filename: "IMG_1004.HEIC", place: "Paris", year: 2023, favorite: true)
        ]
        let index = SearchIndex(photos: photos, people: people)

        XCTAssertEqual(index.search(SearchQuery(text: "suns")), ["1"])
        XCTAssertEqual(index.search(SearchQuery(text: "new y")), ["1"])
        XCTAssertEqual(index.search(SearchQuery(text: "maple")), ["2"])
        XCTAssertEqual(index.search(SearchQuery(text: "IPH")), ["1"])
        XCTAssertEqual(index.search(SearchQuery(text: "paris")), ["4"])
        XCTAssertEqual(index.search(SearchQuery(text: "2022")), ["2"])
        XCTAssertEqual(index.search(SearchQuery(favoritesOnly: true)), ["4"])
        XCTAssertEqual(index.search(SearchQuery(media: .videos)), ["3"])
        XCTAssertEqual(index.search(SearchQuery(text: "new", personIDs: [oscar.id])), ["1"])
        XCTAssertTrue(index.search(SearchQuery(text: "dog", personIDs: [oscar.id])).isEmpty)
        XCTAssertEqual(index.search(SearchQuery(tags: ["dog"])), ["2"])
        XCTAssertEqual(index.search(SearchQuery(text: "sony", cameras: ["sony a7"])), ["2"])
    }

    func testFacetsCountMatches() {
        let people = ["A", "B", "C"].map { Person(name: $0) }
        let map = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let photos = [
            makePhoto(id: "1", filename: "a.jpg", tags: ["sea", "trip"], camera: "iPhone 17 Pro", people: [people[0].id]),
            makePhoto(id: "2", filename: "b.jpg", tags: ["sea"], camera: "iPhone 17 Pro", people: [people[0].id, people[1].id])
        ]
        let index = SearchIndex(photos: photos, people: map)
        let facets = index.facets(limitedTo: ["1", "2"], people: people)
        XCTAssertEqual(facets.tags.first?.value, "sea")
        XCTAssertEqual(facets.tags.first?.count, 2)
        XCTAssertEqual(facets.cameras.first?.value, "iphone 17 pro")
        XCTAssertEqual(facets.people.first?.count, 2)
    }
}
