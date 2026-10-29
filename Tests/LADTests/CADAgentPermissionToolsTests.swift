import AppKit
import SceneKit
import XCTest
@testable import LAD

final class CADAgentPermissionToolsTests: XCTestCase {
    @MainActor
    func testPoliciesReturnDecisionsWithoutRunningTheOperationOrRequiringCAD() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = try fixture.tools()
        let marker = fixture.root.appendingPathComponent("must-not-run")
        let arguments = ["operation": "touch \(marker.path)", "reason": "Check a permission decision"]
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        for (policy, allowed) in [(AgentPermissionPolicy.alwaysDeny, false), (.alwaysAllow, true), (.alwaysDeny, false)] {
            fixture.controller.policy = policy
            let response = try await tools.handle(name: "lad_request_permission", arguments: arguments)
            XCTAssertNil(response["isError"], "Denial is a successful decision, not a tool error.")
            let output = try content(response)
            XCTAssertEqual(output["allowed"] as? Bool, allowed)
            XCTAssertEqual(output["source"] as? String, "policy")
            XCTAssertEqual(output["rememberedPolicy"] as? String, policy.rawValue)
            XCTAssertEqual(output["scope"] as? String, "task_workspace")
            XCTAssertEqual((output["workspace"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, fixture.root.resolvingSymlinksInPath().path)
            XCTAssertEqual(output["executionPerformed"] as? Bool, false)
        }
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
    }

    @MainActor
    func testArgumentsFailBeforeAskingOrChangingPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = try fixture.tools()
        let invalid: [[String: Any]] = [
            [:], ["operation": "Use a helper"], ["reason": "Analyze a reference"],
            ["operation": 1, "reason": "Analyze a reference"],
            ["operation": "   ", "reason": "Analyze a reference"],
            ["operation": "Use a helper", "reason": ""],
            ["operation": "Use\na helper", "reason": "Analyze a reference"],
            ["operation": "Use a helper", "reason": "Reason\u{0}suffix"],
            ["operation": String(repeating: "x", count: 201), "reason": "Analyze a reference"],
            ["operation": "Use a helper", "reason": String(repeating: "x", count: 2_001)],
            ["operation": "Use a helper", "reason": "Analyze a reference", "command": "touch forbidden"]
        ]
        for arguments in invalid {
            do {
                _ = try await tools.handle(name: "lad_request_permission", arguments: arguments)
                XCTFail("Invalid permission arguments were accepted: \(arguments)")
            } catch {
                XCTAssertFalse(error is CancellationError)
                XCTAssertFalse(error.localizedDescription.contains("Python"))
            }
        }
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
        XCTAssertEqual(fixture.controller.policy, .ask)
    }

    @MainActor
    func testOneTimeDecisionReceivesItsDesignWindowAndDoesNotChangeGlobalPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let viewport = CADSceneView(frame: owner.contentView!.bounds, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])
        owner.contentView = viewport
        let tools = try fixture.tools(viewport: viewport)
        let pending = Task { try await tools.handle(name: "lad_request_permission", arguments: [
            "operation": "  Install an optional analysis helper  ", "reason": "  Inspect a supplied reference  "
        ]) }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        XCTAssertTrue(fixture.presenter.prompts[0].window === owner)
        XCTAssertEqual(fixture.presenter.prompts[0].operation, "Install an optional analysis helper")
        XCTAssertEqual(fixture.presenter.prompts[0].reason, "Inspect a supplied reference")
        fixture.presenter.respond(0, .decision(allowed: false, remember: false))
        let output = try content(try await pending.value)
        XCTAssertEqual(output["allowed"] as? Bool, false)
        XCTAssertEqual(output["source"] as? String, "user")
        XCTAssertTrue(output["rememberedPolicy"] is NSNull)
        XCTAssertEqual(fixture.controller.policy, .ask)

        viewport.removeFromSuperview()
        do {
            _ = try await tools.handle(name: "lad_request_permission", arguments: ["operation": "Another operation", "reason": "Its design view is detached"])
            XCTFail("A detached owning view must not fall back to another window or a standalone prompt.")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.presenter.prompts.count, 1)
    }

    @MainActor
    func testToolCancellationAndCallerCancellationDismissPendingRequestsWithoutRememberingLateApproval() async throws {
        for cancelTools in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let tools = try fixture.tools()
            let pending = Task { try await tools.handle(name: "lad_request_permission", arguments: [
                "operation": "Install an optional helper", "reason": "Analyze a reference"
            ]) }
            try await waitUntil { fixture.presenter.prompts.count == 1 }
            if cancelTools { tools.cancel() }
            else { pending.cancel() }
            do {
                _ = try await pending.value
                XCTFail("A canceled permission request must not return a decision.")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(fixture.presenter.dismissed, [0])
            fixture.presenter.respond(0, .decision(allowed: true, remember: true))
            XCTAssertEqual(fixture.controller.policy, .ask)
        }
    }

    private func content(_ response: [String: Any]) throws -> [String: Any] {
        let blocks = try XCTUnwrap(response["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LADError.message("The permission request did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let suite = "LAD.PermissionToolsTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let presenter: PermissionToolsPresenter
        let controller: AgentPermissionController

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-permission-tools-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            presenter = PermissionToolsPresenter()
            controller = AgentPermissionController(defaults: defaults, presenter: presenter)
        }

        func tools(viewport: CADSceneView? = nil) throws -> CADAgentTools {
            try CADAgentTools(directory: root, python: "/unavailable/permission-test-python", threads: 1,
                              current: nil, currentPreview: nil, engine: EngineService(), viewport: viewport,
                              permissionController: controller)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class PermissionToolsPresenter: AgentPermissionPresenting {
    var prompts: [AgentPermissionPrompt] = []
    var completions: [@MainActor (AgentPermissionPromptResponse) -> Void] = []
    var dismissed = Set<Int>()

    func present(_ prompt: AgentPermissionPrompt, completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> AgentPermissionPresentation {
        let index = prompts.count
        prompts.append(prompt)
        completions.append(completion)
        return AgentPermissionPresentation { [weak self] in self?.dismissed.insert(index) }
    }

    func respond(_ index: Int, _ response: AgentPermissionPromptResponse) { completions[index](response) }
}
