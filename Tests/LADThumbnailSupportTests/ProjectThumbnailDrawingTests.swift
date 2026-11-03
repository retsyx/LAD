import CoreGraphics
import XCTest
@testable import LADThumbnailSupport

final class ProjectThumbnailDrawingTests: XCTestCase {
    func testOpaqueImageCoversTheWholeBitmapAtBothBackingScales() throws {
        let source = try bitmap(width: 32, height: 32)
        source.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(source.makeImage())
        for points in [32, 128, 512] {
            for scale in [1, 2] {
                for transformed in [false, true] {
                    let pixels = points * scale
                    let output = try bitmap(width: pixels, height: pixels)
                    if transformed { output.scaleBy(x: CGFloat(scale), y: CGFloat(scale)) }
                    XCTAssertTrue(ProjectThumbnailDrawing.draw(image, in: output))
                    for (x, y) in [(1, 1), (pixels - 2, 1), (1, pixels - 2), (pixels - 2, pixels - 2),
                                   (pixels / 2, pixels / 2)] {
                        XCTAssertEqual(try alpha(output, x: x, y: y), 255,
                            "Unpainted thumbnail at \(points) points, scale \(scale), transformed \(transformed), pixel (\(x),\(y)).")
                    }
                }
            }
        }
    }

    func testNonSquareImageRemainsCenteredWithoutStretchingAtRetinaScale() throws {
        let source = try bitmap(width: 40, height: 20)
        source.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let output = try bitmap(width: 200, height: 200)
        let image = try XCTUnwrap(source.makeImage())
        XCTAssertTrue(ProjectThumbnailDrawing.draw(image, in: output))
        XCTAssertEqual(try alpha(output, x: 100, y: 25), 0)
        XCTAssertEqual(try alpha(output, x: 100, y: 175), 0)
        XCTAssertEqual(try alpha(output, x: 1, y: 100), 255)
        XCTAssertEqual(try alpha(output, x: 198, y: 100), 255)
        XCTAssertEqual(try alpha(output, x: 100, y: 51), 255)
        XCTAssertEqual(try alpha(output, x: 100, y: 148), 255)
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func alpha(_ context: CGContext, x: Int, y: Int) throws -> UInt8 {
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return bytes[y * context.bytesPerRow + x * 4 + 3]
    }
}
