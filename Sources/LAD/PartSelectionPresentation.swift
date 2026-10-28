/// A feature selection involves its owning part without selecting that part's
/// complete geometry. Folders also show partial selection for selected children.
enum PartSelectionPresentation: Equatable {
    case none
    case partial
    case full

    init(solidIndices: Set<Int>, selectedSolids: Set<Int>, featureSelectedSolids: Set<Int>,
         explicitlySelected: Bool) {
        if explicitlySelected || (!solidIndices.isEmpty && solidIndices.isSubset(of: selectedSolids)) {
            self = .full
        } else if !solidIndices.isDisjoint(with: selectedSolids.union(featureSelectedSolids)) {
            self = .partial
        } else {
            self = .none
        }
    }

    var isSelected: Bool { self != .none }
    var isPartial: Bool { self == .partial }
    var isFull: Bool { self == .full }
}
