import Foundation
import XCTest
@testable import LAD

final class AgentToolCatalogTests: XCTestCase {
    func testHostPropertiesDescribeAuthorizationImagesAndPermissionPrompts() throws {
        let catalog = try AgentToolCatalog.native()
        var capabilities: [ExternalAgentCapability: Set<String>] = [:]
        for tool in catalog.tools { capabilities[tool.host.capability, default: []].insert(tool.name) }
        let mesh = Set(catalog.tools.map(\.name).filter { $0.hasPrefix("lad_mesh_") })
        XCTAssertEqual(capabilities[.capture], ["lad_screenshot"])
        XCTAssertEqual(capabilities[.export], ["lad_export_step", "lad_mesh_export_step"])
        XCTAssertEqual(capabilities[.build], Set(["lad_build", "lad_import", "lad_request_permission", "lad_set_part_colors"])
            .union(mesh).subtracting(["lad_mesh_export_step"]))
        XCTAssertNil(capabilities[.commit], "Only the external transport commits candidates.")
        XCTAssertNil(capabilities[.manageProjects])
        XCTAssertEqual(catalog.imageToolNames, ["lad_render", "lad_screenshot"])
        XCTAssertEqual(ProjectActivityEvent.savedImageTools, catalog.imageToolNames)
        XCTAssertEqual(catalog.tools.filter(\.host.requestsPermission).map(\.name), ["lad_request_permission"])
        XCTAssertEqual(Set(catalog.tools.filter(\.host.reconstruction).map(\.name)), mesh)
        XCTAssertEqual(Set(catalog.tools.filter { !$0.host.references.isEmpty }.map(\.name)), ["lad_import", "lad_mesh_open_reference"])
        for tool in catalog.tools {
            XCTAssertEqual(tool.annotations["readOnlyHint"] as? Bool, [.read, .capture].contains(tool.host.capability), tool.name)
        }
    }

    func testCatalogRejectsDuplicateToolsAndHostArgumentsOutsideTheSchema() throws {
        func catalog(_ tools: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: tools) }
        func tool(_ name: String, host: [String: Any]) -> [String: Any] {
            ["name": name, "description": "Fixture", "annotations": ["readOnlyHint": true],
             "inputSchema": ["type": "object", "properties": ["path": ["type": "string"]]], "host": host]
        }
        let valid = try AgentToolCatalog.load(catalog([tool("one", host: ["capability": "export", "exportPath": "path"])]))
        XCTAssertEqual(valid["one"]?.host.exportPath, "path")
        XCTAssertEqual(valid["one"]?.host.returnsImage, false)
        XCTAssertThrowsError(try AgentToolCatalog.load(catalog([tool("one", host: ["capability": "read"]),
                                                                tool("one", host: ["capability": "read"])])))
        XCTAssertThrowsError(try AgentToolCatalog.load(catalog([tool("one", host: ["capability": "read", "sources": ["queryPath"]])])))
        XCTAssertThrowsError(try AgentToolCatalog.load(catalog([tool("one", host: ["capability": "everything"])])))
        XCTAssertThrowsError(try AgentToolCatalog.load(catalog([tool("one", host: [:])])))
    }

    func testResultSerializesMetadataOnceAndWrapsItForTheBridge() throws {
        let metadata: [String: Any] = ["path": "/workspace/renders/a.png", "zoom": 1.5, "items": [1, 2], "name": "Bracket"]
        let image = CADAgentToolResult.Image(path: "/workspace/renders/a.png", data: Data([0x89, 0x50]))
        let result = try CADAgentToolResult(metadata: metadata, image: image)
        XCTAssertEqual(result.text, #"{"items":[1,2],"name":"Bracket","path":"/workspace/renders/a.png","zoom":1.5}"#)
        XCTAssertEqual(result.envelope as NSDictionary, ["content": [
            ["type": "text", "text": result.text],
            ["type": "image_path", "path": image.path, "mimeType": "image/png"]
        ]] as NSDictionary)
        let failed = try CADAgentToolResult(metadata: ["status": "error"], isError: true)
        XCTAssertEqual(failed.envelope["isError"] as? Bool, true)
        XCTAssertEqual((failed.envelope["content"] as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testCallsRecordTheSourceFilesTheirHostPropertiesName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-tool-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try CADAgentTools(directory: root, python: "/missing/python", threads: 1, current: nil,
                                      currentPreview: nil, engine: EngineService())
        let workspace = try CADAgentWorkspace(directory: root)
        try workspace.write(Data("result = cq.Solid.makeBox(1, 1, 1)\n".utf8), path: "program")
        try workspace.write(Data("print('convert')\n".utf8), path: "convert.py")
        try workspace.write(Data("solid\nendsolid\n".utf8), path: "part.stl")
        try workspace.write(Data("result = cq.Solid.makeBox(2, 2, 2)\n".utf8), path: "edit-program.py")
        try workspace.write(JSONSerialization.data(withJSONObject: ["programPath": "edit-program.py"]), path: "edit.json")
        var events: [ProjectActivityEvent] = []
        let call = CADAgentToolCall(tools: tools, workspace: workspace, onActivity: { events.append($0) })
        let cases: [(String, [String: Any], [String])] = [
            ("lad_build", ["programPath": "program"], ["program.py"]),
            ("lad_import", ["path": "part.stl", "producerPaths": ["convert.py"]], ["convert.py"]),
            ("lad_mesh_try_edit", ["contextID": "missing", "revisionID": "r0", "editPath": "edit.json"], ["edit.json", "edit-program.py"])
        ]
        for (index, (name, arguments, expected)) in cases.enumerated() {
            do {
                _ = try await call.perform(id: "tool:\(index)", name: name, arguments: arguments)
                XCTFail("\(name) needs a CAD runtime or reconstruction context.")
            } catch {}
            let running = try XCTUnwrap(events.first { $0.id == "tool:\(index)" && $0.status == "running" })
            XCTAssertEqual(running.files?.map(\.name), expected, name)
            XCTAssertEqual(events.last?.status, "failed")
            XCTAssertEqual(events.last?.files?.map(\.name), expected)
        }
    }
}
