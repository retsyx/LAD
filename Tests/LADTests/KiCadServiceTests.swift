import Darwin
import Foundation
import XCTest
@testable import LAD

final class KiCadServiceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-KiCad-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func executable(in directory: URL, body: String = "") throws -> URL {
        let script = directory.appendingPathComponent("fake kicad-cli")
        let program = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$PWD/arguments.txt"
        printf '%s\\n' "$KICAD_CONFIG_HOME" "$KICAD_DOCUMENTS_HOME" "$KICAD10_3RD_PARTY" "$HOME" > "$PWD/locations.txt"
        out=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '--output' ]; then shift; out="$1"; fi
            shift
        done
        \(body)
        printf 'ISO-10303-21;\\nHEADER;\\nENDSEC;\\nDATA;\\nENDSEC;\\nEND-ISO-10303-21;\\n' > "$out"
        printf 'STEP export completed\\n'
        """
        try Data(program.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func board(in directory: URL, models: String = "", name: String = "board.kicad_pcb") throws -> URL {
        let board = directory.appendingPathComponent(name)
        try Data("(kicad_pcb (version 20260206) (general (thickness 1.5422)) \(models))".utf8).write(to: board)
        return board
    }

    @MainActor
    func testDirectArgumentsPrivateOutputAndSourceProjectStayUnchanged() async throws {
        let directory = try temporaryDirectory()
        let model = directory.appendingPathComponent("My component.step")
        try Data("ISO-10303-21;\nEND-ISO-10303-21;".utf8).write(to: model)
        let source = try board(in: directory, models: """
        (footprint "Custom" (property "Reference" "U1") (model "${KIPRJMOD}/My component.step" (offset (xyz 0 0 0))))
        """, name: "PCB ' $(touch no).kicad_pcb")
        let original = try Data(contentsOf: source)
        let project = source.deletingPathExtension().appendingPathExtension("kicad_pro")
        let originalProject = Data("{\"text_variables\":{\"REVISION\":\"A\"}}".utf8)
        try originalProject.write(to: project)
        let service = KiCadService(executable: try executable(in: directory), recoverMissingModels: false)
        let result = try await service.exportSTEP(board: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: result.stepURL.deletingLastPathComponent()) }
        XCTAssertEqual(result.boardURL, source.resolvingSymlinksInPath())
        XCTAssertEqual(result.boardThickness, 1.5422)
        XCTAssertEqual(result.modeledComponents, 1)
        XCTAssertTrue(result.missingModels.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: project), originalProject)
        let folder = result.stepURL.deletingLastPathComponent()
        XCTAssertNotEqual(folder, directory)
        let locations = try String(contentsOf: folder.appendingPathComponent("locations.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(locations, [folder.appendingPathComponent("config").path, folder.appendingPathComponent("documents").path,
                                   folder.appendingPathComponent("packages").path, FileManager.default.homeDirectoryForCurrentUser.path])
        let settings = folder.appendingPathComponent("config/10.0")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings.appendingPathComponent("kicad.json"))) as? [String: Any])
        let pcm = try XCTUnwrap(json["pcm"] as? [String: Any])
        XCTAssertEqual(pcm["lib_auto_add"] as? Bool, false)
        XCTAssertEqual(pcm["lib_auto_remove"] as? Bool, false)
        XCTAssertEqual(pcm["check_for_updates"] as? Bool, false)
        for (file, head) in [("fp-lib-table", "fp_lib_table"), ("sym-lib-table", "sym_lib_table"), ("design-block-lib-table", "design_block_lib_table")] {
            XCTAssertEqual(try String(contentsOf: settings.appendingPathComponent(file)), "(\(head) (version 7))\n")
        }
        let arguments = try String(contentsOf: folder.appendingPathComponent("arguments.txt")).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, ["pcb", "export", "step", "--subst-models", "--user-origin", "0x0mm", "--output", result.stepURL.path, folder.appendingPathComponent(source.lastPathComponent).path])
        let staged = try String(contentsOf: folder.appendingPathComponent(source.lastPathComponent))
        XCTAssertTrue(staged.contains(model.resolvingSymlinksInPath().path))
        XCTAssertFalse(staged.contains("${KIPRJMOD}"))
        XCTAssertTrue(result.diagnostics.contains("STEP export completed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("no").path))
    }

    @MainActor
    func testReportsUnavailableGeometryAndIgnoresHiddenModels() async throws {
        let directory = try temporaryDirectory()
        let source = try board(in: directory, models: """
        (footprint "HDMI" (property "Reference" "J1") (model "${KICAD10_3DMODEL_DIR}/Connector_Video.3dshapes/missing.step"))
        (footprint "Other" (property "Reference" "J2") (model "${KIPRJMOD}/hidden.step" (hide yes)))
        """)
        let result = try await KiCadService(executable: executable(in: directory), recoverMissingModels: false).exportSTEP(board: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: result.stepURL.deletingLastPathComponent()) }
        XCTAssertEqual(result.missingModels, ["J1: ${KICAD10_3DMODEL_DIR}/Connector_Video.3dshapes/missing.step"])
        XCTAssertEqual(result.modeledComponents, 0)
        XCTAssertTrue(result.diagnostics.contains("omitted from STEP"))
        XCTAssertFalse(result.diagnostics.contains("hidden.step"))
    }

    @MainActor
    func testCachedOfficialModelsResolveDuplicateReferencesWithoutChangingPCB() async throws {
        let directory = try temporaryDirectory()
        let relative = "Connector_Video.3dshapes/HDMI_A_Amphenol_10029449-x01xLF_Horizontal.step"
        let cache = directory.appendingPathComponent("cache")
        let model = cache.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ISO-10303-21;\nEND-ISO-10303-21;".utf8).write(to: model)
        let source = try board(in: directory, models: """
        (footprint "HDMI" (property "Reference" "J1") (model "${KICAD10_3DMODEL_DIR}/\(relative)"))
        (footprint "HDMI" (property "Reference" "J2") (model "${KICAD10_3DMODEL_DIR}/\(relative)"))
        """)
        let original = try Data(contentsOf: source)
        let result = try await KiCadService(executable: executable(in: directory), recoverMissingModels: false, modelCache: cache).exportSTEP(board: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: result.stepURL.deletingLastPathComponent()) }
        XCTAssertTrue(result.missingModels.isEmpty)
        XCTAssertEqual(result.recoveredModels.count, 2)
        XCTAssertEqual(result.modeledComponents, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let staged = try String(contentsOf: result.stepURL.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent))
        XCTAssertTrue(staged.contains(model.path))
        XCTAssertFalse(staged.contains("${KICAD10_3DMODEL_DIR}"))
    }

    @MainActor
    func testOfficialRecoveryURLsCannotEscapeStandardModelRepository() {
        XCTAssertEqual(KiCadService.standardLibraryPath("${KICAD10_3DMODEL_DIR}/Connector_Video.3dshapes/part.wrl"), "Connector_Video.3dshapes/part.step")
        XCTAssertEqual(KiCadService.officialModelURL("Connector_Video.3dshapes/part.step")?.host, "gitlab.com")
        for path in ["../../secret.step", "Other/part.step", "Connector_Video.3dshapes/../part.step", "Connector_Video.3dshapes/part.step?url=evil", "Connector_Video.3dshapes/file.py", "//evil.com/file.step"] {
            XCTAssertNil(KiCadService.officialModelURL(path), path)
        }
        XCTAssertNil(KiCadService.standardLibraryPath("${KIPRJMOD}/models/private.step"))
        XCTAssertNil(KiCadService.standardLibraryPath("https://example.com/part.step"))
    }

    @MainActor
    func testNonzeroExitIncludesBoundedDiagnosticsAndRejectsMissingOutput() async throws {
        let directory = try temporaryDirectory()
        let source = try board(in: directory)
        let fake = try executable(in: directory, body: """
        /usr/bin/head -c 150000 /dev/zero
        /usr/bin/head -c 150000 /dev/zero >&2
        printf 'Exact KiCad failure\\n' >&2
        exit 7
        """)
        do {
            _ = try await KiCadService(executable: fake, recoverMissingModels: false).exportSTEP(board: source)
            XCTFail("Expected KiCad failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit 7"))
            XCTAssertTrue(error.localizedDescription.contains("Exact KiCad failure"))
            XCTAssertLessThan(error.localizedDescription.utf8.count, 5_000)
        }
        _ = try executable(in: directory, body: "exit 0")
        do {
            _ = try await KiCadService(executable: fake, recoverMissingModels: false).exportSTEP(board: source)
            XCTFail("Expected missing output failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing")) }
    }

    @MainActor
    func testCancellationAndTimeoutStopRunningNativeProcess() async throws {
        let directory = try temporaryDirectory()
        let source = try board(in: directory)
        let fake = try executable(in: directory, body: "exec /bin/sleep 30")
        let service = KiCadService(executable: fake, recoverMissingModels: false)
        let task = Task { try await service.exportSTEP(board: source) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        service.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let deadlineService = KiCadService(executable: fake, timeout: 0.1, recoverMissingModels: false)
        do { _ = try await deadlineService.exportSTEP(board: source); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("export limit")) }
    }

    @MainActor
    func testInvalidBoardInputsFailBeforeLaunch() async throws {
        let directory = try temporaryDirectory()
        let service = KiCadService(executable: try executable(in: directory), recoverMissingModels: false)
        let source = directory.appendingPathComponent("not-board.kicad_pcb")
        try Data("(not_a_board)".utf8).write(to: source)
        do { _ = try await service.exportSTEP(board: source); XCTFail("Expected invalid board") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not a KiCad")) }
        let fifo = directory.appendingPathComponent("fifo.kicad_pcb")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do { _ = try await service.exportSTEP(board: fifo); XCTFail("Expected regular-file check") }
        catch { XCTAssertTrue(error.localizedDescription.contains("regular file")) }
    }

    @MainActor
    func testInstalledKiCadExportsExactBoardAndAllReferencedModels() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_KICAD_TEST_BOARD"] else {
            throw XCTSkip("Set LAD_KICAD_TEST_BOARD to verify the installed KiCad CLI against a real board.")
        }
        let cache = ProcessInfo.processInfo.environment["LAD_KICAD_MODEL_CACHE"].map { URL(fileURLWithPath: $0) }
        let source = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: source)
        let result = try await KiCadService(modelCache: cache).exportSTEP(board: source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(result.missingModels.isEmpty, result.diagnostics)
        XCTAssertGreaterThan(result.modeledComponents, 0)
        XCTAssertGreaterThan(try Data(contentsOf: result.stepURL).count, 1_000)
        print("Real KiCad STEP: \(result.stepURL.path)\n\(result.diagnostics)")
    }
}
