import AppKit
import XCTest
@testable import LAD

final class ProjectQueuedEditorDropTests: XCTestCase {
    @MainActor
    func testScrolledQueueEditorCannotCaptureFilePathsOverTheMainComposer() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 200, width: 400, height: 150))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.documentView = document
        root.addSubview(scroll)
        let queuedEditor = PromptFilePathDropView(frame: document.bounds)
        queuedEditor.writeText = { _ in }
        document.addSubview(queuedEditor)
        defer { queuedEditor.disconnect() }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        let composerPoint = root.convert(NSPoint(x: 50, y: 50), to: nil)
        XCTAssertTrue(queuedEditor.convert(queuedEditor.bounds, to: nil).contains(composerPoint),
                      "The un-clipped queue region deliberately overlaps the composer.")
        XCTAssertNil(PromptFilePathDropView.region(at: composerPoint, in: window),
                     "A clipped queue editor must not steal paths intended for another editor or the window.")
        let composer = PromptFilePathDropView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        composer.writeText = { _ in }
        root.addSubview(composer)
        defer { composer.disconnect() }
        XCTAssertTrue(PromptFilePathDropView.region(at: composerPoint, in: window) === composer)
        let queuePoint = root.convert(NSPoint(x: 50, y: 250), to: nil)
        XCTAssertTrue(PromptFilePathDropView.region(at: queuePoint, in: window) === queuedEditor)
    }
}
