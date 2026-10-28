import Foundation

/// Opaque sRGB color independent of the UI and rendering frameworks.
struct PartColor: Codable, Sendable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    static let maximumRecentCount = 16

    /// Muted, distinct finishes that remain legible against the dark viewport.
    static let curated: [PartColor] = [
        rgb(0xD4DAE2), rgb(0x98A7BA), rgb(0x65758A),
        rgb(0xE8DFC8), rgb(0xC9AA78), rgb(0xD6AD55),
        rgb(0xE29086), rgb(0xC67B62), rgb(0xB86C87),
        rgb(0xA8AD61), rgb(0x86B58A), rgb(0x59A67C),
        rgb(0x4CA89E), rgb(0x65AAC2), rgb(0x718FCA),
        rgb(0xA08BC7), rgb(0xBD91C4), rgb(0xC6ACBA)
    ]

    private static func rgb(_ value: UInt32) -> PartColor {
        PartColor(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
