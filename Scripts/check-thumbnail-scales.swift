import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing

// Opt-in native-service integration check. Build/register LAD first, then run:
// xcrun swift Scripts/check-thumbnail-scales.swift [OUTPUT_DIRECTORY]
// Every request uses a fresh minimal package, so an old cached image cannot
// hide a drawing bug. No existing designs or preferences are modified.
#if !arch(arm64)
fatalError("LAD requires Apple Silicon (arm64).")
#endif

func failure(_ message: String) -> NSError {
    NSError(domain: "LAD.ThumbnailScaleCheck", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

func fixturePNG() throws -> Data {
    let size = 512
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw failure("Could not create the fixture bitmap.")
    }
    let quadrants: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: 0, width: 256, height: 256), CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)),
        (CGRect(x: 256, y: 0, width: 256, height: 256), CGColor(red: 0.1, green: 0.8, blue: 0.1, alpha: 1)),
        (CGRect(x: 0, y: 256, width: 256, height: 256), CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)),
        (CGRect(x: 256, y: 256, width: 256, height: 256), CGColor(red: 0.9, green: 0.8, blue: 0.1, alpha: 1))
    ]
    for (rect, color) in quadrants { context.setFillColor(color); context.fill(rect) }
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw failure("Could not encode the fixture PNG.")
    }
    return png
}

func fixturePackage(in output: URL, name: String, png: Data) throws -> URL {
    let package = output.appendingPathComponent(name + "-" + UUID().uuidString + ".lad", isDirectory: true)
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    let path = "assets/sha256/\(hash.prefix(2))/\(hash)"
    let image = package.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: image, options: .atomic)
    let root: [String: Any] = ["formatVersion": 5, "projectID": UUID().uuidString,
                               "thumbnail": ["path": path, "sha256": hash]]
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        .write(to: package.appendingPathComponent("project.json"), options: .atomic)
    return package
}

final class RequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CGImage, Error>?

    func finish(_ value: Result<CGImage, Error>) {
        lock.lock(); defer { lock.unlock() }
        result = value
    }

    func value() -> Result<CGImage, Error>? {
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

func thumbnail(package: URL, size: Int, scale: Int) throws -> CGImage {
    let request = QLThumbnailGenerator.Request(fileAt: package,
        size: CGSize(width: size, height: size), scale: CGFloat(scale), representationTypes: .thumbnail)
    request.iconMode = false
    let result = RequestResult()
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
        if let error { result.finish(.failure(error)); return }
        guard let representation, representation.type == .thumbnail else {
            result.finish(.failure(failure("Quick Look returned no content thumbnail (icon fallback is not accepted).")))
            return
        }
        result.finish(.success(representation.cgImage))
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let value = result.value() { return try value.get() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    QLThumbnailGenerator.shared.cancel(request)
    throw failure("The native Quick Look request timed out.")
}

struct CaseReport: Codable {
    var logicalSize: Int
    var scale: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var cornerColors: [String]?
    var minimumCornerAlpha: Double?
    var imagePath: String?
    var error: String?
}

func inspect(_ image: CGImage, size: Int, scale: Int, output: URL) throws -> CaseReport {
    let bitmap = NSBitmapImageRep(cgImage: image)
    var report = CaseReport(logicalSize: size, scale: scale, pixelWidth: image.width,
                            pixelHeight: image.height)
    let name = "size-\(size)-scale-\(scale).png"
    let imageURL = output.appendingPathComponent(name)
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: imageURL, options: .atomic)
        report.imagePath = imageURL.path
    }
    var colors = [String](), minimumAlpha = 1.0
    for y in [image.height / 8, image.height * 7 / 8] {
        for x in [image.width / 8, image.width * 7 / 8] {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                throw failure("Could not sample the returned thumbnail.")
            }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            minimumAlpha = min(minimumAlpha, Double(color.alphaComponent))
            if r > 0.5 && g < 0.4 && b < 0.4 { colors.append("red") }
            else if g > 0.5 && r < 0.4 && b < 0.4 { colors.append("green") }
            else if b > 0.5 && r < 0.4 && g < 0.4 { colors.append("blue") }
            else if r > 0.5 && g > 0.5 && b < 0.4 { colors.append("yellow") }
            else { colors.append("unexpected") }
        }
    }
    report.cornerColors = colors
    report.minimumCornerAlpha = minimumAlpha
    var problems = [String]()
    if image.width != size * scale || image.height != size * scale {
        problems.append("Expected \(size * scale)×\(size * scale) pixels, got \(image.width)×\(image.height).")
    }
    if Set(colors) != ["red", "green", "blue", "yellow"] || minimumAlpha < 0.98 {
        problems.append("The source image did not cover the complete thumbnail canvas: corners \(colors), minimum alpha \(minimumAlpha).")
    }
    report.error = problems.isEmpty ? nil : problems.joined(separator: " ")
    return report
}

do {
    guard CommandLine.arguments.count <= 2 else { throw failure("Usage: check-thumbnail-scales.swift [OUTPUT_DIRECTORY]") }
    let output = CommandLine.arguments.count == 2
        ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        : FileManager.default.temporaryDirectory.appendingPathComponent("LAD-thumbnail-scales-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let png = try fixturePNG()
    try png.write(to: output.appendingPathComponent("source.png"), options: .atomic)
    var cases = [CaseReport]()
    for size in [128, 256, 512] {
        for scale in [1, 2] {
            var report = CaseReport(logicalSize: size, scale: scale)
            do {
                let package = try fixturePackage(in: output, name: "size-\(size)-scale-\(scale)", png: png)
                let image = try thumbnail(package: package, size: size, scale: scale)
                report = try inspect(image, size: size, scale: scale, output: output)
            } catch { report.error = error.localizedDescription }
            cases.append(report)
            print("\(size)pt @\(scale)x: \(report.error ?? "PASS")")
            fflush(stdout)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let reportURL = output.appendingPathComponent("report.json")
    try encoder.encode(cases).write(to: reportURL, options: .atomic)
    print("Report: \(reportURL.path)")
    exit(cases.allSatisfy { $0.error == nil } ? 0 : 1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
