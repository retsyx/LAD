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
        XCTAssertEqual(images.images[key]?.data, red)

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
        XCTAssertEqual(images.images[key]?.data, blue)
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
    func testLargeImageViewPreviewsFitThePaneAndDecodeOnlyABoundedBitmap() async throws {
        try requireWindowServer()
        for (width, height, orientation) in [(6_000, 2_000, 1), (3_000, 2_000, 6)] {
            let original = try jpeg(width: width, height: height, orientation: orientation)
            let decoded = try XCTUnwrap(ProjectActivityImageDecoder.preview(original))
            XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 2_048,
                                     "A preview must not decode the original full-resolution bitmap.")
            let expectedRatio = orientation == 6 ? Double(height) / Double(width) : Double(width) / Double(height)
            XCTAssertEqual(Double(decoded.width) / Double(decoded.height), expectedRatio, accuracy: 0.002)
            let images = ProjectActivityImages()
            let taskID = UUID()
            let event = ProjectActivityEvent(id: "project:server:thread:view", category: "tool", title: "imageView",
                status: "completed", output: "{\"type\":\"imageView\",\"id\":\"view\",\"path\":\"/removed/large.jpg\"}")
            let key = ProjectActivityImageKey(taskID: taskID, eventID: event.id)
            images.store(original, for: key)
            let hosted = fixture(ProjectActivityEventView(event: event, taskID: taskID, images: images, initiallyExpanded: true))
            defer { close(hosted) }
            try await waitForColor(.red, in: hosted)
            for paneWidth in [720.0, 480.0, 960.0] {
                hosted.window.setContentSize(NSSize(width: paneWidth, height: 760))
                hosted.host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let frame = try coloredFrame(.red, in: hosted)
                XCTAssertLessThanOrEqual(frame.height, 421)
                XCTAssertGreaterThanOrEqual(frame.minX, 15)
                XCTAssertLessThanOrEqual(frame.maxX, paneWidth - 15)
                XCTAssertEqual(frame.width / frame.height, expectedRatio, accuracy: 0.05)
                XCTAssertEqual(hosted.window.contentLayoutRect.width, paneWidth, accuracy: 1,
                               "Large images must not change the native window's requested size.")
                XCTAssertEqual(hosted.window.contentLayoutRect.height, 760, accuracy: 1)
            }
            XCTAssertEqual(images.images[key]?.data, original, "Only the displayed preview may be downsampled.")
            try XCTUnwrap(try bitmap(hosted).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/lad-tool-activity-image-view-\(orientation).png"))
        }
    }

    @MainActor
    func testDoubleClickOpensTheExactOriginalForImageViewAndRenderResults() async throws {
        try requireWindowServer()
        NSApplication.shared.activate(ignoringOtherApps: true)
        for title in ["imageView", "lad_render"] {
            var opened = [URL]()
            let images = ProjectActivityImages(opener: { opened.append($0); return true })
            defer { images.reset() }
            let original = try jpeg(width: 600, height: 300)
            let taskID = UUID()
            let event = ProjectActivityEvent(id: "project:\(title):original", category: "tool", title: title,
                status: "completed", output: "{\"path\":\"/removed/original.jpg\",\"type\":\"image_path\"}")
            images.store(original, for: ProjectActivityImageKey(taskID: taskID, eventID: event.id))
            let hosted = fixture(ProjectActivityEventView(event: event, taskID: taskID, images: images, initiallyExpanded: true))
            defer { close(hosted) }
            try await waitForColor(.red, in: hosted)
            let frame = try coloredFrame(.red, in: hosted)
            try click(frame, count: 1, in: hosted)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(opened.isEmpty, "A single click must leave the system viewer closed.")
            try click(frame, count: 2, in: hosted)
            let deadline = ContinuousClock.now + .seconds(3)
            while opened.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(opened.count, 1)
            let file = try XCTUnwrap(opened.first)
            XCTAssertTrue(["jpg", "jpeg"].contains(file.pathExtension))
            XCTAssertEqual(try Data(contentsOf: file), original,
                           "The external viewer must receive the original image, independently of its preview.")
        }
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
        host.sizingOptions = []
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
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
    private func normalizedPixels(_ bitmap: NSBitmapImageRep) throws -> (width: Int, height: Int, bytes: [UInt8]) {
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
        return (image.width, image.height, pixels)
    }

    private func matches(_ expected: PixelColor, bytes: [UInt8], offset: Int) -> Bool {
        guard bytes[offset + 3] > 230 else { return false }
        let red = bytes[offset], green = bytes[offset + 1], blue = bytes[offset + 2]
        switch expected {
        // JPEGs and the native wide-gamut display capture can shift the small
        // channels. Identify the fixture by saturated red dominance instead.
        case .red: return red > 200 && Int(red) > Int(green) * 2 && Int(red) > Int(blue) * 2
        case .green: return green > 230 && red < 26 && blue < 26
        case .blue: return blue > 230 && red < 26 && green < 26
        }
    }

    @MainActor
    private func matchingPixels(_ expected: PixelColor, in bitmap: NSBitmapImageRep) throws -> Int {
        let pixels = try normalizedPixels(bitmap)
        var count = 0
        for y in stride(from: 0, to: pixels.height, by: 4) {
            for x in stride(from: 0, to: pixels.width, by: 4) {
                if matches(expected, bytes: pixels.bytes, offset: (y * pixels.width + x) * 4) { count += 1 }
            }
        }
        return count
    }

    @MainActor
    private func coloredFrame(_ expected: PixelColor, in hosted: Hosted) throws -> NSRect {
        let pixels = try normalizedPixels(bitmap(hosted))
        var minX = pixels.width, minY = pixels.height, maxX = 0, maxY = 0
        for y in stride(from: 0, to: pixels.height, by: 2) {
            for x in stride(from: 0, to: pixels.width, by: 2) where
                matches(expected, bytes: pixels.bytes, offset: (y * pixels.width + x) * 4) {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x + 1); maxY = max(maxY, y + 1)
            }
        }
        XCTAssertGreaterThan(maxX, minX)
        XCTAssertGreaterThan(maxY, minY)
        let xScale = hosted.host.bounds.width / CGFloat(pixels.width)
        let yScale = hosted.host.bounds.height / CGFloat(pixels.height)
        return NSRect(x: CGFloat(minX) * xScale,
            y: hosted.host.isFlipped ? CGFloat(minY) * yScale : hosted.host.bounds.maxY - CGFloat(maxY) * yScale,
            width: CGFloat(maxX - minX) * xScale, height: CGFloat(maxY - minY) * yScale)
    }

    @MainActor
    private func click(_ frame: NSRect, count: Int, in hosted: Hosted) throws {
        hosted.window.makeKey()
        let location = hosted.host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.sendEvent(down)
        if let release = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(release)
        }
    }

    private func jpeg(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
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
