import Foundation
import XCTest
@testable import LAD

/// The local viewport geometry cache: complete entries, keys bound to replay
/// inputs, least recently used eviction, and design display without a worker.
final class CADGeometryCacheTests: XCTestCase {
    private let python = "/nonexistent/python"

    func testStoredGeometryLoadsAsAPrivateCopyOfTheValidatedBuild() async throws {
        let cache = try makeCache()
        let spec = model("result = cq.Solid.makeBox(1, 1, 1)")
        var built: PreviewMesh? = try preview()
        let original = try XCTUnwrap(built)
        await cache.store(original, for: spec, python: python).value
        built = nil

        let loadedFirst = await cache.preview(for: spec, python: python)
        let loadedSecond = await cache.preview(for: spec, python: python)
        let first = try XCTUnwrap(loadedFirst), second = try XCTUnwrap(loadedSecond)
        for loaded in [first, second] {
            XCTAssertEqual(loaded.positions, original.positions)
            XCTAssertEqual(loaded.vertexNormals, original.vertexNormals)
            XCTAssertEqual(loaded.triangleIndices, original.triangleIndices)
            XCTAssertEqual(loaded.edgePoints, original.edgePoints)
            XCTAssertEqual(loaded.triangleSolids, original.triangleSolids)
            XCTAssertEqual(loaded.edgeSolids, original.edgeSolids)
            XCTAssertEqual(loaded.parts, original.parts)
            XCTAssertEqual(loaded.validatedHash, original.validatedHash)
            XCTAssertEqual(loaded.buildSeconds, original.buildSeconds)
            let artifacts = try XCTUnwrap(loaded.buildArtifacts)
            XCTAssertEqual(loaded.brepPath, artifacts.folder.appendingPathComponent("model.brep").path)
            XCTAssertEqual(loaded.stepPath, artifacts.folder.appendingPathComponent("model.step").path)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: artifacts.folder.path).filter { !$0.hasPrefix(".") },
                           ["model.brep"])
        }
        XCTAssertNotEqual(first.brepPath, second.brepPath, "Each load owns its own native copy")
        XCTAssertNotEqual(first.brepPath, original.brepPath)
        let printing = await cache.preview(for: spec, print: true, python: python)
        XCTAssertNil(printing, "The printing version is a separate entry")
    }

    func testKeysFollowReplayInputsRuntimeAndPrintingButNotDisplayMetadata() {
        let spec = model("result = cq.Solid.makeBox(1, 1, 1)",
                         inputs: [CADInputAsset(id: "ref", name: "ref.step", format: "step", data: Data("A".utf8))])
        let key = CADGeometryCache.key(for: spec, print: false, python: python)
        var renamed = spec
        renamed.title = "Another title"
        renamed.summary = "Another summary"
        renamed.inputAssets?[0].name = "renamed.step"
        XCTAssertEqual(CADGeometryCache.key(for: renamed, print: false, python: python), key)

        var changedInput = spec
        changedInput.inputAssets?[0].data = Data("B".utf8)
        var changedScript = spec
        changedScript.script += "\n"
        var changedUnits = spec
        changedUnits.units = "in"
        var withSource = spec
        withSource.sourceSTEP = Data()
        let others = [
            CADGeometryCache.key(for: spec, print: true, python: python),
            CADGeometryCache.key(for: spec, print: false, python: "/other/python"),
            CADGeometryCache.key(for: changedInput, print: false, python: python),
            CADGeometryCache.key(for: changedScript, print: false, python: python),
            CADGeometryCache.key(for: changedUnits, print: false, python: python),
            CADGeometryCache.key(for: withSource, print: false, python: python)
        ]
        XCTAssertEqual(Set(others + [key]).count, others.count + 1)
    }

    func testLeastRecentlyUsedEntriesAreEvictedBeyondTheBound() async throws {
        let probe = try makeCache()
        await probe.store(try preview(), for: model("probe"), python: python).value
        let entry = probe.byteCount
        XCTAssertGreaterThan(entry, 0)

        // Room for four entries; one entry may take a quarter of the bound.
        let cache = try makeCache(maximumBytes: entry * 4 + entry / 2)
        let specs = (0..<5).map { model("version \($0)") }
        for spec in specs.prefix(4) {
            await cache.store(try preview(), for: spec, python: python).value
            try await Task.sleep(for: .milliseconds(20))
        }
        let touched = await cache.preview(for: specs[0], python: python)
        XCTAssertNotNil(touched, "Loading makes an entry the most recently used")
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(try preview(), for: specs[4], python: python).value

        var kept: [Bool] = []
        for spec in specs { kept.append(await cache.preview(for: spec, python: python) != nil) }
        XCTAssertEqual(kept, [true, false, true, true, true])
        XCTAssertLessThanOrEqual(cache.byteCount, cache.maximumBytes)
    }

    func testOnlyValidatedGeometryWithinTheEntryBoundIsStored() async throws {
        let cache = try makeCache()
        var pending = try preview()
        pending.validatedHash = nil
        pending.pendingValidationHash = String(repeating: "b", count: 64)
        await cache.store(pending, for: model("pending"), python: python).value
        let unvalidated = await cache.preview(for: model("pending"), python: python)
        XCTAssertNil(unvalidated)
        XCTAssertEqual(cache.byteCount, 0)

        let small = try makeCache(maximumBytes: 64)
        await small.store(try preview(), for: model("large"), python: python).value
        let large = await small.preview(for: model("large"), python: python)
        XCTAssertNil(large)
        XCTAssertEqual(small.byteCount, 0)
    }

    func testANewBuildReplacesItsEntry() async throws {
        let cache = try makeCache()
        let spec = model("rebuilt")
        await cache.store(try preview(), for: spec, python: python).value
        var rebuilt = try preview()
        rebuilt.buildSeconds = 1.5
        await cache.store(rebuilt, for: spec, python: python).value
        let loaded = await cache.preview(for: spec, python: python)
        XCTAssertEqual(loaded?.buildSeconds, 1.5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count, 1)
    }

    func testUnreadableEntryIsDiscarded() async throws {
        let cache = try makeCache()
        let spec = model("corrupt")
        await cache.store(try preview(), for: spec, python: python).value
        let entry = cache.directory.appendingPathComponent(CADGeometryCache.key(for: spec, print: false, python: python))
        try Data([1, 2, 3]).write(to: entry.appendingPathComponent("mesh.bin"))
        let loaded = await cache.preview(for: spec, python: python)
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
    }

    @MainActor
    func testStoredRevisionDisplaysCachedGeometryWithoutAWorker() async throws {
        let cache = try makeCache()
        let spec = model("result = cq.Solid.makeBox(1, 1, 1)")
        let cached = try preview()
        await cache.store(cached, for: spec, python: python).value
        let root = try temporaryFolder("autosaves")
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: root), python: python, geometryCache: cache)
        defer { state.cancel() }
        let revision = ProjectRevision(model: spec, parts: cached.parts)
        state.revisions = [revision]
        state.selectedRevisionID = revision.id
        XCTAssertTrue(state.loadStoredRevision())
        let deadline = ContinuousClock.now + .seconds(10)
        while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(state.error)
        let mesh = try XCTUnwrap(state.mesh)
        XCTAssertEqual(mesh.positions, cached.positions)
        XCTAssertEqual(mesh.buildSeconds, cached.buildSeconds)
        XCTAssertEqual(state.revisions[0].validatedHash, cached.validatedHash)
    }

    /// A displayed version and its printing version are kept after their
    /// builds, and a later session displays both from the cache.
    @MainActor
    func testDisplayedDesignAndPrintingVersionsAreReusedByALaterSession() async throws {
        guard ProcessInfo.processInfo.environment["LAD_RUN_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set LAD_RUN_ENGINE_TESTS=1 to build and cache designs with the native CAD runtime.")
        }
        let cache = try makeCache()
        let spec = ModelSpec(title: "Plate", summary: "Cache fixture.", units: "mm", script: """
        plate = cq.Workplane("XY").box(40, 20, 6).val().cut(cq.Solid.makeCylinder(1.6, 10, cq.Vector(0, 0, -5)))
        if lad.print:
            plate = plate.fuse(cq.Solid.makeCylinder(1.6, 0.2, cq.Vector(0, 0, -0.2))).clean()
        result = cq.Assembly(name="Kit", metadata={"lad_id": "kit"}).add(plate, name="Plate", metadata={"lad_id": "plate"})
        """)
        let revision = ProjectRevision(model: spec)

        func session() async throws -> (design: PreviewMesh, printing: PreviewMesh) {
            let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: try temporaryFolder("autosaves")),
                                 geometryCache: cache)
            defer { state.cancel() }
            state.revisions = [revision]
            state.selectedRevisionID = revision.id
            XCTAssertTrue(state.loadStoredRevision())
            let deadline = ContinuousClock.now + .seconds(120)
            while state.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(state.error)
            let design = try XCTUnwrap(state.mesh)
            state.printVersionView = true
            while state.isPreparingPrintView, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(state.error)
            let printing = try XCTUnwrap(state.displayedMesh)
            XCTAssertNotEqual(printing.brepPath, design.brepPath)
            return (design, printing)
        }

        let built = try await session()
        // The replay displays before its deferred verification; it is kept
        // once verified, as is the printing version.
        let deadline = ContinuousClock.now + .seconds(120)
        while try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter({ !$0.hasPrefix(".") }).count < 2,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let reused = try await session()
        XCTAssertEqual(reused.design.buildSeconds, built.design.buildSeconds, "The design was not rebuilt")
        XCTAssertEqual(reused.printing.buildSeconds, built.printing.buildSeconds, "The printing version was not rebuilt")
        XCTAssertEqual(reused.design.positions, built.design.positions)
        XCTAssertEqual(reused.printing.volume, built.printing.volume)
        XCTAssertEqual(reused.design.topology?.faces.count, built.design.topology?.faces.count)

        // Native requests run on the cached solid.
        let face = try XCTUnwrap(reused.design.topology?.faces.first?.id)
        let report = try await EngineService().measure(reused.design, features: [face], solids: [],
                                                        python: EngineService.defaultPython, threads: 2)
        XCTAssertFalse(report.metrics.isEmpty)
    }

    // MARK: - Fixtures

    private func makeCache(maximumBytes: Int64 = CADGeometryCache.defaultMaximumBytes) throws -> CADGeometryCache {
        CADGeometryCache(directory: try temporaryFolder("geometry"), maximumBytes: maximumBytes)
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-geometry-cache-\(name)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func model(_ script: String, inputs: [CADInputAsset]? = nil) -> ModelSpec {
        ModelSpec(title: "Box", summary: "Cache fixture.", units: "mm", script: script, inputAssets: inputs)
    }

    /// A validated single-triangle build with its own native solid file.
    private func preview() throws -> PreviewMesh {
        let artifacts = try EngineBuildArtifacts.create(in: FileManager.default.temporaryDirectory, token: UUID(), containsSTEP: false)
        let brep = artifacts.folder.appendingPathComponent("model.brep")
        try Data("DBRep_DrawableShape\n\nCASCADE Topology V3\n".utf8).write(to: brep)
        return PreviewMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], triangles: [[0, 1, 2]],
                           edges: [[0, 0, 0, 1, 0, 0]], bounds: [0, 0, 0, 1, 1, 0], volume: 1, area: 0.5, solids: 1, faces: 1,
                           buildSeconds: 0.375, threads: 2, stepPath: artifacts.folder.appendingPathComponent("model.step").path,
                           triangleSolids: [0], edgeSolids: [0], parts: [PartNode(id: "body", name: "Body", solidIndices: [0])],
                           brepPath: brep.path, normals: [[0, 0, 1], [0, 0, 1], [0, 0, 1]],
                           validatedHash: String(repeating: "a", count: 64), buildArtifacts: artifacts)
    }
}
