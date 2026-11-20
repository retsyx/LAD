import SwiftUI

struct PartMaterialPicker: View {
    let assignment: PartMaterialAssignment
    let designMaterials: [PartMaterial]
    let library: PartMaterialLibrary
    let onApply: (PartMaterial?) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newDensity = ""
    @State private var addError: String?
    @State private var hoveredID: String?
    @State private var revealedID: String?
    @FocusState private var focus: Field?

    private enum Field { case search, name, density }

    private struct Entry: Identifiable {
        enum Origin { case standard, custom, design }
        let material: PartMaterial
        let origin: Origin
        var id: String { "\(origin):\(material.name):\(material.density)" }
    }

    private static let unassignedID = "unassigned"

    private var entries: [Entry] {
        let library = library.materials.map { Entry(material: $0, origin: self.library.isCustom($0) ? .custom : .standard) }
        var seen = Set<PartMaterial>()
        let design = designMaterials.filter { !self.library.contains($0) && seen.insert($0).inserted }
            .map { Entry(material: $0, origin: .design) }
        let all = (library + design).sorted { PartMaterial.alphabetical($0.material, $1.material) }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? all : all.filter { $0.material.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Material").font(.headline)
            searchField
            list
            if isAdding { addForm } else { footer }
        }
        .padding(16)
        .frame(width: 340)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .task {
            await Task.yield()
            if !Task.isCancelled { focus = .search }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
                .onSubmit {
                    let matches = entries
                    if matches.count == 1, let only = matches.first { onApply(only.material) }
                }
                .accessibilityLabel("Search materials")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1) }
    }

    private var list: some View {
        let entries = entries
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        row(id: Self.unassignedID, name: "Unassigned", density: 0, origin: nil,
                            isCurrent: assignment.contains(nil)) { onApply(nil) }
                    }
                    ForEach(entries) { entry in
                        row(id: entry.id, name: entry.material.name, density: entry.material.density, origin: entry.origin,
                            isCurrent: assignment.contains(entry.material)) { onApply(entry.material) }
                    }
                    if entries.isEmpty {
                        Text("No Matching Materials").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .padding(4)
            }
            .frame(height: 264)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1) }
            .onChange(of: revealedID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                // Show the first of the parts' current materials in list order.
                let current = (assignment.includesUnassigned ? [Self.unassignedID] : [])
                    + entries.filter { assignment.contains($0.material) }.map(\.id)
                guard let first = current.first else { return }
                DispatchQueue.main.async { proxy.scrollTo(first, anchor: .center) }
            }
        }
    }

    private func row(id: String, name: String, density: Double, origin: Entry.Origin?, isCurrent: Bool,
                     action: @escaping () -> Void) -> some View {
        let material = PartMaterial(name: name, density: density)
        return HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.accent).opacity(isCurrent ? 1 : 0)
                        .frame(width: 12)
                    Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isCurrent ? Palette.accent : origin == nil ? Palette.muted : Color.white.opacity(0.88))
                    if origin == .design {
                        Text("Design").font(.system(size: 8, weight: .semibold)).tracking(0.4)
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay { Capsule().strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1) }
                            .help("Saved in this design only")
                    }
                    Spacer(minLength: 6)
                    Text(Self.densityLabel(density)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.vertical, 5).padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(Self.densityLabel(density))\(origin == .design ? ", this design only" : "")")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            Group {
                switch origin {
                case .design:
                    let conflict = library.material(named: name)
                    Button { importMaterial(material) } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(conflict != nil)
                        .help(conflict.map { "LAD materials already include ‘\($0.name)’" } ?? "Import into LAD Materials")
                        .accessibilityLabel("Import \(name) into LAD materials")
                case .custom:
                    Button { library.remove(material) } label: { Image(systemName: "minus.circle") }
                        .help("Remove from LAD Materials")
                        .accessibilityLabel("Remove \(name) from LAD materials")
                case .standard, nil:
                    Color.clear
                }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
            .frame(width: 20, height: 20)
        }
        .padding(.trailing, 4)
        .background(Palette.accent.opacity(Self.highlight(current: isCurrent, revealed: revealedID == id, hovered: hoveredID == id)),
                    in: RoundedRectangle(cornerRadius: 4))
        .onHover { inside in
            if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        .id(id)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("New Material…") {
                addError = nil
                newName = query.trimmingCharacters(in: .whitespacesAndNewlines)
                newDensity = ""
                isAdding = true
                focus = newName.isEmpty ? .name : .density
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Name", text: $newName)
                    .focused($focus, equals: .name)
                TextField("Density", text: $newDensity)
                    .focused($focus, equals: .density)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .accessibilityLabel("Density in grams per cubic centimeter")
                Text(PartMaterial.densityUnit).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .textFieldStyle(.roundedBorder)
            if let addError {
                Text(addError).font(.system(size: 10)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { isAdding = false; addError = nil; focus = .search }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addMaterial)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newDensity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .controlSize(.small)
    }

    private func addMaterial() {
        guard let density = Self.density(from: newDensity) else {
            addError = "Enter the density as a number."
            return
        }
        do {
            let material = try library.add(name: newName, density: density)
            isAdding = false
            addError = nil
            query = ""
            reveal(material)
        } catch { addError = error.localizedDescription }
    }

    private func importMaterial(_ material: PartMaterial) {
        guard (try? library.add(name: material.name, density: material.density)) != nil else { return }
        reveal(material)
    }

    private func reveal(_ material: PartMaterial) {
        let id = Entry(material: material, origin: library.isCustom(material) ? .custom : .standard).id
        revealedID = nil
        DispatchQueue.main.async { revealedID = id }
        focus = .search
    }

    /// Current materials keep the parts tree's selection tint; hover adds to it.
    private static func highlight(current: Bool, revealed: Bool, hovered: Bool) -> Double {
        (current || revealed ? 0.14 : 0) + (hovered ? 0.08 : 0)
    }

    static func densityLabel(_ density: Double) -> String {
        density.formatted(.number.precision(.fractionLength(density == 0 ? 0...0 : 2...6))) + " " + PartMaterial.densityUnit
    }

    /// Accept the user's locale and plain decimal notation.
    static func density(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        if let number = formatter.number(from: trimmed) { return number.doubleValue }
        return Double(trimmed)
    }
}
