import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

enum AppPaths {
    static let bundleFolderName = "Backu"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(bundleFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var catalogFile: URL {
        supportDirectory.appendingPathComponent("catalog.json")
    }

    static var serversFile: URL {
        supportDirectory.appendingPathComponent("servers.json")
    }

    static var embeddingsFile: URL {
        supportDirectory.appendingPathComponent("face-embeddings.bin")
    }

    static var thumbnailCache: URL {
        let url = supportDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var imageCache: URL {
        let url = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var stagingDirectory: URL {
        let url = supportDirectory.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var geocodeCacheFile: URL {
        supportDirectory.appendingPathComponent("places.json")
    }

    static var uploadJournalFile: URL {
        supportDirectory.appendingPathComponent("upload-journal.json")
    }

    /// Clears half-written exports and keeps biometric data out of iCloud
    /// device backups, matching the privacy copy in the app.
    static func prepareForLaunch() {
        let files = try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
        for file in files ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        for url in [embeddingsFile, thumbnailCache, imageCache] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        pruneDirectory(imageCache, maxBytes: 500 * 1024 * 1024)
        pruneDirectory(thumbnailCache, maxBytes: 250 * 1024 * 1024)
        pruneStaleTransferScratch()
    }

    /// A process killed mid-download leaves its assembled-range directory
    /// behind. Those can be tens of megabytes, so clear anything older than an
    /// hour rather than waiting for the cache size prune to catch it.
    private static func pruneStaleTransferScratch() {
        let deadline = Date().addingTimeInterval(-60 * 60)
        for directory in [imageCache, stagingDirectory] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.lastPathComponent.hasPrefix(".backu-download-") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < deadline {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// Keeps the on-disk preview cache bounded on devices with a large library.
    private static func pruneDirectory(_ directory: URL, maxBytes: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
