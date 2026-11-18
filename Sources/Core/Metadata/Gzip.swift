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

    /// Decompresses a gzip file in bounded chunks. The caller sees each decoded
    /// chunk once and can drop it, so a 60 MB JSONL body never has to be
    /// resident at the same time as its 13 MB compressed form.
    static func decompress(
        fileURL: URL,
        chunkSize: Int = 64 * 1024,
        verifyChecksum: Bool = true,
        onChunk: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        guard fileSize >= 18 else { throw GzipError.truncated }
        let trailerStart = fileSize - 8

        try handle.seek(toOffset: UInt64(trailerStart))
        guard let trailer = try handle.read(upToCount: 8), trailer.count == 8 else {
            throw GzipError.truncated
        }
        let bytes = [UInt8](trailer)
        let expectedCRC = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        let expectedSize = Int(bytes[4])
            | Int(bytes[5]) << 8
            | Int(bytes[6]) << 16
            | Int(bytes[7]) << 24
        guard expectedSize >= 0, expectedSize <= maximumInputBytes else {
            throw GzipError.tooLarge
        }

        try handle.seek(toOffset: 0)
        // The header is ten bytes for anything this app writes, but optional
        // FEXTRA/FNAME/FCOMMENT fields must be skipped, so read enough to find
        // the deflate stream's first byte.
        var headerBuffer = Data()
        var headerLength: Int?
        while headerLength == nil {
            guard let more = try handle.read(upToCount: min(chunkSize, trailerStart)) else {
                throw GzipError.truncated
            }
            if more.isEmpty { throw GzipError.truncated }
            headerBuffer.append(more)
            headerLength = try gzipHeaderLength(headerBuffer)
            if headerBuffer.count > trailerStart { throw GzipError.truncated }
        }
        guard let start = headerLength, start <= headerBuffer.count else {
            throw GzipError.truncated
        }

        // `compression_stream` needs valid pointers even before the first
        // process call; a one-byte scratch buffer is enough to seed it.
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { throw GzipError.corrupt }

        let outputCapacity = max(chunkSize, 256 * 1024)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer {
            output.deallocate()
            compression_stream_destroy(&stream)
        }

        var crc: UInt32 = 0xFFFF_FFFF
        var produced: Int64 = 0
        var ended = false

        func drain(_ base: UnsafePointer<UInt8>, _ count: Int, finalizing: Bool) throws {
            stream.src_ptr = base
            stream.src_size = count
            while true {
                stream.dst_ptr = output
                stream.dst_size = outputCapacity
                let consumedBefore = stream.src_size
                let status = compression_stream_process(
                    &stream,
                    finalizing ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                )
                let written = outputCapacity - stream.dst_size
                if written > 0 {
                    let chunk = UnsafeRawBufferPointer(start: output, count: written)
                    produced += Int64(written)
                    if verifyChecksum { crc = CRC32.update(crc, chunk) }
                    try onChunk(chunk)
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // More input is needed only when the decoder also has
                    // nothing buffered to hand back. A full output buffer, or
                    // pending output with no input left, means keep calling.
                    if stream.src_size == 0, written == 0 { return }
                    if written == 0, stream.src_size == consumedBefore { throw GzipError.corrupt }
                case COMPRESSION_STATUS_END:
                    ended = true
                    return
                default:
                    throw GzipError.corrupt
                }
            }
        }

        if start < headerBuffer.count {
            let remainder = headerBuffer.subdata(in: start..<headerBuffer.count)
            try remainder.withUnsafeBytes { raw in
                try drain(
                    raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(scratch),
                    raw.count,
                    finalizing: false
                )
            }
        }
        // `headerBuffer` already consumed this much of the file.
        var readOffset = headerBuffer.count
        while !ended, readOffset < fileSize - 8 {
            let want = min(chunkSize, fileSize - 8 - readOffset)
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                throw GzipError.truncated
            }
            readOffset += chunk.count
            try chunk.withUnsafeBytes { raw in
                try drain(
                    raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(scratch),
                    raw.count,
                    finalizing: false
                )
            }
        }
        if !ended {
            try drain(UnsafePointer(scratch), 0, finalizing: true)
        }
        guard produced == Int64(expectedSize) else { throw GzipError.corrupt }
        if verifyChecksum, CRC32.finalize(crc) != expectedCRC { throw GzipError.corrupt }
    }

    /// Length of a gzip header, or nil when `bytes` does not hold all of it.
    private static func gzipHeaderLength(_ data: Data) throws -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return nil }
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw GzipError.invalidHeader
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { return nil }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { return nil }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        return offset <= bytes.count ? offset : nil
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
        data.withUnsafeBytes { buffer in
            finalize(update(0xFFFF_FFFF, buffer))
        }
    }

    /// Running checksum, so a streamed decompressor never needs the whole body.
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var value = crc
        for byte in bytes.bindMemory(to: UInt8.self) {
            value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value
    }

    static func finalize(_ crc: UInt32) -> UInt32 {
        crc ^ 0xFFFF_FFFF
    }
}
