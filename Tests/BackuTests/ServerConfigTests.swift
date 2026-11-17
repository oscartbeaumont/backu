import XCTest

final class ServerConfigTests: XCTestCase {
    func testPrefixIsOptionalAndNormalised() {
        let prefixed = ServerConfig(
            name: "Prefixed",
            provider: .custom,
            endpoint: "https://s3.example.com",
            bucket: "photos",
            accessKeyID: "key",
            prefix: " /Photos/ ",
            pathStyle: true
        )
        XCTAssertEqual(prefixed.normalizedPrefix, "Photos")
        XCTAssertEqual(prefixed.folderDescription, "Photos")

        var root = prefixed
        root.prefix = ""
        XCTAssertEqual(root.normalizedPrefix, "")
        XCTAssertEqual(root.folderDescription, "Bucket root")

        root.prefix = "  /  "
        XCTAssertEqual(root.normalizedPrefix, "")
        XCTAssertEqual(root.folderDescription, "Bucket root")
    }

    func testRootPrefixKeepsObjectKeysUnchanged() {
        let photo = PhotoItem(
            id: "asset:prefix-test",
            filename: "IMG_0001.HEIC",
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let root = ServerConfig(
            name: "Root",
            provider: .custom,
            endpoint: "https://s3.example.com",
            bucket: "photos",
            accessKeyID: "key",
            prefix: "",
            pathStyle: true
        )
        let key = BackupEngine.objectKey(for: photo, in: root)
        XCTAssertTrue(key.hasPrefix("Photos/"), key)
        XCTAssertFalse(key.hasPrefix("/"), key)
        XCTAssertEqual(BackupEngine.objectKey(for: photo, in: root), key)

        var nested = root
        nested.prefix = "Archive"
        XCTAssertTrue(BackupEngine.objectKey(for: photo, in: nested).hasPrefix("Archive/Photos/"))

        var stored = photo
        let folderOnly = ServerConfig(
            name: "Folder",
            provider: .custom,
            endpoint: "https://s3.example.com",
            bucket: "photos",
            accessKeyID: "key",
            prefix: "Backu",
            pathStyle: true
        )
        stored.copies = [
            PhotoCopy(
                serverID: folderOnly.id,
                objectKey: "Backu/Photos/2023/11/IMG_0001-abcd1234.HEIC",
                sidecarKey: "Backu/Photos/2023/11/IMG_0001-abcd1234.HEIC.json",
                uploadedAt: Date(),
                byteCount: 1,
                etag: nil,
                sha256: "abc"
            )
        ]
        // Existing uploads keep their recorded path even when the prefix changes.
        XCTAssertEqual(
            BackupEngine.objectKey(for: stored, in: folderOnly),
            "Backu/Photos/2023/11/IMG_0001-abcd1234.HEIC"
        )
    }
}
