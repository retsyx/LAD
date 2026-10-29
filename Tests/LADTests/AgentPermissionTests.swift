import AppKit
import Foundation
import XCTest
@testable import LAD

@MainActor
final class AgentPermissionTests: XCTestCase {
    func testDefaultAndInvalidStoredPolicyAskAndSettingsPersistAcrossControllers() throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.controller.policy, .ask)
        fixture.controller.policy = .alwaysDeny
        XCTAssertEqual(fixture.defaults.string(forKey: AgentPermissionController.preferenceKey), "alwaysDeny")
        XCTAssertEqual(AgentPermissionController(defaults: fixture.defaults, presenter: fixture.presenter).policy, .alwaysDeny)
        fixture.defaults.set("unknown", forKey: AgentPermissionController.preferenceKey)
        XCTAssertEqual(AgentPermissionController(defaults: fixture.defaults, presenter: fixture.presenter).policy, .ask)
    }

    func testAlwaysPoliciesReturnWithoutPresenting() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        for policy in [AgentPermissionPolicy.alwaysAllow, .alwaysDeny] {
            fixture.controller.policy = policy
            let decision = try await fixture.controller.request(operation: "Example operation", reason: "Needed for the request", window: nil)
            XCTAssertEqual(decision, AgentPermissionDecision(allowed: policy == .alwaysAllow, source: .policy, rememberedPolicy: policy))
        }
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
    }

    func testFourUserChoicesHaveCorrectScopeAndPersistence() async throws {
        for allowed in [false, true] {
            for remember in [false, true] {
                let fixture = PermissionFixture()
                defer { fixture.cleanUp() }
                let task = Task { try await fixture.controller.request(operation: "Example operation", reason: "Needed for the request", window: nil) }
                defer { task.cancel() }
                try await waitUntil { fixture.presenter.prompts.count == 1 }
                fixture.presenter.respond(at: 0, .decision(allowed: allowed, remember: remember))
                let decision = try await task.value
                let remembered: AgentPermissionPolicy? = remember ? (allowed ? .alwaysAllow : .alwaysDeny) : nil
                XCTAssertEqual(decision, AgentPermissionDecision(allowed: allowed, source: .user, rememberedPolicy: remembered))
                XCTAssertEqual(fixture.controller.policy, remembered ?? .ask)
                let reopened = AgentPermissionController(defaults: fixture.defaults, presenter: fixture.presenter)
                XCTAssertEqual(reopened.policy, remembered ?? .ask)
                XCTAssertEqual(fixture.presenter.dismissed, [0])
            }
        }
    }

    func testRequestsArePresentedOneAtATimeInSubmissionOrder() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let first = Task { try await fixture.controller.request(operation: "First", reason: "First reason", window: nil) }
        defer { first.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        let second = Task { try await fixture.controller.request(operation: "Second", reason: "Second reason", window: nil) }
        defer { second.cancel() }
        await Task.yield()
        XCTAssertEqual(fixture.presenter.prompts.map(\.operation), ["First"])
        fixture.presenter.respond(at: 0, .decision(allowed: true, remember: false))
        try await waitUntil { fixture.presenter.prompts.count == 2 }
        XCTAssertEqual(fixture.presenter.prompts.map(\.operation), ["First", "Second"])
        fixture.presenter.respond(at: 1, .decision(allowed: false, remember: false))
        let decisions = try await [first.value, second.value]
        XCTAssertEqual(decisions.map(\.allowed), [true, false])
        XCTAssertEqual(fixture.presenter.maximumActive, 1)
    }

    func testPolicyChangesResolveEveryPendingRequestAndIgnoreOldRememberCallback() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let first = Task { try await fixture.controller.request(operation: "First", reason: "First reason", window: nil) }
        defer { first.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        let second = Task { try await fixture.controller.request(operation: "Second", reason: "Second reason", window: nil) }
        defer { second.cancel() }
        await Task.yield()
        fixture.controller.policy = .alwaysDeny
        let decisions = try await [first.value, second.value]
        XCTAssertEqual(decisions, Array(repeating: AgentPermissionDecision(allowed: false, source: .policy, rememberedPolicy: .alwaysDeny), count: 2))
        XCTAssertEqual(fixture.presenter.prompts.count, 1)
        fixture.presenter.respond(at: 0, .decision(allowed: true, remember: true))
        XCTAssertEqual(fixture.controller.policy, .alwaysDeny)
        XCTAssertEqual(fixture.defaults.string(forKey: AgentPermissionController.preferenceKey), "alwaysDeny")
    }

    func testCancelActiveRequestAdvancesQueueAndLateResponseCannotGrant() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let first = Task { try await fixture.controller.request(operation: "First", reason: "First reason", window: nil) }
        defer { first.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        let second = Task { try await fixture.controller.request(operation: "Second", reason: "Second reason", window: nil) }
        defer { second.cancel() }
        await Task.yield()
        first.cancel()
        try await assertCancelled(first)
        try await waitUntil { fixture.presenter.prompts.count == 2 }
        fixture.presenter.respond(at: 0, .decision(allowed: true, remember: true))
        XCTAssertEqual(fixture.controller.policy, .ask)
        fixture.presenter.respond(at: 1, .decision(allowed: false, remember: false))
        let decision = try await second.value
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(fixture.presenter.dismissed, [0, 1])
    }

    func testCancelQueuedRequestDoesNotDismissAnotherDesignsPrompt() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let first = Task { try await fixture.controller.request(operation: "First", reason: "First reason", window: nil) }
        defer { first.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        let second = Task { try await fixture.controller.request(operation: "Second", reason: "Second reason", window: nil) }
        await Task.yield()
        second.cancel()
        try await assertCancelled(second)
        XCTAssertTrue(fixture.presenter.dismissed.isEmpty)
        fixture.presenter.respond(at: 0, .decision(allowed: true, remember: false))
        let decision = try await first.value
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(fixture.presenter.prompts.count, 1)
    }

    func testAlreadyCanceledRequestsNeverPresentOrUseAnAlwaysAllowPolicy() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        for policy in [AgentPermissionPolicy.ask, .alwaysAllow, .alwaysDeny] {
            fixture.controller.policy = policy
            let task = Task { try await fixture.controller.request(operation: "Canceled", reason: "Reason", window: nil) }
            task.cancel()
            try await assertCancelled(task)
        }
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
    }

    func testCancellationWinsAgainstAnImmediateSettingsPolicyChange() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let task = Task { try await fixture.controller.request(operation: "Canceled", reason: "Reason", window: nil) }
        defer { task.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        task.cancel()
        fixture.controller.policy = .alwaysAllow
        try await assertCancelled(task)
        XCTAssertEqual(fixture.presenter.dismissed, [0])
        fixture.presenter.respond(at: 0, .decision(allowed: false, remember: true))
        XCTAssertEqual(fixture.controller.policy, .alwaysAllow)
    }

    func testOwnerClosingCancelsOnlyItsRequestsAndDoesNotBorrowAnotherWindow() async throws {
        _ = NSApplication.shared
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { owner.close(); other.close() }
        let first = Task { try await fixture.controller.request(operation: "First", reason: "First reason", window: owner) }
        defer { first.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        XCTAssertTrue(fixture.presenter.prompts[0].window === owner)
        let sameOwner = Task { try await fixture.controller.request(operation: "Same owner", reason: "Queued reason", window: owner) }
        defer { sameOwner.cancel() }
        await Task.yield()
        let second = Task { try await fixture.controller.request(operation: "Second", reason: "Second reason", window: other) }
        defer { second.cancel() }
        await Task.yield()
        owner.close()
        try await assertCancelled(first)
        try await assertCancelled(sameOwner)
        try await waitUntil { fixture.presenter.prompts.count == 2 }
        XCTAssertEqual(fixture.presenter.prompts.map(\.operation), ["First", "Second"])
        XCTAssertTrue(fixture.presenter.prompts[1].window === other)
        fixture.presenter.respond(at: 0, .decision(allowed: true, remember: true))
        XCTAssertEqual(fixture.controller.policy, .ask)
        fixture.presenter.respond(at: 1, .decision(allowed: false, remember: false))
        _ = try await second.value
    }

    func testSynchronousPresentationAndCancellationCannotLeaveAStaleTokenOrPolicy() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        fixture.presenter.onPresent = { _, completion in completion(.decision(allowed: false, remember: false)) }
        for _ in 0..<2 {
            let decision = try await fixture.controller.request(operation: "Immediate", reason: "Immediate reason", window: nil)
            XCTAssertFalse(decision.allowed)
        }
        XCTAssertEqual(fixture.presenter.dismissed, [0, 1])
        var running: Task<AgentPermissionDecision, Error>?
        fixture.presenter.onPresent = { _, completion in
            running?.cancel()
            completion(.decision(allowed: true, remember: true))
        }
        running = Task { try await fixture.controller.request(operation: "Canceled", reason: "Canceled reason", window: nil) }
        defer { running?.cancel(); fixture.presenter.onPresent = nil }
        try await assertCancelled(try XCTUnwrap(running))
        XCTAssertEqual(fixture.controller.policy, .ask)
    }

    func testInvalidRequestsAndDismissalNeverRememberADecision() async throws {
        let fixture = PermissionFixture()
        defer { fixture.cleanUp() }
        for operation in ["", String(repeating: "a", count: 8_193), "invalid\0operation"] {
            do {
                _ = try await fixture.controller.request(operation: operation, reason: "Reason", window: nil)
                XCTFail("An invalid request must not be presented")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
        XCTAssertTrue(fixture.presenter.prompts.isEmpty)
        let request = Task { try await fixture.controller.request(operation: "Example", reason: "Reason", window: nil) }
        defer { request.cancel() }
        try await waitUntil { fixture.presenter.prompts.count == 1 }
        fixture.presenter.respond(at: 0, .cancelled)
        try await assertCancelled(request)
        XCTAssertEqual(fixture.controller.policy, .ask)
        XCTAssertNil(fixture.defaults.string(forKey: AgentPermissionController.preferenceKey))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The permission controller did not reach the expected state")
        throw CancellationError()
    }

    private func assertCancelled(_ task: Task<AgentPermissionDecision, Error>) async throws {
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

@MainActor
private final class PermissionFixture {
    let suite = "LAD-AgentPermissionTests-\(UUID())"
    let defaults: UserDefaults
    let presenter = PermissionTestPresenter()
    let controller: AgentPermissionController

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        controller = AgentPermissionController(defaults: defaults, presenter: presenter)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class PermissionTestPresenter: AgentPermissionPresenting {
    var prompts: [AgentPermissionPrompt] = []
    var completions: [@MainActor (AgentPermissionPromptResponse) -> Void] = []
    var dismissed: [Int] = []
    var maximumActive = 0
    private var active: Set<Int> = []
    var onPresent: (@MainActor (AgentPermissionPrompt, @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> Void)?

    func present(_ prompt: AgentPermissionPrompt,
                 completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> AgentPermissionPresentation {
        let index = prompts.count
        prompts.append(prompt)
        completions.append(completion)
        active.insert(index)
        maximumActive = max(maximumActive, active.count)
        onPresent?(prompt, completion)
        return AgentPermissionPresentation { [weak self] in
            self?.active.remove(index)
            self?.dismissed.append(index)
        }
    }

    func respond(at index: Int, _ response: AgentPermissionPromptResponse) { completions[index](response) }
}
