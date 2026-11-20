import Foundation
import Observation

/// LAD's standard materials and the user's custom materials on this Mac.
/// Agent-defined materials stay in their design unless the user imports them.
@MainActor
@Observable
final class PartMaterialLibrary {
    static let shared = PartMaterialLibrary()
    static let preferenceKey = "customPartMaterials"
    static let maximumCustomCount = 1_000

    private(set) var customMaterials: [PartMaterial]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([PartMaterial].self, from: $0) } ?? []
        var names = Set(PartMaterial.standard.map(\.key))
        customMaterials = Array(saved.filter { $0.isValid && names.insert($0.key).inserted }.prefix(Self.maximumCustomCount))
    }

    /// Standard and custom materials, alphabetically.
    var materials: [PartMaterial] { (PartMaterial.standard + customMaterials).sorted(by: PartMaterial.alphabetical) }

    func isCustom(_ material: PartMaterial) -> Bool { customMaterials.contains(material) }
    func contains(_ material: PartMaterial) -> Bool { PartMaterial.standard.contains(material) || isCustom(material) }

    func material(named name: String) -> PartMaterial? {
        let key = PartMaterial.key(name)
        return materials.first { $0.key == key }
    }

    @discardableResult
    func add(name: String, density: Double) throws -> PartMaterial {
        let material = try PartMaterial.validated(name: name, density: density)
        if let existing = self.material(named: material.name) {
            guard existing == material else {
                throw LADError.message("A material named ‘\(existing.name)’ already exists.")
            }
            return existing
        }
        guard customMaterials.count < Self.maximumCustomCount else {
            throw LADError.message("The material library is full. Remove a custom material first.")
        }
        customMaterials.append(material)
        persist()
        return material
    }

    func remove(_ material: PartMaterial) {
        guard let index = customMaterials.firstIndex(of: material) else { return }
        customMaterials.remove(at: index)
        persist()
    }

    private func persist() {
        if customMaterials.isEmpty { defaults.removeObject(forKey: Self.preferenceKey) }
        else if let data = try? JSONEncoder().encode(customMaterials) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}
