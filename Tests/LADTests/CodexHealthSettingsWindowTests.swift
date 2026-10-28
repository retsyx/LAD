import AppKit
import XCTest
@testable import LAD

final class CodexHealthSettingsWindowTests: XCTestCase {
    @MainActor
    func testHiddenSettingsChecksWhenOpenedAndChecksAgainAfterNativeCloseAndReopen() async throws {
        try requireWindowServer()
        try await requireNativeKeyActivation()
        let window = makeWindow(title: "LAD Settings health lifecycle test")
        let monitor = CodexSettingsWindowMonitor()
        let probe = Probe()
        monitor.configure(executable: "/test/codex") { executable, force in
            await probe.check(executable: executable, force: force)
        }
        monitor.attach(to: window)
        defer { monitor.disconnect(); window.close() }

        try await settle()
        XCTAssertTrue(probe.requests.isEmpty, "Attaching retained hidden Settings content must not run a check.")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { window.isKeyWindow && !probe.requests.isEmpty }
        XCTAssertEqual(probe.requests.first?.executable, "/test/codex")
        XCTAssertFalse(probe.requests.first?.force ?? true)
        try await settle()

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        let checksBeforeReopen = probe.requests.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try await settle()
        XCTAssertEqual(probe.requests.count, checksBeforeReopen,
                       "Closing the retained native window must gate app activation checks.")

        window.makeKeyAndOrderFront(nil)
        try await waitUntil { window.isKeyWindow && probe.requests.count > checksBeforeReopen }
        XCTAssertTrue(window.isVisible, "Reopening the same native Settings window must resume status checks.")
    }

    @MainActor
    func testOtherWindowKeyAndAppActivationDoNotCheckHiddenSettings() async throws {
        try requireWindowServer()
        try await requireNativeKeyActivation()
        let settings = makeWindow(title: "Hidden LAD Settings health test")
        let other = makeWindow(title: "Unrelated LAD Project health test")
        let monitor = CodexSettingsWindowMonitor()
        let probe = Probe()
        monitor.configure(executable: "/test/codex") { executable, force in
            await probe.check(executable: executable, force: force)
        }
        monitor.attach(to: settings)
        defer { monitor.disconnect(); settings.close(); other.close() }

        NSApplication.shared.activate(ignoringOtherApps: true)
        other.makeKeyAndOrderFront(nil)
        try await waitUntil { other.isKeyWindow }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try await settle()
        XCTAssertFalse(settings.isVisible)
        XCTAssertTrue(probe.requests.isEmpty,
                      "Another window becoming key or activating LAD must not check hidden Settings.")
    }

    @MainActor
    func testWindowNotificationContractChecksVisibleReopenAndIgnoresHiddenUnrelatedEvents() async throws {
        try requireWindowServer()
        let settings = makeWindow(title: "LAD Settings notification contract test")
        let other = makeWindow(title: "Unrelated LAD Project notification test")
        let monitor = CodexSettingsWindowMonitor()
        let probe = Probe()
        monitor.configure(executable: "/test/codex") { executable, force in
            await probe.check(executable: executable, force: force)
        }
        monitor.attach(to: settings)
        defer { monitor.disconnect(); settings.close(); other.close() }

        // These notifications are deliberately injected. The separate tests
        // above verify real WindowServer activation when the host supports it.
        other.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try await settle()
        XCTAssertTrue(probe.requests.isEmpty, "Hidden Settings must ignore application and unrelated-window events.")

        settings.orderFront(nil)
        XCTAssertTrue(settings.isVisible)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        try await waitUntil { !probe.requests.isEmpty }
        XCTAssertEqual(probe.requests.first?.executable, "/test/codex")
        try await settle()

        settings.performClose(nil)
        XCTAssertFalse(settings.isVisible)
        let checksBeforeReopen = probe.requests.count
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try await settle()
        XCTAssertEqual(probe.requests.count, checksBeforeReopen)

        settings.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        try await waitUntil { probe.requests.count > checksBeforeReopen }
        XCTAssertTrue(settings.isVisible)
    }

    @MainActor
    func testClosingSettingsCancelsItsPendingCheckWithoutPublishingCompletion() async throws {
        try requireWindowServer()
        let settings = makeWindow(title: "Closing LAD Settings health test")
        let other = makeWindow(title: "Independent LAD Settings health test")
        let monitor = CodexSettingsWindowMonitor(), otherMonitor = CodexSettingsWindowMonitor()
        let probe = Probe(suspends: true), otherProbe = Probe(suspends: true)
        monitor.configure(executable: "/test/codex") { executable, force in
            await probe.check(executable: executable, force: force)
        }
        otherMonitor.configure(executable: "/test/other-codex") { executable, force in
            await otherProbe.check(executable: executable, force: force)
        }
        defer { monitor.disconnect(); otherMonitor.disconnect(); settings.close(); other.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settings.makeKeyAndOrderFront(nil)
        other.makeKeyAndOrderFront(nil)
        monitor.attach(to: settings)
        otherMonitor.attach(to: other)
        try await waitUntil { probe.pending == 1 && otherProbe.pending == 1 }

        settings.performClose(nil)
        try await waitUntil { probe.cancelled == 1 && probe.pending == 0 }
        XCTAssertTrue(probe.messages.isEmpty, "A closed window's cancelled check must not publish a result.")
        XCTAssertEqual(otherProbe.pending, 1, "Closing one Settings owner must not cancel another owner's check.")
        XCTAssertEqual(otherProbe.cancelled, 0)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        try await settle()
        XCTAssertEqual(probe.requests.count, 1)
    }

    @MainActor
    func testDetachingSettingsCancelsItsCheckAndRemovesLifecycleObservation() async throws {
        try requireWindowServer()
        let window = makeWindow(title: "Detached LAD Settings health test")
        let monitor = CodexSettingsWindowMonitor()
        let probe = Probe(suspends: true)
        monitor.configure(executable: "/test/codex") { executable, force in
            await probe.check(executable: executable, force: force)
        }
        defer { monitor.disconnect(); window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor.attach(to: window)
        try await waitUntil { probe.pending == 1 }

        monitor.attach(to: nil)
        try await waitUntil { probe.cancelled == 1 && probe.pending == 0 }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        monitor.refresh(force: true)
        try await settle()
        XCTAssertEqual(probe.requests.count, 1, "Detached Settings content must stop observing its former window.")
        XCTAssertTrue(probe.messages.isEmpty)
    }

    @MainActor
    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        return window
    }

    @MainActor
    private func requireWindowServer() throws {
        let application = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("A window server is required for native Settings lifecycle checks.")
        }
        // XCTest starts without LAD's application delegate, which normally
        // opts into regular activation. A prohibited test application can show
        // windows but never make them key, bypassing the lifecycle under test.
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        addTeardownBlock {
            await MainActor.run { _ = application.setActivationPolicy(previousPolicy) }
        }
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @MainActor
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Expected the native Settings lifecycle transition to finish (application active: \(NSApplication.shared.isActive), activation policy: \(NSApplication.shared.activationPolicy().rawValue)).", file: file, line: line)
    }

    @MainActor
    private func requireNativeKeyActivation() async throws {
        let window = makeWindow(title: "LAD native activation capability probe")
        defer { window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(1)
        while !window.isKeyWindow, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard window.isKeyWindow else {
            throw XCTSkip("This XCTest host can show windows but cannot activate a plain native window. Real key-event checks require live LAD verification; notification contract and close/detach checks run separately.")
        }
    }

    @MainActor
    private final class Probe {
        struct Request { let executable: String; let force: Bool }
        private let suspends: Bool
        var requests: [Request] = []
        var pending = 0
        var cancelled = 0
        var messages: [String] = []

        init(suspends: Bool = false) { self.suspends = suspends }

        func check(executable: String, force: Bool) async {
            requests.append(Request(executable: executable, force: force))
            pending += 1
            defer { pending -= 1 }
            do {
                if suspends { try await Task.sleep(for: .seconds(30)) }
                try Task.checkCancellation()
                messages.append("Check completed")
            } catch is CancellationError {
                cancelled += 1
            } catch {
                XCTFail("Unexpected injected health-check error: \(error)")
            }
        }
    }
}
