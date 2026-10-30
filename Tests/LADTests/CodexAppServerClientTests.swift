import Foundation
import XCTest
@testable import LAD

final class CodexAppServerClientTests: XCTestCase {
    func testPackagedReleaseVersionIsUsedForCodexAttribution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-client-version-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("LAD.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "studio.lad.test-client-version", "CFBundleShortVersionString": "2.3.4"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(CodexAppServerClient.info(in: bundle), ["name": "lad", "title": "LAD", "version": "2.3.4"])
    }
}
