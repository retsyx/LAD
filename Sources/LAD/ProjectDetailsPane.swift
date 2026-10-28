import SwiftUI

struct ProjectDetailsPane: View {
    @ObservedObject var state: AppState
    let project: ModelSpec
    @Binding var isProgramExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DESIGN").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted)
                Spacer()
                ProjectRevisionPicker(state: state)
            }
            if let mesh = state.mesh {
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        if i > 0 { Text("×").foregroundStyle(Palette.muted) }
                        Text(mesh.size[i], format: .number.precision(.fractionLength(0...1)))
                    }
                    Text("mm").foregroundStyle(Palette.muted)
                }.font(.system(size: 11, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
                Rectangle().fill(Palette.line).frame(height: 1)
                detailRow("Solids", "\(mesh.solids)")
                detailRow("Volume", "\(mesh.volume.formatted(.number.precision(.fractionLength(0)))) mm³")
            }
            DisclosureGroup(isExpanded: $isProgramExpanded) {
                EmptyView()
            } label: {
                HStack(spacing: 4) {
                    Text("CadQuery program").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 4)
                    CopyButton(text: project.script, label: "Copy CAD program")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if isProgramExpanded {
                // DisclosureGroup propagates its content's ideal height on
                // macOS. Keep the source viewport as a flexible sibling so
                // the document cannot enlarge its pane or the app window.
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Text(project.script).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityIdentifier("projectProgramScrollView")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
        }.font(.system(size: 10))
    }
}
