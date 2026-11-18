import Compression
import Foundation

/// Standard gzip framing around Apple's raw DEFLATE.
///
/// `Compression` only exposes raw zlib/deflate streams, which cannot be opened
/// by `gunzip`, Python's `gzip`, or any other tool. The metadata log is meant to
/// stay inspectable from outside the app, so the ten-byte header and CRC trailer
/// are written here. Everything else is the system encoder.
enum Gzip {
    enum GzipError: Error {
        case tooLarge
        case invalidHeader
        case truncated
        case corrupt
    }

    /// Refuses to compress anything larger than this. A metadata snapshot for a
    /// million photos still fits comfortably; a runaway buffer should fail
    /// loudly rather than allocate gigabytes.
    static let maximumInputBytes = 512 * 1024 * 1024

    static func compress(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes else { throw GzipError.tooLarge }
        let deflated = try deflate(data)
        var output = Data(capacity: deflated.count + 18)
        // ID1 ID2 CM FLG MTIME(4) XFL OS
        output.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        output.append(deflated)
        var crc = CRC32.checksum(data).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 18 else { throw GzipError.truncated }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw GzipError.invalidHeader
        }
        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw GzipError.truncated }
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset + 8 <= bytes.count else { throw GzipError.truncated }

        let trailerStart = bytes.count - 8
        guard offset <= trailerStart else { throw GzipError.truncated }
        let expectedSize = Int(bytes[trailerStart + 4])
            | Int(bytes[trailerStart + 5]) << 8
            | Int(bytes[trailerStart + 6]) << 16
            | Int(bytes[trailerStart + 7]) << 24
        guard expectedSize >= 0, expectedSize <= maximumInputBytes else {
            throw GzipError.tooLarge
        }

        let deflated = data.subdata(in: offset..<trailerStart)
        let inflated = try inflate(deflated, expectedSize: expectedSize)
        let expectedCRC = UInt32(bytes[trailerStart])
            | UInt32(bytes[trailerStart + 1]) << 8
            | UInt32(bytes[trailerStart + 2]) << 16
            | UInt32(bytes[trailerStart + 3]) << 24
        guard CRC32.checksum(inflated) == expectedCRC else { throw GzipError.corrupt }
        return inflated
    }

    // MARK: - DEFLATE

    private static func deflate(_ data: Data) throws -> Data {
        if data.isEmpty {
            // Canonical empty raw-deflate stream.
            return Data([0x03, 0x00])
        }
        var capacity = max(64, data.count / 2)
        while capacity <= maximumInputBytes {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let destinationBase = destination.baseAddress else { return 0 }
                return data.withUnsafeBytes { source -> Int in
                    guard let sourceBase = source.baseAddress else { return 0 }
                    return compression_encode_buffer(
                        destinationBase.assumingMemoryBound(to: UInt8.self),
                        capacity,
                        sourceBase.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                output.removeSubrange(written..<output.count)
                return output
            }
            capacity *= 2
        }
        throw GzipError.tooLarge
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    sourceBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw GzipError.corrupt }
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
