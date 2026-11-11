import Foundation
import XCTest
@testable import LAD

final class ClaudeExecutableDiscoveryTests: XCTestCase {
    func testExplicitChoiceWinsAndMissingChoiceNeverSwitchesInstallations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let explicit = try fixture.executable("custom/claude")
        let automatic = try fixture.executable("bin/claude")
        var discoveryCalls = 0
        func discover() -> String? { discoveryCalls += 1; return automatic.path }
        XCTAssertEqual(ClaudeExecutable.configuredPath(override: " \(explicit.path)\n", automatic: discover), explicit.path)
        try FileManager.default.removeItem(at: explicit)
        XCTAssertEqual(ClaudeExecutable.configuredPath(override: explicit.path, automatic: discover), explicit.path)
        XCTAssertEqual(discoveryCalls, 0)
        XCTAssertEqual(ClaudeExecutable.configuredPath(override: nil, automatic: discover), automatic.path)
        XCTAssertEqual(discoveryCalls, 1)
    }

    func testSelfUpdatingInstallationsPrecedeExtensionsAndPackageManagerCopies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let native = try fixture.executable("UserHome/.local/bin/claude")
        _ = try fixture.executable("UserHome/.vscode/extensions/anthropic.claude-code-2.1.322-darwin-arm64/resources/native-binary/claude")
        let path = try fixture.executable("nvm/bin/claude")
        let found = ClaudeExecutable.find(installations: [native, fixture.root.appendingPathComponent("homebrew/bin/claude")],
            extensionDirectories: [fixture.root.appendingPathComponent("UserHome/.vscode/extensions")],
            searchDirectories: [path.deletingLastPathComponent()])
        XCTAssertEqual(found, native.path)
    }

    func testNewestEditorExtensionPrecedesStalePathInstallations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let extensions = fixture.root.appendingPathComponent("UserHome/.vscode/extensions")
        _ = try fixture.executable("UserHome/.vscode/extensions/anthropic.claude-code-2.1.39-darwin-arm64/resources/native-binary/claude")
        let newest = try fixture.executable("UserHome/.vscode/extensions/anthropic.claude-code-2.1.322-darwin-arm64/resources/native-binary/claude")
        _ = try fixture.executable("UserHome/.vscode/extensions/anthropic.claude-code-2.2.0-darwin-arm64/resources/README")
        _ = try fixture.executable("UserHome/.vscode/extensions/other.claude-code-9.0.0/resources/native-binary/claude")
        let stale = try fixture.executable("nvm/v22/bin/claude")
        let found = ClaudeExecutable.find(installations: [fixture.root.appendingPathComponent("missing/claude")],
                                          extensionDirectories: [extensions], searchDirectories: [stale.deletingLastPathComponent()])
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, newest.resolvingSymlinksInPath().path)
        XCTAssertEqual(ClaudeExecutable.find(installations: [], extensionDirectories: [],
                                             searchDirectories: [stale.deletingLastPathComponent()]), stale.path)
        XCTAssertNil(ClaudeExecutable.find(installations: [], extensionDirectories: [], searchDirectories: []))
    }

    func testDirectoriesAndNonExecutableFilesAreNotInstallations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("dir/claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = fixture.root.appendingPathComponent("plain/claude")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        XCTAssertNil(ClaudeExecutable.find(installations: [directory, plain], extensionDirectories: [], searchDirectories: []))
        XCTAssertNil(ClaudeExecutable.resolve("relative/claude"))
        XCTAssertNil(ClaudeExecutable.resolve("   "))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Claude-Discovery-\(UUID().uuidString)", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func executable(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
