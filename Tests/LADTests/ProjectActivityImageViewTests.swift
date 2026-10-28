import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import LAD

final class ProjectActivityImageViewTests: XCTestCase {
    @MainActor
    func testExpandedToolResultShowsItsOwnPNGAndUpdatesWithoutAnotherRender() async throws {
        try requireWindowServer()
        let images = ProjectActivityImages()
        let taskID = UUID()
        let event = renderEvent()
        let key = ProjectActivityImageKey(taskID: taskID, eventID: event.id)
        let red = try ImageAttachmentTestImage.png(.red, width: 400, height: 300)
        let blue = try ImageAttachmentTestImage.png(.blue, width: 400, height: 300)
        images.store(red, for: key)

        let collapsed = fixture(ProjectActivityEventView(event: event, taskID: taskID, images: images))
        XCTAssertEqual(try matchingPixels(.red, in: bitmap(collapsed)), 0,
                       "Collapsed tool calls must not display or decode their image result.")
        close(collapsed)

        let expanded = fixture(ProjectActivityEventView(event: event, taskID: taskID, images: images, initiallyExpanded: true))
        defer { close(expanded) }
        try await waitForColor(.red, in: expanded)
        XCTAssertGreaterThan(try matchingPixels(.red, in: bitmap(expanded)), 1_000)
        XCTAssertEqual(images.images[key]?.png, red)

        // The same event string in another task must never replace this row's
        // image. Tool IDs are task-scoped, including repair attempts.
        images.store(blue, for: ProjectActivityImageKey(taskID: UUID(), eventID: event.id))
        XCTAssertGreaterThan(try matchingPixels(.red, in: bitmap(expanded)), 1_000)
        XCTAssertEqual(try matchingPixels(.blue, in: bitmap(expanded)), 0)
        images.store(blue, for: key)
        try await waitForColor(.blue, in: expanded)
        let final = try bitmap(expanded)
        XCTAssertGreaterThan(try matchingPixels(.blue, in: final), 1_000)
        XCTAssertEqual(try matchingPixels(.red, in: final), 0)
        XCTAssertEqual(images.images[key]?.png, blue)
        try XCTUnwrap(final.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/lad-tool-activity-render-result.png"))
    }

    @MainActor
    func testScreenshotResultUsesTheSameExpandedImagePresentation() async throws {
        try requireWindowServer()
        let images = ProjectActivityImages()
        let taskID = UUID()
        let event = ProjectActivityEvent(id: "project:tool:screenshot", category: "tool", title: "lad_screenshot",
            status: "completed", output: "{\"content\":[{\"type\":\"image_path\",\"path\":\"/temporary/view.png\"}]}")
        let png = try ImageAttachmentTestImage.png(.green, width: 320, height: 180)
        images.store(png, for: ProjectActivityImageKey(taskID: taskID, eventID: event.id))
        let hosted = fixture(ProjectActivityEventView(event: event, taskID: taskID, images: images, initiallyExpanded: true))
        defer { close(hosted) }
        try await waitForColor(.green, in: hosted)
        XCTAssertGreaterThan(try matchingPixels(.green, in: bitmap(hosted)), 1_000)
        XCTAssertFalse(ProjectActivityTranscript.text(for: event).contains(png.base64EncodedString()),
                       "Copying tool activity must retain text output without derived media bytes.")
    }

    @MainActor
    func testEmptyWorkspaceAnchorKeepsToolActivityAttachedWithoutTakingInputOrSpace() async throws {
        try requireWindowServer()
        let first = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        weak var captured: NSWindow?
        let host = NSHostingView(rootView: Color.clear.frame(width: 400, height: 300)
            .background(ProjectActivityWindowAnchor { captured = $0 }))
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        first.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while captured !== first, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(captured === first)
        func anchor(in view: NSView) -> ProjectActivityWindowAnchorView? {
            if let anchor = view as? ProjectActivityWindowAnchorView { return anchor }
            return view.subviews.lazy.compactMap { anchor(in: $0) }.first
        }
        let native = try XCTUnwrap(anchor(in: host))
        XCTAssertFalse(native.acceptsFirstResponder)
        XCTAssertNil(native.hitTest(NSPoint(x: native.bounds.midX, y: native.bounds.midY)))
        XCTAssertEqual(host.fittingSize.width, 400, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 300, accuracy: 1)
        first.contentView = nil
        XCTAssertNil(captured)
        second.contentView = host
        XCTAssertTrue(captured === second)
    }

    @MainActor
    func testToolActivityRemainsNonmodalIsolatedAndReleasesContentWhenHidden() throws {
        try requireWindowServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-activity-pane-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory))
        let other = AppState(autosaveStore: ProjectAutosaveStore(rootDirectory: directory.appendingPathComponent("other")))
        let owner = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 720),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let otherOwner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 720),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; otherOwner.isReleasedWhenClosed = false
        let controller = ProjectActivityPanelController(), otherController = ProjectActivityPanelController()
        defer {
            controller.close(); otherController.close(); owner.close(); otherOwner.close()
            state.cancel(); other.cancel()
        }
        controller.toggle(state: state, owner: owner)
        otherController.toggle(state: other, owner: otherOwner)
        let panel = try XCTUnwrap(controller.panel)
        let otherPanel = try XCTUnwrap(otherController.panel)
        XCTAssertFalse(panel === otherPanel)
        XCTAssertNil(panel.parent)
        XCTAssertNil(otherPanel.parent)
        XCTAssertTrue((owner.childWindows ?? []).isEmpty, "Per-design ownership must not attach the independently movable pane as a native child.")
        XCTAssertTrue((otherOwner.childWindows ?? []).isEmpty)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertFalse(panel.styleMask.contains(.utilityWindow), "Keep standard native traffic-light spacing.")
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertNil(NSApplication.shared.modalWindow)
        controller.hide()
        XCTAssertNil(panel.contentView, "Hidden Tool Activity must release decoded screenshots.")
        XCTAssertNil(panel.parent)
        XCTAssertTrue(otherController.isVisible)
        controller.toggle(state: state, owner: owner)
        owner.close()
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.hasPanel)
        XCTAssertTrue(otherController.isVisible)
        XCTAssertTrue(otherController.panel === otherPanel, "Closing one design must preserve the other design's activity window.")
        XCTAssertNotNil(otherPanel.contentView)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.revisions.isEmpty)
        XCTAssertTrue(state.taskAudits.isEmpty, "Showing results must not request more work from the agent.")
    }

    private func renderEvent() -> ProjectActivityEvent {
        ProjectActivityEvent(id: "project:tool:render", category: "tool", title: "lad_render", status: "completed",
            output: "{\"content\":[{\"type\":\"image_path\",\"path\":\"/temporary/render.png\"}]}")
    }

    private struct Hosted {
        var window: NSWindow
        var host: NSHostingView<AnyView>
    }

    @MainActor
    private func fixture<V: View>(_ content: V) -> Hosted {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(VStack { content }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.background).preferredColorScheme(.dark)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return Hosted(window: window, host: host)
    }

    @MainActor
    private func close(_ hosted: Hosted) {
        hosted.window.orderOut(nil); hosted.window.contentView = nil; hosted.window.close()
    }

    @MainActor
    private func bitmap(_ hosted: Hosted) throws -> NSBitmapImageRep {
        hosted.host.layoutSubtreeIfNeeded(); hosted.window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosted.host.bitmapImageRepForCachingDisplay(in: hosted.host.bounds))
        hosted.host.cacheDisplay(in: hosted.host.bounds, to: bitmap)
        return bitmap
    }

    private enum PixelColor { case red, green, blue }

    @MainActor
    private func matchingPixels(_ expected: PixelColor, in bitmap: NSBitmapImageRep) throws -> Int {
        // AppKit's cached display can report a calibrated/HDR color space:
        // colorAt(...).usingColorSpace(.sRGB) then shifts pure blue's green
        // channel. Normalize the captured PNG into explicit sRGB RGBA bytes,
        // the same image representation being checked visually.
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var count = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let offset = (y * image.width + x) * 4
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                guard pixels[offset + 3] > 230 else { continue }
                switch expected {
                case .red: if red > 230 && green < 26 && blue < 26 { count += 1 }
                case .green: if green > 230 && red < 26 && blue < 26 { count += 1 }
                case .blue: if blue > 230 && red < 26 && green < 26 { count += 1 }
                }
            }
        }
        return count
    }

    @MainActor
    private func waitForColor(_ color: PixelColor, in hosted: Hosted) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try matchingPixels(color, in: bitmap(hosted)) > 1_000 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expanded result did not draw its supplied screenshot.")
    }

    @MainActor
    private func requireWindowServer() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A window server is required to verify native tool results.") }
        _ = NSApplication.shared
    }
}
