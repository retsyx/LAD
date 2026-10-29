import AppKit
import Foundation
import XCTest
@testable import LAD

final class AgentPermissionNativeTests: XCTestCase {
    @MainActor
    func testNativeSheetDisplaysRequestAndReturnsAllowAndDeny() async throws {
        try requireWindowServer()
        let preferences = try NativePermissionTestPreferences()
        defer { preferences.remove() }
        let controller = AgentPermissionController(defaults: preferences.defaults)
        let owner = makeWindow(title: "Permission decision test")
        defer { owner.close() }

        for allowed in [false, true] {
            let operation = "Inspect a supplied analysis helper"
            let reason = "Check the reference dimensions before refining the design"
            let probe = NativePermissionProbe(controller: controller, operation: operation, reason: reason, owner: owner)
            defer { probe.task?.cancel() }
            try await waitUntil { owner.attachedSheet != nil }
            let sheet = try XCTUnwrap(owner.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let requestText = descendants(in: content).compactMap { ($0 as? NSTextView)?.string }.joined(separator: "\n")
            XCTAssertTrue(requestText.contains(operation))
            XCTAssertTrue(requestText.contains(reason))
            XCTAssertEqual(try rememberButton(in: sheet).state, .off)
            XCTAssertNil(NSApplication.shared.modalWindow, "Permission sheets must not start an application modal loop.")
            try button(titled: allowed ? "Allow" : "Deny", in: sheet).performClick(nil)
            try await waitUntil { probe.result != nil }
            let decision = try XCTUnwrap(probe.result).get()
            XCTAssertEqual(decision.allowed, allowed)
            XCTAssertEqual(decision.source, .user)
            XCTAssertNil(decision.rememberedPolicy)
            XCTAssertEqual(controller.policy, .ask)
            try await waitUntil { owner.attachedSheet == nil && !sheet.isVisible }
        }
    }

    @MainActor
    func testNativeRememberChoicePersistsInInjectedPreferences() async throws {
        try requireWindowServer()
        let preferences = try NativePermissionTestPreferences()
        defer { preferences.remove() }
        let originalGlobalPolicy = UserDefaults.standard.string(forKey: AgentPermissionController.preferenceKey)
        let controller = AgentPermissionController(defaults: preferences.defaults)
        let owner = makeWindow(title: "Remember permission test")
        defer { owner.close() }

        for allowed in [false, true] {
            controller.policy = .ask
            let probe = NativePermissionProbe(controller: controller, operation: "Use an optional helper", reason: "Analyze this design", owner: owner)
            defer { probe.task?.cancel() }
            try await waitUntil { owner.attachedSheet != nil }
            let sheet = try XCTUnwrap(owner.attachedSheet)
            let remember = try rememberButton(in: sheet)
            remember.state = .on
            try button(titled: allowed ? "Allow" : "Deny", in: sheet).performClick(nil)
            try await waitUntil { probe.result != nil }
            let decision = try XCTUnwrap(probe.result).get()
            let expected: AgentPermissionPolicy = allowed ? .alwaysAllow : .alwaysDeny
            XCTAssertEqual(decision.allowed, allowed)
            XCTAssertEqual(decision.source, .user)
            XCTAssertEqual(decision.rememberedPolicy, expected)
            XCTAssertEqual(controller.policy, expected)
            XCTAssertEqual(preferences.defaults.string(forKey: AgentPermissionController.preferenceKey), expected.rawValue)
            try await waitUntil { owner.attachedSheet == nil && !sheet.isVisible }
        }
        XCTAssertEqual(UserDefaults.standard.string(forKey: AgentPermissionController.preferenceKey), originalGlobalPolicy)
    }

    @MainActor
    func testTaskCancellationDismissesNativeSheetWithoutRemembering() async throws {
        try requireWindowServer()
        let preferences = try NativePermissionTestPreferences()
        defer { preferences.remove() }
        let controller = AgentPermissionController(defaults: preferences.defaults)
        let owner = makeWindow(title: "Permission cancellation test")
        defer { owner.close() }
        let probe = NativePermissionProbe(controller: controller, operation: "Use a helper", reason: "Analyze a reference", owner: owner)
        defer { probe.task?.cancel() }
        try await waitUntil { owner.attachedSheet != nil }
        let sheet = try XCTUnwrap(owner.attachedSheet)
        try rememberButton(in: sheet).state = .on
        probe.task?.cancel()
        try await waitUntil { probe.result != nil && owner.attachedSheet == nil && !sheet.isVisible }
        assertCancelled(probe)
        XCTAssertEqual(controller.policy, .ask)
        XCTAssertNil(preferences.defaults.string(forKey: AgentPermissionController.preferenceKey))
        XCTAssertNil(NSApplication.shared.modalWindow)
    }

    @MainActor
    func testClosingFallbackPanelPreservesAnExistingOwnerSheetAndGrantsNothing() async throws {
        try requireWindowServer()
        let preferences = try NativePermissionTestPreferences()
        defer { preferences.remove() }
        let controller = AgentPermissionController(defaults: preferences.defaults)
        let owner = makeWindow(title: "Permission fallback owner test")
        let occupied = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
        occupied.title = "Existing test sheet"
        occupied.isReleasedWhenClosed = false
        defer {
            owner.endSheet(occupied)
            occupied.orderOut(nil)
            occupied.close()
            owner.close()
        }
        owner.beginSheet(occupied, completionHandler: nil)
        try await waitUntil { owner.attachedSheet === occupied }
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let probe = NativePermissionProbe(controller: controller, operation: "Use a supplied helper", reason: "Inspect this design", owner: owner)
        defer { probe.task?.cancel() }
        func permissionPanel() -> NSWindow? {
            NSApplication.shared.windows.first {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.title == "Agent Permission" && $0.isVisible
            }
        }
        try await waitUntil { permissionPanel() != nil }
        let panel = try XCTUnwrap(permissionPanel())
        XCTAssertNil(panel.sheetParent)
        XCTAssertTrue(owner.attachedSheet === occupied)
        XCTAssertNil(NSApplication.shared.modalWindow)
        try rememberButton(in: panel).state = .on
        panel.performClose(nil)
        try await waitUntil { probe.result != nil && !panel.isVisible }
        assertCancelled(probe)
        XCTAssertTrue(owner.attachedSheet === occupied, "Dismissing permission must not end another native sheet.")
        XCTAssertEqual(controller.policy, .ask)
        XCTAssertNil(preferences.defaults.string(forKey: AgentPermissionController.preferenceKey))
    }

    @MainActor
    private func requireWindowServer() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required for native permission dialogs.") }
    }

    @MainActor
    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    @MainActor
    private func button(titled title: String, in window: NSWindow) throws -> NSButton {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor
    private func rememberButton(in window: NSWindow) throws -> NSButton {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Remember for all future requests") })
    }

    @MainActor
    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LADError.message("The native permission dialog did not reach its expected state.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func assertCancelled(_ probe: NativePermissionProbe, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = probe.result, case .failure(let error) = result else {
            return XCTFail("Dismissal must cancel the permission request.", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
    }
}

@MainActor
private final class NativePermissionProbe {
    var result: Result<AgentPermissionDecision, Error>?
    var task: Task<Void, Never>?

    init(controller: AgentPermissionController, operation: String, reason: String, owner: NSWindow) {
        task = Task { [weak self] in
            do { self?.result = .success(try await controller.request(operation: operation, reason: reason, window: owner)) }
            catch { self?.result = .failure(error) }
        }
    }
}

private struct NativePermissionTestPreferences {
    let name = "LAD.NativePermissionTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
    func remove() { defaults.removePersistentDomain(forName: name) }
}
