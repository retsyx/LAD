import Foundation

/// sRGB color and opacity independent of the UI and rendering frameworks.
/// Alpha is the opacity of the part's faces: 1 is opaque, 0 fully transparent.
struct PartColor: Sendable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// The same hue at full opacity.
    var opaque: PartColor { PartColor(red: red, green: green, blue: blue) }

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

/// Opaque colors keep their three-component encoding; alpha is written only
/// when a part is partially transparent.
extension PartColor: Codable {
    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        red = try values.decode(Double.self, forKey: .red)
        green = try values.decode(Double.self, forKey: .green)
        blue = try values.decode(Double.self, forKey: .blue)
        alpha = try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(red, forKey: .red)
        try values.encode(green, forKey: .green)
        try values.encode(blue, forKey: .blue)
        if alpha != 1 { try values.encode(alpha, forKey: .alpha) }
    }
}
