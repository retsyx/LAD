import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

enum ImageAttachmentTestImage {
    @MainActor
    static func png(_ color: NSColor, width: Int = 32, height: Int = 24) throws -> Data {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func byte(_ component: CGFloat) -> UInt8 { UInt8((min(1, max(0, component)) * 255).rounded()) }
        let rgba = [byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent), byte(rgb.alphaComponent)]
        let bytes = Data(Array(repeating: rgba, count: width * height).flatMap { $0 })
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
