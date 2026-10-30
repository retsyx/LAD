import Foundation
import XCTest
@testable import LAD

final class CodexExecutableDiscoveryTests: XCTestCase {
    func testExplicitChoiceWinsAndMissingChoiceNeverSwitchesInstallations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let explicit = try fixture.executable("custom/codex")
        let automatic = try fixture.executable("bin/codex")
        var discoveryCalls = 0
        func discover() -> String? { discoveryCalls += 1; return automatic.path }

        XCTAssertEqual(CodexExecutable.configuredPath(override: "  \(explicit.path)\n", automatic: discover), explicit.path)
        try FileManager.default.removeItem(at: explicit)
        XCTAssertEqual(CodexExecutable.configuredPath(override: explicit.path, automatic: discover), explicit.path)
        XCTAssertEqual(discoveryCalls, 0, "A missing explicit choice must remain visible instead of selecting another account or installation.")
        XCTAssertEqual(CodexExecutable.configuredPath(override: " \n", automatic: discover), automatic.path)
        XCTAssertEqual(discoveryCalls, 1)
    }

    func testNamedExplicitChoiceResolvesInItsSearchDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let explicit = try fixture.executable("custom/bin/codex")
        let directories = [explicit.deletingLastPathComponent()]
        XCTAssertEqual(CodexExecutable.configuredPath(override: "codex", searchDirectories: directories,
                                                     automatic: { XCTFail("Explicit choice must win"); return nil }), explicit.path)
    }

    func testFinderDiscoveryWorksWithoutInteractiveShellPATH() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("UserHome/.local/bin/codex")
        let directories = CodexExecutable.searchDirectories(path: nil, home: fixture.root.appendingPathComponent("UserHome"),
                                                            installationDirectories: [fixture.root.appendingPathComponent("system-bin")])
        let found = CodexExecutable.find(applicationBundles: [], searchDirectories: directories,
                                         extensionDirectories: [])
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       expected.resolvingSymlinksInPath().path)
    }

    func testNVMDiscoveryUsesNewestAvailableInstallationWithoutRunningShell() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.executable("UserHome/.nvm/versions/node/v9.0.0/bin/codex")
        let expected = try fixture.executable("UserHome/.nvm/versions/node/v20.0.0/bin/codex")
        _ = try fixture.executable("UserHome/.nvm/versions/node/v22.0.0/bin/node")
        let directories = CodexExecutable.searchDirectories(path: nil, home: fixture.root.appendingPathComponent("UserHome"),
                                                            installationDirectories: [])
        XCTAssertEqual(CodexExecutable.resolve("codex", searchDirectories: directories)?.resolvingSymlinksInPath(),
                       expected.resolvingSymlinksInPath())
    }

    func testSearchIgnoresRelativeAndDuplicatePATHEntries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("bin/codex")
        let directories = CodexExecutable.searchDirectories(path: ":.:relative-bin:\(expected.deletingLastPathComponent().path):\(expected.deletingLastPathComponent().path):",
                                                            home: fixture.root.appendingPathComponent("UserHome"),
                                                            installationDirectories: [])
        // Foundation may standardize /private/var to /var on macOS. Compare
        // these automatic search locations by their filesystem destinations.
        let canonicalDirectories = directories.map { $0.resolvingSymlinksInPath().path }
        let expectedDirectory = expected.deletingLastPathComponent().resolvingSymlinksInPath().path
        XCTAssertEqual(canonicalDirectories.first, expectedDirectory)
        XCTAssertEqual(canonicalDirectories.filter { $0 == expectedDirectory }.count, 1)
        XCTAssertTrue(directories.allSatisfy { ($0.path as NSString).isAbsolutePath })
        XCTAssertEqual(CodexExecutable.resolve("codex", searchDirectories: directories)?.resolvingSymlinksInPath(),
                       expected.resolvingSymlinksInPath())
        XCTAssertNil(CodexExecutable.resolve("bin/codex", searchDirectories: directories))
        XCTAssertNil(CodexExecutable.resolve("", searchDirectories: directories))
    }

    func testCodexApplicationPrecedesChatGPTApplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
        _ = try fixture.executable("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
    }

    func testAppLauncherTakesPriorityOverPATHAndEditorExtension() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let launcher = try fixture.executable("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        _ = try fixture.executable("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        _ = try fixture.executable("bin/codex")
        _ = try fixture.executable("extensions/openai.chatgpt-99.0.0/bin/macos-aarch64/codex")
        XCTAssertEqual(fixture.discover(), launcher.path)
    }

    func testTraditionalAppLayoutAndUserApplicationDirectoriesAreSupported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("UserApplications/Codex.app/Contents/Resources/codex")
        _ = try fixture.executable("bin/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
    }

    func testNestedNativeAppExecutableRemainsAvailableWithoutLauncher() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        _ = try fixture.executable("bin/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
    }

    func testMissingOrNonexecutableApplicationsFallBackToExecutableSearchOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.executable("Applications/Codex.app/Contents/Resources/codex", permissions: 0o644)
        _ = try fixture.executable("bin/codex", permissions: 0o644)
        let expected = try fixture.executable("second-bin/codex")
        _ = try fixture.executable("extensions/openai.chatgpt-99.0.0/bin/macos-aarch64/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
        let first = try fixture.executable("bin/codex")
        XCTAssertEqual(fixture.discover(), first.path)
    }

    func testEditorFallbackChoosesNewestExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.executable("extensions/openai.chatgpt-12.0.0/bin/macos-aarch64/codex", permissions: 0o644)
        _ = try fixture.executable("extensions/openai.chatgpt-9.0.0/bin/macos-aarch64/codex")
        let expected = try fixture.executable("extensions/openai.chatgpt-10.0.0/bin/macos-aarch64/codex")
        _ = try fixture.executable("extensions/unrelated.extension-999.0.0/bin/macos-aarch64/codex")
        XCTAssertEqual(fixture.discover(), expected.path,
                       "Version ordering must be numeric and nonexecutable entries must be skipped.")
    }

    func testEditorInsidersIsAnAvailableFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("insiders-extensions/openai.chatgpt-10.0.0/bin/macos-aarch64/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
    }

    func testExecutableDirectoriesAreIgnoredDuringDiscoveryAndExplicitResolution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["Applications/Codex.app/Contents/Resources/codex", "bin/codex",
                     "extensions/openai.chatgpt-20.0.0/bin/macos-aarch64/codex"] {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let expected = try fixture.executable("extensions/openai.chatgpt-10.0.0/bin/macos-aarch64/codex")
        XCTAssertEqual(fixture.discover(), expected.path)
        XCTAssertNil(CodexService.resolveExecutable(fixture.root.appendingPathComponent("bin/codex").path))
    }

    func testExplicitExecutableAndSymlinkAreResolvedWithoutChoosingAnotherInstallation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try fixture.executable("custom-codex")
        let link = fixture.root.appendingPathComponent("linked-codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: expected)
        XCTAssertEqual(CodexService.resolveExecutable(expected.path), expected)
        XCTAssertEqual(CodexService.resolveExecutable(link.path), link)
        XCTAssertNil(CodexService.resolveExecutable(fixture.root.appendingPathComponent("absent-codex").path))
    }

    func testNoInstallationsProduceNoExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertNil(fixture.discover())
    }

    private final class Fixture {
        let root: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-Codex-discovery-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            root = try EngineArtifact.canonicalDirectory(directory)
        }

        func executable(_ path: String, permissions: Int = 0o755) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return url
        }

        func discover() -> String? {
            CodexService.findExecutable(applicationBundles: [
                root.appendingPathComponent("Applications/Codex.app"),
                root.appendingPathComponent("UserApplications/Codex.app"),
                root.appendingPathComponent("Applications/ChatGPT.app"),
                root.appendingPathComponent("UserApplications/ChatGPT.app")
            ], searchDirectories: [root.appendingPathComponent("bin"), root.appendingPathComponent("second-bin")],
               extensionDirectories: [root.appendingPathComponent("extensions"), root.appendingPathComponent("insiders-extensions")])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
