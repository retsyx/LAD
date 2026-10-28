import Foundation
import zlib

/// A portable, single-entry ZIP container. Decompression stays in memory; no
/// archive-controlled paths are ever extracted to disk.
enum ProjectZIP {
    private static let entryName = Data("project.json".utf8)
    private static let overhead = 30 + 12 + 46 + 12 + 22
    private static let localSignature: UInt32 = 0x04034b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let endSignature: UInt32 = 0x06054b50

    static func isZIP(_ data: Data) -> Bool {
        // Recognize damaged and empty ZIPs as containers too, so their errors
        // cannot fall through to the former plain-JSON project reader.
        data.count >= 2 && data.prefix(2).elementsEqual([0x50, 0x4b])
    }

    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= ProjectStore.maximumFileBytes else { throw invalid("Uncompressed design exceeds the 256 MB limit.") }
        let compressed = try deflate(payload)
        let checksum = crc(payload)
        let compressedSize = UInt32(compressed.count)
        let uncompressedSize = UInt32(payload.count)
        var archive = Data(capacity: compressed.count + overhead)

        append(localSignature, to: &archive)
        append(UInt16(20), to: &archive) // ZIP 2.0, DEFLATE
        append(UInt16(0x0800), to: &archive) // UTF-8 name
        append(UInt16(8), to: &archive)
        append(UInt16(0), to: &archive) // Deterministic 1980-01-01 timestamp
        append(UInt16(33), to: &archive)
        append(checksum, to: &archive)
        append(compressedSize, to: &archive)
        append(uncompressedSize, to: &archive)
        append(UInt16(entryName.count), to: &archive)
        append(UInt16(0), to: &archive)
        archive.append(entryName)
        archive.append(compressed)

        let centralOffset = UInt32(archive.count)
        append(centralSignature, to: &archive)
        append(UInt16(20), to: &archive)
        append(UInt16(20), to: &archive)
        append(UInt16(0x0800), to: &archive)
        append(UInt16(8), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(33), to: &archive)
        append(checksum, to: &archive)
        append(compressedSize, to: &archive)
        append(uncompressedSize, to: &archive)
        append(UInt16(entryName.count), to: &archive)
        append(UInt16(0), to: &archive) // Extra fields
        append(UInt16(0), to: &archive) // Entry comment
        append(UInt16(0), to: &archive) // Starting disk
        append(UInt16(0), to: &archive) // Internal attributes
        append(UInt32(0), to: &archive) // External attributes
        append(UInt32(0), to: &archive) // Local header offset
        archive.append(entryName)

        let centralSize = UInt32(archive.count) - centralOffset
        append(endSignature, to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(1), to: &archive)
        append(UInt16(1), to: &archive)
        append(centralSize, to: &archive)
        append(centralOffset, to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    static func decode(_ archive: Data) throws -> Data {
        guard archive.count <= ProjectStore.maximumFileBytes else { throw invalid("File exceeds the 256 MB limit.") }
        guard archive.count >= overhead else { throw invalid("The ZIP container is incomplete.") }
        return try archive.withUnsafeBytes { bytes in
            let reader = Reader(bytes: bytes)
            // ZIP permits an archive comment. Require its declared end to be
            // the actual end, rejecting appended data and partial archives.
            let lastEnd = archive.count - 22
            let firstEnd = max(0, lastEnd - Int(UInt16.max))
            var end: Int?
            for offset in stride(from: lastEnd, through: firstEnd, by: -1) {
                if (try reader.u32(offset)) == endSignature,
                   offset + 22 + Int((try reader.u16(offset + 20))) == archive.count {
                    end = offset
                    break
                }
            }
            guard let end else { throw invalid("The ZIP directory is missing or incomplete.") }
            guard (try reader.u16(end + 4)) == 0, (try reader.u16(end + 6)) == 0,
                  (try reader.u16(end + 8)) == 1, (try reader.u16(end + 10)) == 1 else {
                throw invalid("The ZIP must contain one design manifest entry on a single disk.")
            }
            let centralSize = Int((try reader.u32(end + 12)))
            let central = Int((try reader.u32(end + 16)))
            guard centralSize >= 46 + entryName.count, central + centralSize == end,
                  (try reader.u32(central)) == centralSignature else { throw invalid("The ZIP directory is invalid.") }

            let version = (try reader.u16(central + 6))
            let flags = (try reader.u16(central + 8))
            let method = (try reader.u16(central + 10))
            // Flags 1/2 only describe DEFLATE compression choices; UTF-8 is
            // also supported. Reject encryption and streamed data descriptors.
            guard (10...20).contains(version), flags & ~UInt16(0x0806) == 0,
                  method == 0 || method == 8 else { throw invalid("This ZIP uses unsupported compression or encryption.") }
            let checksum = (try reader.u32(central + 16))
            let compressedSize = Int((try reader.u32(central + 20)))
            let uncompressedSize = Int((try reader.u32(central + 24)))
            guard compressedSize <= ProjectStore.maximumFileBytes,
                  uncompressedSize <= ProjectStore.maximumFileBytes else { throw invalid("Uncompressed design exceeds the 256 MB limit.") }
            let nameSize = Int((try reader.u16(central + 28)))
            let extraSize = Int((try reader.u16(central + 30)))
            let commentSize = Int((try reader.u16(central + 32)))
            guard nameSize == entryName.count, central + 46 + nameSize + extraSize + commentSize == end,
                  (try reader.u16(central + 34)) == 0, (try reader.u32(central + 42)) == 0,
                  reader.matches(entryName, at: central + 46) else { throw invalid("The ZIP must contain only the design manifest.") }
            try reader.validateExtraFields(at: central + 46 + nameSize, count: extraSize)

            guard (try reader.u32(0)) == localSignature,
                  (try reader.u16(4)) == version, (try reader.u16(6)) == flags, (try reader.u16(8)) == method,
                  (try reader.u16(10)) == (try reader.u16(central + 12)), (try reader.u16(12)) == (try reader.u16(central + 14)),
                  (try reader.u32(14)) == checksum, (try reader.u32(18)) == UInt32(compressedSize),
                  (try reader.u32(22)) == UInt32(uncompressedSize), (try reader.u16(26)) == UInt16(nameSize),
                  reader.matches(entryName, at: 30) else { throw invalid("The ZIP entry and directory do not match.") }
            let localExtraSize = Int((try reader.u16(28)))
            let content = 30 + nameSize + localExtraSize
            guard content + compressedSize == central else { throw invalid("The ZIP entry size is invalid.") }
            try reader.validateExtraFields(at: 30 + nameSize, count: localExtraSize)

            let compressed = UnsafeRawBufferPointer(rebasing: bytes[content..<central])
            let payload: Data
            if method == 0 {
                guard compressedSize == uncompressedSize else { throw invalid("The stored ZIP entry size is invalid.") }
                payload = Data(compressed)
            } else {
                payload = try inflate(compressed, expectedSize: uncompressedSize)
            }
            guard crc(payload) == checksum else { throw invalid("The design ZIP checksum does not match.") }
            return payload
        }
    }

    private static func deflate(_ payload: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS,
                            8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("ZIP compression could not start.") }
        defer { deflateEnd(&stream) }
        return try payload.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data(capacity: min(payload.count + 64, 1_048_576))
            var chunk = [UInt8](repeating: 0, count: 65_536)
            try chunk.withUnsafeMutableBytes { output in
                while true {
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = zlib.deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END else { throw invalid("ZIP compression failed.") }
                    let written = output.count - Int(stream.avail_out)
                    guard result.count + written <= ProjectStore.maximumFileBytes - overhead else { throw invalid("Compressed design exceeds the 256 MB limit.") }
                    result.append(output.bindMemory(to: UInt8.self).baseAddress!, count: written)
                    if status == Z_STREAM_END { break }
                }
            }
            return result
        }
    }

    private static func inflate(_ compressed: UnsafeRawBufferPointer, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("ZIP decompression could not start.") }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: compressed.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(compressed.count)
        // One spare byte detects a stream that expands past its declared size,
        // including an allegedly empty stream, without unbounded allocation.
        var output = Data(count: expectedSize + 1)
        let status = output.withUnsafeMutableBytes { buffer -> Int32 in
            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(buffer.count)
            return zlib.inflate(&stream, Z_FINISH)
        }
        guard status == Z_STREAM_END, stream.total_out == expectedSize,
              stream.total_in == compressed.count else { throw invalid("The compressed ZIP entry is damaged or has an invalid size.") }
        output.removeLast()
        return output
    }

    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        append(UInt16(truncatingIfNeeded: value), to: &data)
        append(UInt16(truncatingIfNeeded: value >> 16), to: &data)
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= bytes.count - 2 else { throw invalid("The ZIP headers are truncated.") }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16
        }
        func matches(_ data: Data, at offset: Int) -> Bool {
            offset >= 0 && offset <= bytes.count - data.count && bytes[offset..<offset + data.count].elementsEqual(data)
        }
        func validateExtraFields(at offset: Int, count: Int) throws {
            guard offset >= 0, count >= 0, offset <= bytes.count - count else { throw invalid("The ZIP extra fields are truncated.") }
            var cursor = offset
            let end = offset + count
            while cursor < end {
                guard cursor + 4 <= end else { throw invalid("The ZIP extra fields are invalid.") }
                let type = try u16(cursor)
                let length = Int(try u16(cursor + 2))
                guard type != 1, cursor + 4 + length <= end else { throw invalid("ZIP64 or invalid ZIP extra fields are not supported.") }
                cursor += 4 + length
            }
        }
    }

    private static func invalid(_ reason: String) -> LADError { .message("Invalid LAD design. \(reason)") }
}
