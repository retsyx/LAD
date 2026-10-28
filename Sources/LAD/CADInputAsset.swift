import Foundation

/// Required pre-existing reference geometry, including faithful source-format
/// conversions such as a user-provided KiCad PCB exported as STEP.
/// These are recipe inputs, never LAD's regenerable preview or native caches.
struct CADInputAsset: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var format: String
    var data: Data

    static let supportedFormats: Set<String> = ["step", "stp", "brep", "stl", "obj"]
}
