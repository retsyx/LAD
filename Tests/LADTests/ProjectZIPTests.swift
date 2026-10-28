import XCTest
@testable import LAD

final class ProjectZIPTests: XCTestCase {
    func testEmptyTextAndBinaryPayloadsRoundtripDeterministically() throws {
        let payloads = [Data(), fixturePayload, Data((0...255).map(UInt8.init)),
                        Data(repeating: 65, count: 1_000_000)]
        for payload in payloads {
            let archive = try ProjectZIP.encode(payload)
            XCTAssertTrue(ProjectZIP.isZIP(archive))
            XCTAssertEqual(try ProjectZIP.decode(archive), payload)
            XCTAssertEqual(try ProjectZIP.encode(payload), archive)
        }
        let repeated = Data(repeating: 65, count: 1_000_000)
        XCTAssertLessThan(try ProjectZIP.encode(repeated).count, repeated.count / 100)
        XCTAssertFalse(ProjectZIP.isZIP(Data("{\"formatVersion\":4}".utf8)))
        XCTAssertTrue(ProjectZIP.isZIP(Data([0x50, 0x4b])))
    }

    func testStandardUnzipReadsGeneratedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-ZIP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Roundtrip.lad")
        try ProjectZIP.encode(fixturePayload).write(to: file)

        let check = try unzip(["-t", file.path])
        XCTAssertEqual(check.status, 0, String(decoding: check.output, as: UTF8.self))
        let extracted = try unzip(["-p", file.path, "project.json"])
        XCTAssertEqual(extracted.status, 0)
        XCTAssertEqual(extracted.output, fixturePayload)
    }

    func testReadsIndependentPythonDeflateAndStoredZIPFixtures() throws {
        // Created using Python's zipfile, rather than LAD's ZIP writer. The
        // stored fixture also has UT extras plus file and archive comments.
        for encoded in [deflateFixture, storedFixture] {
            let archive = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(try ProjectZIP.decode(archive), fixturePayload)
        }
    }

    func testRejectsTruncationAndAppendedData() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        for length in [0, 1, 2, 29, 41, 42, archive.count - 23, archive.count - 1] {
            XCTAssertThrowsError(try ProjectZIP.decode(archive.prefix(length)), "Truncation at \(length)")
        }
        XCTAssertThrowsError(try ProjectZIP.decode(archive + Data([0])))
    }

    func testRejectsDamagedDataAndCRC() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        let central = centralOffset(archive)
        var corrupted = archive
        corrupted[42 + (central - 42) / 2] ^= 0x80
        XCTAssertThrowsError(try ProjectZIP.decode(corrupted))

        corrupted = archive
        set32(0, in: &corrupted, at: 14)
        set32(0, in: &corrupted, at: central + 16)
        XCTAssertThrowsError(try ProjectZIP.decode(corrupted))
    }

    func testRejectsMismatchedHeadersAndUnsafeEntryNames() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        let central = centralOffset(archive)
        for offset in [4, 6, 8, 10, 12, 14, 18, 22, 26, 28, 30] {
            var corrupted = archive
            corrupted[offset] ^= 1
            XCTAssertThrowsError(try ProjectZIP.decode(corrupted), "Local header byte \(offset)")
        }
        var traversal = archive
        let unsafeName = Data("../evil.json".utf8)
        XCTAssertEqual(unsafeName.count, 12)
        traversal.replaceSubrange(30..<42, with: unsafeName)
        traversal.replaceSubrange(central + 46..<central + 58, with: unsafeName)
        XCTAssertThrowsError(try ProjectZIP.decode(traversal))
    }

    func testRejectsEncryptionUnsupportedMethodsAndZIP64() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        let central = centralOffset(archive)
        let mutations: [(inout Data) -> Void] = [
            { self.set16(0x0801, in: &$0, at: 6); self.set16(0x0801, in: &$0, at: central + 8) },
            { self.set16(0x0808, in: &$0, at: 6); self.set16(0x0808, in: &$0, at: central + 8) },
            { self.set16(12, in: &$0, at: 8); self.set16(12, in: &$0, at: central + 10) },
            { self.set16(45, in: &$0, at: 4); self.set16(45, in: &$0, at: central + 6) },
            { self.set32(UInt32.max, in: &$0, at: 18); self.set32(UInt32.max, in: &$0, at: central + 20) },
            { self.set32(UInt32.max, in: &$0, at: 22); self.set32(UInt32.max, in: &$0, at: central + 24) }
        ]
        for mutate in mutations {
            var corrupted = archive
            mutate(&corrupted)
            XCTAssertThrowsError(try ProjectZIP.decode(corrupted))
        }
        var zip64Extra = try XCTUnwrap(Data(base64Encoded: storedFixture))
        set16(1, in: &zip64Extra, at: 42)
        XCTAssertThrowsError(try ProjectZIP.decode(zip64Extra))
    }

    func testRejectsMultipleEntriesSplitArchivesAndBadDirectoryOffsets() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        let end = archive.count - 22
        let central = centralOffset(archive)
        let mutations: [(inout Data) -> Void] = [
            { self.set16(2, in: &$0, at: end + 8); self.set16(2, in: &$0, at: end + 10) },
            { self.set16(1, in: &$0, at: end + 4) },
            { self.set16(1, in: &$0, at: end + 6) },
            { self.set16(1, in: &$0, at: central + 34) },
            { self.set32(1, in: &$0, at: central + 42) },
            { self.set32(UInt32.max, in: &$0, at: end + 12) },
            { self.set32(UInt32.max, in: &$0, at: end + 16) }
        ]
        for mutate in mutations {
            var corrupted = archive
            mutate(&corrupted)
            XCTAssertThrowsError(try ProjectZIP.decode(corrupted))
        }
    }

    func testRejectsDeclaredSizeBombsAndIncorrectDecompressedSizes() throws {
        let archive = try ProjectZIP.encode(fixturePayload)
        let central = centralOffset(archive)
        for size in [0, fixturePayload.count - 1, fixturePayload.count + 1, ProjectStore.maximumFileBytes + 1] {
            var corrupted = archive
            set32(UInt32(size), in: &corrupted, at: 22)
            set32(UInt32(size), in: &corrupted, at: central + 24)
            XCTAssertThrowsError(try ProjectZIP.decode(corrupted), "Declared size \(size)")
        }
        var stored = try XCTUnwrap(Data(base64Encoded: storedFixture))
        let storedCentral = centralOffset(stored)
        set32(UInt32(fixturePayload.count - 1), in: &stored, at: 22)
        set32(UInt32(fixturePayload.count - 1), in: &stored, at: storedCentral + 24)
        XCTAssertThrowsError(try ProjectZIP.decode(stored))
    }

    func testRejectsCompressedTrailingDataAndMalformedExtras() throws {
        var archive = try ProjectZIP.encode(fixturePayload)
        let oldCentral = centralOffset(archive)
        archive.insert(0, at: oldCentral)
        let central = oldCentral + 1
        let compressedSize = central - 42
        set32(UInt32(compressedSize), in: &archive, at: 18)
        set32(UInt32(compressedSize), in: &archive, at: central + 20)
        set32(UInt32(central), in: &archive, at: archive.count - 6)
        XCTAssertThrowsError(try ProjectZIP.decode(archive))

        var stored = try XCTUnwrap(Data(base64Encoded: storedFixture))
        set16(UInt16.max, in: &stored, at: 44)
        XCTAssertThrowsError(try ProjectZIP.decode(stored))
    }

    private let fixturePayload = Data("{\"project\":\"LAD\",\"history\":[\"draft\",\"refined\"]}\n".utf8)
    private let deflateFixture = "UEsDBBQAAAAIAABgWV2b6jUIMQAAADAAAAAMAAAAcHJvamVjdC5qc29uq1YqKMrPSk0uUbJS8nF0UdJRysgsLskvqlSyilZKKUpMKwEKFaWmZealpijF1nIBAFBLAQIUAxQAAAAIAABgWV2b6jUIMQAAADAAAAAMAAAAAAAAAAAAAACAAQAAAABwcm9qZWN0Lmpzb25QSwUGAAAAAAEAAQA6AAAAWwAAAAAA"
    private let storedFixture = "UEsDBBQAAAAAAABgWV2b6jUIMAAAADAAAAAMAAkAcHJvamVjdC5qc29uVVQFAAEAAAAAeyJwcm9qZWN0IjoiTEFEIiwiaGlzdG9yeSI6WyJkcmFmdCIsInJlZmluZWQiXX0KUEsBAhQDFAAAAAAAAGBZXZvqNQgwAAAAMAAAAAwACQAOAAAAAAAAAIABAAAAAHByb2plY3QuanNvblVUBQABAAAAAGVudHJ5IG1ldGFkYXRhUEsFBgAAAAABAAEAUQAAAGMAAAAPAGFyY2hpdmUgY29tbWVudA=="

    private func centralOffset(_ archive: Data) -> Int {
        // For fixtures with a comment, find the actual EOCD as a standard ZIP
        // reader does. Test data uses no signature bytes inside comments.
        let signature = Data([0x50, 0x4b, 0x05, 0x06])
        let end = archive.range(of: signature, options: .backwards)!.lowerBound
        return Int(archive[end + 16]) | Int(archive[end + 17]) << 8 |
            Int(archive[end + 18]) << 16 | Int(archive[end + 19]) << 24
    }

    private func unzip(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func set16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func set32(_ value: UInt32, in data: inout Data, at offset: Int) {
        set16(UInt16(truncatingIfNeeded: value), in: &data, at: offset)
        set16(UInt16(truncatingIfNeeded: value >> 16), in: &data, at: offset + 2)
    }
}
