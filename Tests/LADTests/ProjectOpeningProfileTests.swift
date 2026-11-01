import AppKit
import SceneKit
import XCTest
@testable import LAD

/// Read-only, opt-in stage timings for a saved project; no machine-specific thresholds.
final class ProjectOpeningProfileTests: XCTestCase {
    @MainActor
    func testProfileOpening() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAD_PROFILE_PROJECT"] else {
            throw XCTSkip("Set LAD_PROFILE_PROJECT to a saved design to profile opening.")
        }
        let clock = ProcessInfo.processInfo
        var timings = [String: Double]()
        var start = clock.systemUptime
        var project = try ProjectStore.read(from: URL(fileURLWithPath: path))
        timings["archiveReadDecodeValidate"] = clock.systemUptime - start
        let revision = try XCTUnwrap(project.revisions.first { $0.id == project.selectedRevisionID })
        start = clock.systemUptime
        let python = try await CADRuntimeManager.resolvePython(EngineService.defaultPython)
        timings["runtimeReady"] = clock.systemUptime - start
        start = clock.systemUptime
        let receipt = ProcessInfo.processInfo.environment["LAD_PROFILE_VALIDATED_HASH"] ?? revision.validatedHash
        let preview = try await EngineService().buildPreview(revision.model, python: python, threads: 8, validatedHash: receipt)
        timings["engineTotal"] = clock.systemUptime - start
        timings["workerReportedBuild"] = preview.buildSeconds
        if let copyPath = ProcessInfo.processInfo.environment["LAD_PROFILE_SAVE_COPY"],
           let index = project.revisions.firstIndex(where: { $0.id == revision.id }) {
            project.revisions[index].validatedHash = preview.validatedHash
            try ProjectStore.write(project, to: URL(fileURLWithPath: copyPath))
        }
        // Repeat the consumer stages separately to explain engine time outside buildSeconds.
        // These diagnostic samples overlap engineTotal and are not additive opening stages.
        start = clock.systemUptime
        let resultData = try Data(contentsOf: URL(fileURLWithPath: preview.brepPath!).deletingLastPathComponent().appendingPathComponent("result.json"))
        timings["samplePreviewRead"] = clock.systemUptime - start
        start = clock.systemUptime
        let decoded = try JSONDecoder().decode(PreviewMesh.self, from: resultData)
        timings["samplePreviewDecode"] = clock.systemUptime - start
        start = clock.systemUptime
        try ProjectStore.validatePreview(decoded)
        timings["samplePreviewValidation"] = clock.systemUptime - start
        start = clock.systemUptime
        try CADMeasurements.validateTopology(decoded)
        timings["sampleTopologyValidation"] = clock.systemUptime - start
        // Preserve only temporary profiling inputs/results, never change the source archive.
        let folder = URL(fileURLWithPath: try XCTUnwrap(preview.brepPath)).deletingLastPathComponent()
        let retained = URL(fileURLWithPath: "/tmp/lad-opening-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: folder, to: retained)
        print("LAD_PROFILE_ARTIFACTS \(retained.path)")
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required.") }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        defer { _ = app.setActivationPolicy(policy) }
        start = clock.systemUptime
        let view = CADSceneView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let frames = ProjectOpeningFrames()
        view.delegate = frames
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { view.delegate = nil; window.orderOut(nil); window.contentView = nil; window.close() }
        timings["viewCreation"] = clock.systemUptime - start
        start = clock.systemUptime
        view.update(mesh: preview, mode: project.displayMode ?? .edges, grid: project.showGrid ?? true,
                    command: nil, selectedSolids: [], hiddenSolids: Set(revision.hiddenSolids ?? []),
                    projection: project.projectionMode ?? .perspective)
        timings["sceneInstall"] = clock.systemUptime - start
        start = clock.systemUptime
        let deadline = clock.systemUptime + 120
        while view.isPreparingResources, clock.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isPreparingResources)
        timings["scenePrepareWait"] = clock.systemUptime - start
        start = clock.systemUptime
        let before = frames.count
        while frames.count <= before, clock.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(frames.count, before)
        timings["visibleFrameWait"] = clock.systemUptime - start
        let report: [String: Any] = ["seconds": timings, "project": URL(fileURLWithPath: path).lastPathComponent,
                                   "solids": preview.solids, "faces": preview.faces,
                                   "vertices": preview.vertices.count, "triangles": preview.triangles.count,
                                   "artifactDirectory": retained.path, "python": python,
                                   "validatedHash": preview.validatedHash ?? "", "reusedValidation": receipt == preview.validatedHash]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/lad-project-opening-profile.json"), options: .atomic)
        print("LAD_PROFILE \(String(decoding: data, as: UTF8.self))")
    }
}

private final class ProjectOpeningFrames: NSObject, SCNSceneRendererDelegate {
    private let lock = NSLock()
    private var rendered = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return rendered }
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); rendered += 1; lock.unlock()
    }
}
