import XCTest
@testable import LAD

final class ProjectNamingTests: XCTestCase {
    func testInlineNamesTrimOuterWhitespaceAndOptionalExtensionWithoutRemovingPunctuation() throws {
        XCTAssertEqual(try ProjectNaming.userName("  PCB case — v2.1 [USB-C].LAD  "), "PCB case — v2.1 [USB-C]")
        XCTAssertEqual(try ProjectNaming.userName("Case  with  spaces"), "Case  with  spaces")
        XCTAssertEqual(try ProjectNaming.userName("Enclosure + PCB (rev 2)"), "Enclosure + PCB (rev 2)")
        XCTAssertEqual(try ProjectNaming.userName("Café 🔩"), "Café 🔩")
        XCTAssertEqual(Array(try ProjectNaming.userName("Cafe\u{301}").utf8), Array("Café".utf8))
    }

    func testInlineNamesRejectEmptyHiddenPathAndControlCharacterNames() {
        for name in ["", "   ", ".", "..", ".lad", ".hidden", "Case/base", "Case:base", "Case\nbase", "Case\u{0}base"] {
            XCTAssertThrowsError(try ProjectNaming.userName(name), "Accepted invalid project name: \(name.debugDescription)")
        }
    }

    func testFilenameLimitUsesUTF8BytesAndReservesRoomForCollisionSuffixes() throws {
        XCTAssertEqual(try ProjectNaming.userName(String(repeating: "é", count: 110)), String(repeating: "é", count: 110))
        XCTAssertThrowsError(try ProjectNaming.userName(String(repeating: "é", count: 111)))
        XCTAssertThrowsError(try ProjectNaming.userName(String(repeating: "a", count: 221)))
    }

    func testSavedNamesValidateTheBaseWithoutStrippingAnotherExtension() throws {
        let name = try ProjectNaming.userName("Enclosure.lad.lad")
        XCTAssertEqual(name, "Enclosure.lad")
        XCTAssertNoThrow(try ProjectNaming.validateSavedName(name))
        for name in [" Case", "Case ", "Cafe\u{301}", "Case/base", ".hidden", "", String(repeating: "a", count: 221)] {
            XCTAssertThrowsError(try ProjectNaming.validateSavedName(name), "Accepted unnormalized saved name")
        }
    }
}
