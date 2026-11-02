import CoreFoundation
import CryptoKit
import Foundation

/// Immutable reconstruction snapshots and branch cursors for one agent task.
/// Commits here never change the design window; final CAD uses the usual path.
@MainActor
final class CADMeshSession {
    struct Output {
        var values: [String: Any]
        var program: String?
        var preview: PreviewMesh?
    }
    private struct Record { var contextID: String; var data: Data }
    private struct Branch { var contextID: String; var history: [String]; var index: Int }
    private let workspace: CADAgentWorkspace
    private var contexts: [String: Data] = [:]
    private var revisions: [String: Record] = [:]
    private var previews: [String: Record] = [:]
    private var evidence: [String: Record] = [:]
    private var fits: [String: Record] = [:]
    private var comparisons: [String: Record] = [:]
    private var branches: [String: Branch] = [:]
    private var currentBranches: [String: String] = [:]
    private var native: [String: Data] = [:]
    private var display: [String: PreviewMesh] = [:]
    private var displayOrder: [String] = []
    private var recordBytes = 0
    private var nativeBytes = 0
    private var fileBytes = 0
    private var files = Set<String>()
    private let maximumBytes = 256 * 1024 * 1024

    init(workspace: CADAgentWorkspace) { self.workspace = workspace }

    func program(contextID: String, revisionID: String) throws -> String? {
        let value = try resolve(revisionID, context: contextID, previewsAllowed: false)
        return try object(value.data)["script"] as? String
    }

    func handle(name: String, arguments: [String: Any], engine: EngineService,
                python: String, threads: Int, solidColors: [Int: PartColor] = [:]) async throws -> Output {
        if ["lad_mesh_commit", "lad_mesh_undo", "lad_mesh_redo", "lad_mesh_branch"].contains(name) {
            return try transaction(name, arguments)
        }
        var assets: [String: Data] = [:]
        var request: [String: Any] = ["operation": String(name.dropFirst(4))]
        var options: [String: Any] = [:]
        let contextID: String?
        let targetID: String?
        if name == "lad_mesh_open_reference" {
            try allowed(arguments, ["path", "units", "maxDeviation", "sourceKind", "policyPath"])
            let path = try text("path", arguments)
            let suffix = try workspace.url(path).pathExtension.lowercased()
            guard ["stl", "json"].contains(suffix) else { throw LADError.message("Open an STL or indexed triangle JSON reference.") }
            guard let number = arguments["maxDeviation"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else {
                throw LADError.message("Declare a finite nonnegative maximum deviation in the source units.")
            }
            let access = workspace
            assets["source." + suffix] = try await Task.detached(priority: .userInitiated) {
                try access.read(path, maximumBytes: 128_000_000)
            }.value
            request["sourceAsset"] = "source." + suffix
            options = ["units": try text("units", arguments), "max_deviation": number.doubleValue,
                       "source_kind": arguments["sourceKind"] ?? "unknown"]
            try stageJSON("policyPath", arguments, as: "policy.json", key: "policyAsset", assets: &assets, request: &request)
            contextID = nil; targetID = nil
        } else {
            let context = try text("contextID", arguments)
            guard let data = contexts[context] else { throw LADError.message("This reference context is unavailable in the current task.") }
            contextID = context; assets["context.json"] = data; request["contextAsset"] = "context.json"
            let id = try text(name == "lad_mesh_compare" ? "targetID" : "revisionID", arguments)
            let record = try resolve(id, context: context, previewsAllowed: name == "lad_mesh_compare")
            targetID = id; assets["revision.json"] = record.data; request["revisionAsset"] = "revision.json"
            let definition = try object(record.data)
            if let hash = definition["geometry_hash"] as? String {
                guard let bytes = native[hash] else { throw LADError.message("This reconstruction's exact geometry is unavailable.") }
                assets["source.brep"] = bytes; request["brepAsset"] = "source.brep"
            }
            switch name {
            case "lad_mesh_inspect":
                try allowed(arguments, ["contextID", "revisionID", "queryPath"])
                try stageJSON("queryPath", arguments, as: "query.json", key: "queryAsset", required: true, assets: &assets, request: &request)
                let query = try object(assets["query.json"]!)
                let records = try referencedRecords(query, pool: evidence, context: context)
                assets["evidence.json"] = try json(records); request["evidenceAsset"] = "evidence.json"
            case "lad_mesh_fit":
                try allowed(arguments, ["contextID", "revisionID", "evidenceIDs", "families", "constraintsPath"])
                let ids = try strings("evidenceIDs", arguments)
                guard !ids.isEmpty else { throw LADError.message("Select evidence from lad_mesh_inspect before fitting.") }
                let records = try ids.map { try self.record($0, pool: evidence, context: context) }
                assets["evidence.json"] = try json(records); request["evidenceAsset"] = "evidence.json"
                options["families"] = arguments["families"] ?? "auto"
                try stageJSON("constraintsPath", arguments, as: "constraints.json", key: "constraintsAsset", assets: &assets, request: &request, array: true)
            case "lad_mesh_try_edit":
                try allowed(arguments, ["contextID", "revisionID", "editPath", "programPath"])
                try stageJSON("editPath", arguments, as: "edit.json", key: "editAsset", required: true, assets: &assets, request: &request)
                var edit = try object(assets["edit.json"]!)
                guard !containsInlineSource(edit) else { throw LADError.message("Supply CAD source through programPath, never inline in the edit record or an atomic child edit.") }
                if let programPath = arguments["programPath"] ?? edit.removeValue(forKey: "programPath") {
                    guard let path = programPath as? String else { throw LADError.message("Use a CAD program file path.") }
                    assets["program.py"] = try workspace.read(path, maximumBytes: 200_000)
                    request["programAsset"] = "program.py"
                }
                assets["edit.json"] = try json(edit)
                let records = try referencedRecords(edit, pool: fits, context: context)
                assets["fits.json"] = try json(records); request["fitsAsset"] = "fits.json"
            case "lad_mesh_compare":
                try allowed(arguments, ["contextID", "targetID", "scope", "quality"])
                options = ["scope": arguments["scope"] ?? "all", "quality": arguments["quality"] ?? "preview"]
            case "lad_mesh_export_step":
                try allowed(arguments, ["contextID", "revisionID", "comparisonID", "path"])
                let report = try self.record(try text("comparisonID", arguments), pool: comparisons, context: context)
                guard report["model_ref"] as? String == id else { throw LADError.message("The acceptance report belongs to another reconstruction revision.") }
                assets["comparison.json"] = try json(report); request["comparisonAsset"] = "comparison.json"
                let colors: [[String: Any]] = solidColors.keys.sorted().map { index in
                    let color = solidColors[index]!
                    return ["solidIndex": index, "color": ["red": color.red, "green": color.green, "blue": color.blue]]
                }
                assets["colors.json"] = try json(colors); request["colorsAsset"] = "colors.json"
            default: throw LADError.message("The reconstruction command is unavailable.")
            }
        }
        request["options"] = options
        let output = try await engine.meshOperation(request: json(request), files: assets, python: python, threads: threads)
        try Task.checkCancellation()
        var values = try object(output.metadata)
        for key in ["native_preview", "program_available", "step_available"] { values.removeValue(forKey: key) }
        let recordData = output.record
        let full = try await Task.detached(priority: .userInitiated) {
            guard let value = try JSONSerialization.jsonObject(with: recordData) as? [String: Any] else {
                throw LADError.message("The reconstruction returned an invalid record.")
            }
            return value
        }.value
        try Task.checkCancellation()
        guard full["status"] as? String != "error" else { return Output(values: values, program: nil, preview: nil) }
        let recordURL = try writeRecord(output.record)
        values["recordPath"] = recordURL.path
        var program: String?
        var returnedPreview: PreviewMesh?
        if name == "lad_mesh_open_reference" {
            let payload = try dictionary(full["payload"])
            let context = try dictionary(payload["context"]), revision = try dictionary(payload["revision"])
            let identity = try text("id", context), revisionID = try text("id", revision)
            let contextBytes = try await encoded(context)
            try Task.checkCancellation()
            try retainContext(identity, data: contextBytes)
            try retain(revisionID, data: json(revision), context: identity, pool: &revisions)
            let branch = "branch-" + UUID().uuidString
            branches[branch] = Branch(contextID: identity, history: [revisionID], index: 0)
            currentBranches[identity] = branch
            values.merge(["contextID": identity, "revisionID": revisionID, "branchID": branch, "units": "mm"]) { _, new in new }
        } else if let contextID {
            values["contextID"] = contextID
            switch name {
            case "lad_mesh_inspect":
                if let payload = full["payload"] as? [String: Any] {
                    let id = try identity(payload, keys: ["id", "evidence_id"])
                    let data = try await encoded(payload)
                    try Task.checkCancellation()
                    try retain(id, data: data, context: contextID, pool: &evidence)
                    values["evidenceID"] = id
                }
            case "lad_mesh_fit":
                for candidate in full["payload"] as? [[String: Any]] ?? [] {
                    try retain(try text("id", candidate), data: json(candidate), context: contextID, pool: &fits)
                }
            case "lad_mesh_try_edit":
                if let payload = full["payload"] as? [String: Any] {
                    let id = try text("id", payload)
                    if let bytes = output.native, let hash = payload["geometry_hash"] as? String {
                        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw LADError.message("The reconstruction native geometry identity is invalid.") }
                        if native[hash] == nil {
                            guard nativeBytes + bytes.count <= maximumBytes else { throw LADError.message("Reconstruction geometry exceeds this task's 256 MB limit.") }
                            native[hash] = bytes; nativeBytes += bytes.count
                        }
                    }
                    try retain(id, data: json(payload), context: contextID, pool: &previews)
                    returnedPreview = output.preview ?? targetID.flatMap { display[$0] }
                    if let returnedPreview { cacheDisplay(returnedPreview, id: id) }
                    if payload["commit_eligible"] as? Bool == true, let script = payload["script"] as? String {
                        program = script
                        values["programPath"] = try workspace.write(Data(script.utf8), path: "mesh/programs/\(id).py").path
                    }
                    values["previewID"] = id
                }
            case "lad_mesh_compare":
                if var payload = full["payload"] as? [String: Any] {
                    let id = (payload["comparison_id"] as? String) ?? (payload["id"] as? String) ?? "comparison-\(UUID().uuidString)"
                    payload["comparison_id"] = id
                    try retain(id, data: json(payload), context: contextID, pool: &comparisons)
                    values["comparisonID"] = id
                }
            case "lad_mesh_export_step":
                if let bytes = output.step {
                    let path = arguments["path"] as? String ?? "mesh/exports/\(UUID().uuidString).step"
                    values["path"] = try workspace.write(bytes, path: path).path
                }
            default: break
            }
        }
        return Output(values: values, program: program, preview: returnedPreview)
    }

    private func transaction(_ name: String, _ arguments: [String: Any]) throws -> Output {
        let context = try text("contextID", arguments)
        guard contexts[context] != nil, let branchID = currentBranches[context], var branch = branches[branchID] else {
            throw LADError.message("This reconstruction branch is unavailable in the current task.")
        }
        var payload: [String: Any]
        var preparedProgramPath: String?
        switch name {
        case "lad_mesh_commit":
            try allowed(arguments, ["contextID", "previewID", "expectedRevisionID"])
            let expected = try text("expectedRevisionID", arguments)
            let previewID = try text("previewID", arguments)
            let preview = try record(previewID, pool: previews, context: context)
            guard branch.history[branch.index] == expected, preview["base_revision"] as? String == expected else {
                throw LADError.message("The preview is stale for this branch. Preview an edit against its current revision.")
            }
            guard preview["commit_eligible"] as? Bool == true else { throw LADError.message("The preview did not pass the intermediate commit gates.") }
            var revision = preview
            for key in ["quick_comparison", "base_revision", "commit_eligible", "state"] { revision.removeValue(forKey: key) }
            revision["parent_revision"] = expected
            let id = "revision-" + SHA256.hash(data: try json(revision)).map { String(format: "%02x", $0) }.joined()
            revision["id"] = id
            if let script = revision["script"] as? String {
                preparedProgramPath = try workspace.write(Data(script.utf8), path: "mesh/programs/\(id).py").path
            }
            try retain(id, data: json(revision), context: context, pool: &revisions)
            branch.history = Array(branch.history.prefix(branch.index + 1)) + [id]; branch.index += 1
            branches[branchID] = branch
            if let preview = display[previewID] { cacheDisplay(preview, id: id) }
            payload = ["revisionID": id, "branchID": branchID, "committed": true,
                       "scope": "private reconstruction branch; design window unchanged"]
        case "lad_mesh_undo", "lad_mesh_redo":
            try allowed(arguments, ["contextID", "expectedRevisionID"])
            if let expected = arguments["expectedRevisionID"] as? String, expected != branch.history[branch.index] {
                throw LADError.message("The reconstruction branch changed before this history request.")
            }
            let next = branch.index + (name == "lad_mesh_undo" ? -1 : 1)
            guard branch.history.indices.contains(next) else { throw LADError.message("No reconstruction revision is available in that history direction.") }
            let nextRecord = try record(branch.history[next], pool: revisions, context: context)
            if let script = nextRecord["script"] as? String {
                preparedProgramPath = try workspace.write(Data(script.utf8), path: "mesh/programs/\(branch.history[next]).py").path
            }
            branch.index = next; branches[branchID] = branch
            payload = ["revisionID": branch.history[next], "branchID": branchID]
        case "lad_mesh_branch":
            try allowed(arguments, ["contextID", "revisionID"])
            let id = try text("revisionID", arguments)
            _ = try resolve(id, context: context, previewsAllowed: false)
            let nextRecord = try record(id, pool: revisions, context: context)
            if let script = nextRecord["script"] as? String {
                preparedProgramPath = try workspace.write(Data(script.utf8), path: "mesh/programs/\(id).py").path
            }
            let newBranch = "branch-" + UUID().uuidString
            var ancestry = [id]
            var cursor = nextRecord
            while let parent = cursor["parent_revision"] as? String {
                guard !ancestry.contains(parent) else { throw LADError.message("The reconstruction history contains a dependency cycle.") }
                cursor = try record(parent, pool: revisions, context: context)
                ancestry.append(parent)
            }
            let history = Array(ancestry.reversed())
            branches[newBranch] = Branch(contextID: context, history: history, index: history.count - 1); currentBranches[context] = newBranch
            payload = ["revisionID": id, "branchID": newBranch]
        default: throw LADError.message("The reconstruction transaction is unavailable.")
        }
        let id = payload["revisionID"] as! String
        let revision = try record(id, pool: revisions, context: context)
        if let preparedProgramPath { payload["programPath"] = preparedProgramPath }
        return Output(values: ["status": "ok", "payload": payload, "contextID": context, "revisionID": id,
                               "diagnostics": [], "provenance": ["context_ref": context, "dependency_revisions": [id]]],
                      program: revision["script"] as? String, preview: display[id])
    }

    private func cacheDisplay(_ preview: PreviewMesh, id: String) {
        display[id] = preview; displayOrder.removeAll { $0 == id }; displayOrder.append(id)
        while displayOrder.count > 8 { display.removeValue(forKey: displayOrder.removeFirst()) }
    }
    private func containsInlineSource(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object["program"] != nil || object["script"] != nil || object.values.contains(where: containsInlineSource)
        }
        return (value as? [Any])?.contains(where: containsInlineSource) ?? false
    }
    private func retainContext(_ id: String, data: Data) throws {
        if contexts[id] == nil { try reserve(data.count); contexts[id] = data }
    }
    private func reserve(_ bytes: Int) throws {
        guard bytes <= maximumBytes - recordBytes else { throw LADError.message("Reconstruction records exceed this task's 256 MB limit.") }
        recordBytes += bytes
    }
    private func retain(_ id: String, data: Data, context: String, pool: inout [String: Record]) throws {
        if pool[id] == nil { try reserve(data.count); pool[id] = Record(contextID: context, data: data) }
    }
    private func resolve(_ id: String, context: String, previewsAllowed: Bool) throws -> Record {
        guard let value = revisions[id] ?? (previewsAllowed ? previews[id] : nil), value.contextID == context else {
            throw LADError.message("This exact reconstruction revision is unavailable in the requested context.")
        }
        return value
    }
    private func record(_ id: String, pool: [String: Record], context: String) throws -> [String: Any] {
        guard let value = pool[id], value.contextID == context else { throw LADError.message("A reconstruction handle is stale, unknown or belongs to another context.") }
        return try object(value.data)
    }
    private func referencedRecords(_ object: Any, pool: [String: Record], context: String) throws -> [[String: Any]] {
        var ids = Set<String>()
        func walk(_ value: Any) {
            if let id = value as? String, pool[id] != nil { ids.insert(id) }
            else if let values = value as? [Any] { values.forEach(walk) }
            else if let values = value as? [String: Any] { values.values.forEach(walk) }
        }
        walk(object)
        return try ids.sorted().map { try record($0, pool: pool, context: context) }
    }
    private func stageJSON(_ argument: String, _ arguments: [String: Any], as name: String, key: String,
                           required: Bool = false, assets: inout [String: Data], request: inout [String: Any], array: Bool = false) throws {
        guard let supplied = arguments[argument] else {
            if required { throw LADError.message("Supply a workspace JSON file through \(argument).") }; return
        }
        guard let path = supplied as? String else { throw LADError.message("Use a workspace JSON file path.") }
        let bytes = try workspace.read(path, maximumBytes: 2_000_000)
        let value = try JSONSerialization.jsonObject(with: bytes)
        guard array ? value is [Any] : value is [String: Any] else { throw LADError.message("The reconstruction JSON file has an invalid root value.") }
        assets[name] = bytes; request[key] = name
    }
    private func writeRecord(_ data: Data) throws -> URL {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if !files.contains(hash) {
            guard data.count <= maximumBytes - fileBytes else { throw LADError.message("Reconstruction files exceed this task's 256 MB limit.") }
            files.insert(hash); fileBytes += data.count
        }
        return try workspace.write(data, path: "mesh/records/\(hash).json")
    }
    private func identity(_ values: [String: Any], keys: [String]) throws -> String {
        for key in keys { if let id = values[key] as? String, !id.isEmpty { return id } }
        throw LADError.message("The reconstruction result has no stable identity.")
    }
    private func text(_ key: String, _ values: [String: Any]) throws -> String {
        guard let value = values[key] as? String, !value.isEmpty, value.utf8.count <= 8192,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw LADError.message("Supply a valid reconstruction argument for \(key).") }
        return value
    }
    private func strings(_ key: String, _ values: [String: Any]) throws -> [String] {
        guard let result = values[key] as? [String], (1...32).contains(result.count), Set(result).count == result.count else { throw LADError.message("Supply between 1 and 32 distinct reconstruction evidence handles.") }
        return result
    }
    private func allowed(_ values: [String: Any], _ keys: Set<String>) throws {
        guard Set(values.keys).isSubset(of: keys) else { throw LADError.message("The reconstruction command contains unsupported arguments.") }
    }
    private func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw LADError.message("The reconstruction returned an invalid record.") }; return result
    }
    private func object(_ data: Data) throws -> [String: Any] { try dictionary(JSONSerialization.jsonObject(with: data)) }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func encoded(_ value: Any) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }.value
    }
}
