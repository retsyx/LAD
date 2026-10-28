import AppKit
import SwiftUI
import XCTest
@testable import LAD

final class CopyButtonLazyTests: XCTestCase {
    @MainActor
    func testLayoutAndWindowMovesDoNotFormatTextAndCopyWritesTheCurrentCompleteValue() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to verify native copy actions.") }
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        var evaluations = 0
        var currentText = "Initial transcript"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = CopyButton(label: "Copy lazy transcript") {
            evaluations += 1
            return currentText
        }
        let host = NSHostingView(rootView: button.padding(30))
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        for step in 0..<8 {
            window.setFrameOrigin(NSPoint(x: 100 + step * 4, y: 100 + step * 3))
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(evaluations, 0, "Native layout and movement must not assemble activity transcripts.")

        currentText = String(repeating: "Current complete CAD tool output λ\n", count: 5_000) + "final line"
        XCTAssertTrue(button.writeText(to: pasteboard))
        XCTAssertEqual(evaluations, 1, "One explicit copy must evaluate the provider exactly once.")
        XCTAssertEqual(pasteboard.string(forType: .string), currentText, "Copy must preserve the complete latest transcript.")
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(evaluations, 1, "Subsequent layout must not reformat the transcript.")
        currentText = "Updated after the first copy"
        XCTAssertTrue(button.writeText(to: pasteboard))
        XCTAssertEqual(evaluations, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), currentText, "Each explicit copy must read the current value.")
    }
}
