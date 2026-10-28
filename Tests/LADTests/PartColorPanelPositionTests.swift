import AppKit
import XCTest
@testable import LAD

final class PartColorPanelPositionTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1200, height: 900)
    private let panel = NSSize(width: 300, height: 450)

    func testPanelOpensBesideSwatchesOnRightWithAlignedTop() {
        let anchor = NSRect(x: 300, y: 400, width: 300, height: 350)
        let frame = PartColorPanelPosition.frame(for: panel, beside: anchor, in: screen)
        XCTAssertEqual(frame, NSRect(x: 610, y: 300, width: 300, height: 450))
    }

    func testPanelUsesLeftSideWhenRightDoesNotFit() {
        let anchor = NSRect(x: 950, y: 500, width: 250, height: 300)
        let frame = PartColorPanelPosition.frame(for: panel, beside: anchor, in: screen)
        XCTAssertEqual(frame, NSRect(x: 640, y: 350, width: 300, height: 450))
    }

    func testPanelRemainsInVisibleAreaAtTopAndBottom() {
        for y in [-100.0, 850.0] {
            let frame = PartColorPanelPosition.frame(for: panel, beside: NSRect(x: 300, y: y, width: 300, height: 300), in: screen)
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertEqual(frame.minX, 610)
        }
    }

    func testNeitherSideFitsUsesLargerSpaceAndClampsOnOffsetScreen() {
        let screen = NSRect(x: -1000, y: 100, width: 900, height: 700)
        let anchor = NSRect(x: -700, y: 300, width: 400, height: 300)
        let frame = PartColorPanelPosition.frame(for: NSSize(width: 500, height: 450), beside: anchor, in: screen)
        XCTAssertEqual(frame.minX, -992)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testOversizedRememberedPanelFitsWithinScreen() {
        let screen = NSRect(x: 0, y: 0, width: 600, height: 450)
        let frame = PartColorPanelPosition.frame(for: NSSize(width: 900, height: 700),
                                                beside: NSRect(x: 100, y: 100, width: 300, height: 300), in: screen)
        XCTAssertEqual(frame, NSRect(x: 8, y: 8, width: 584, height: 434))
    }
}
