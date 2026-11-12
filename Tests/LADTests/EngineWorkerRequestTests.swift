import Foundation
import XCTest
@testable import LAD

/// Engine/worker.py accepts each operation's exact field set; these are the
/// fields the app sent before requests were typed.
final class EngineWorkerRequestTests: XCTestCase {
    private let source = EngineWorkerRequest.NativeSource(identity: "/builds/a/model.brep", validated: true)
    private let pose = AssemblySolidTransform(solid: 1, matrix: [1, 0, 0, 5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    func testBuildRequestsCarryOnlyTheProgramAndStagedInputs() throws {
        let plain = EngineWorkerRequest.build(title: "Box", summary: "A box.", units: "mm", script: "result = 1\n",
                                              sourceAsset: nil, inputAssets: [])
        XCTAssertEqual(try object(plain), ["title": "Box", "summary": "A box.", "units": "mm", "script": "result = 1\n"])
        let imported = EngineWorkerRequest.build(title: "Box", summary: "A box.", units: "mm", script: "result = 1\n",
            sourceAsset: "source.step",
            inputAssets: [.init(id: "asset-1", name: "part.stl", format: "stl", path: "input-000.stl")])
        XCTAssertEqual(try object(imported), [
            "title": "Box", "summary": "A box.", "units": "mm", "script": "result = 1\n", "sourceAsset": "source.step",
            "inputAssets": [["id": "asset-1", "name": "part.stl", "format": "stl", "path": "input-000.stl"]]
        ])
        XCTAssertEqual(try object(.runtime), ["operation": "runtime"])
    }

    func testNativeRequestsNameTheStagedSolidAndOmitDefaultOptions() throws {
        let native: NSDictionary = ["brepAsset": "source.brep", "nativeIdentity": "/builds/a/model.brep", "validatedNative": true]
        func with(_ fields: [String: Any]) -> NSDictionary {
            let merged = NSMutableDictionary(dictionary: native)
            merged.addEntries(from: fields)
            return merged
        }
        XCTAssertEqual(try object(.export(source, .init(solidIndices: nil))), with(["operation": "export"]))
        let color = PartColor(red: 1, green: 0.5, blue: 0)
        let export = EngineWorkerRequest.Export(solidIndices: [0, 2], solidTransforms: [pose],
            solidColors: [.init(solidIndex: 2, color: color)], arrangeFor3DPrinting: true, individualParts: [[0], [2]])
        XCTAssertEqual(try object(.export(source, export)), with([
            "operation": "export", "solidIndices": [0, 2], "solidTransforms": [["solid": 1, "matrix": pose.matrix]],
            "solidColors": [["solidIndex": 2, "color": ["red": 1, "green": 0.5, "blue": 0]]],
            "arrangeFor3DPrinting": true, "individualParts": [[0], [2]]
        ]))
        let feature = CADFeatureID(kind: .edge, solidIndex: 0, localIndex: 3)
        XCTAssertEqual(try object(.measure(source, features: [feature], solidIndices: [], solidTransforms: nil)), with([
            "operation": "measure", "features": [["kind": "edge", "solidIndex": 0, "localIndex": 3]], "solidIndices": []
        ]))
        XCTAssertEqual(try object(.measure(source, features: [], solidIndices: [1], solidTransforms: [])), with([
            "operation": "measure", "features": [], "solidIndices": [1], "solidTransforms": []
        ]), "Posed measurements keep an explicit, possibly empty, transform list.")
        XCTAssertEqual(try object(.clearance(source, pairs: [[[0], [1, 2]]], poses: [[pose], []])), with([
            "operation": "clearance", "pairs": [[[0], [1, 2]]], "poses": [[["solid": 1, "matrix": pose.matrix]], []]
        ]))
    }

    func testRequestIsWrittenWhereTheWorkerReadsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-worker-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try EngineWorkerRequest.runtime.write(to: folder)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("request.json")))
        XCTAssertEqual(written as? NSDictionary, ["operation": "runtime"])
    }

    private func object(_ request: EngineWorkerRequest) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
    }
}
