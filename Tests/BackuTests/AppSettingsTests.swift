import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "backu.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAtlasThumbnailsAreOptInAndPersist() {
        let initial = AppSettings(defaults: defaults)
        XCTAssertFalse(initial.atlasThumbnailsEnabled, "The experimental feature must start off")

        initial.atlasThumbnailsEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.atlasThumbnailsEnabled)
    }

    func testBackupDestinationsRoundTrip() {
        let first = UUID()
        let second = UUID()
        let settings = AppSettings(defaults: defaults)
        settings.backupServerIDs = [first, second]

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.backupServerIDs, [first, second])
    }

    func testMigratesLegacySingleDestination() {
        let id = UUID()
        defaults.set(id.uuidString, forKey: "backupServerID")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.backupServerIDs, [id])
        XCTAssertEqual(defaults.array(forKey: "backupServerIDs") as? [String], [id.uuidString])
    }

    func testEmptyDestinationListStaysEmpty() {
        let settings = AppSettings(defaults: defaults)
        settings.backupServerIDs = [UUID()]
        settings.backupServerIDs = []

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.backupServerIDs.isEmpty)
    }
}
