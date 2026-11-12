import CryptoKit
import XCTest
@testable import LAD

final class SHA256HexTests: XCTestCase {
    func testKnownDigestsUseLowercaseHex() {
        XCTAssertEqual(SHA256.hexDigest(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testIncrementalDigestMatchesWholeData() {
        let bytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var hash = SHA256()
        hash.update(data: bytes.prefix(4_096))
        hash.update(data: bytes.dropFirst(4_096))
        XCTAssertEqual(hash.finalize().hexString, SHA256.hexDigest(bytes))
        XCTAssertEqual(SHA256.hexDigest(bytes),
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
