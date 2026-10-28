import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])

// Match WorkspaceView's header exactly: the same symbol, light weight, and
// Palette.accent color. Keep one rendered logo for every Finder icon variant.
let gold = NSColor(srgbRed: 0.96, green: 0.70, blue: 0.36, alpha: 1)
guard let symbol = NSImage(systemSymbolName: "cube.transparent.fill", accessibilityDescription: "LAD")?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 25, weight: .light)) else {
    fatalError("Could not load the LAD logo symbol")
}
let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let logo = NSImage(size: canvas.size)
logo.lockFocus()
let scale = 880 / max(symbol.size.width, symbol.size.height)
let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
symbol.draw(in: NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2,
                       width: size.width, height: size.height))
gold.setFill()
canvas.fill(using: .sourceIn)
logo.unlockFocus()

func writeIcon(named name: String, draw: () -> Void) throws {
    let iconset = root.appendingPathComponent("\(name).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let image = NSImage(size: canvas.size)
    image.lockFocus()
    draw()
    image.unlockFocus()
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let suffix = scale == 2 ? "@2x" : ""
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("\(name).icns").path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(1) }
}

try writeIcon(named: "LAD") { logo.draw(in: canvas) }
// Document icons use the same artwork as the application, with no alternate mark.
try Data(contentsOf: root.appendingPathComponent("LAD.icns"))
    .write(to: root.appendingPathComponent("LADDocument.icns"))

guard let folder = NSImage(named: NSImage.folderName) else { fatalError("Could not load the system folder icon") }
try writeIcon(named: "LADFolder") {
    folder.draw(in: canvas)
    logo.draw(in: NSRect(x: 252, y: 156, width: 520, height: 520))
}
