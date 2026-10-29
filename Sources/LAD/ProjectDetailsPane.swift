import SwiftUI

struct ProjectDetailsPane: View {
    @ObservedObject var state: AppState
    let project: ModelSpec?
    @Binding var isProgramExpanded: Bool
    @State private var infoHeight: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if project != nil { projectInfo }
                        if let project { programDisclosure(project) }
                        if state.hasMeasurementSelection {
                            MeasurementInfoView(state: state, contentPadding: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ProjectInfoHeight.self, value: content.size.height)
                        }
                    }
                }
                .frame(height: isShowingProgram ? min(infoHeight, max(0, geometry.size.height / 2)) : geometry.size.height)
                .accessibilityIdentifier("projectInfoScrollView")
                .id(state.hasMeasurementSelection)
                if isShowingProgram, let project {
                    // The native pane supplies this bounded rectangle. Code
                    // fills the remaining space outside the information scroll.
                    GeometryReader { program in
                        ScrollView([.horizontal, .vertical]) {
                            Text(project.script).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: program.size.width, height: program.size.height)
                        .accessibilityIdentifier("projectProgramScrollView")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                }
            }
        }
        .onPreferenceChange(ProjectInfoHeight.self) { height in
            if height.isFinite, height > 0, abs(infoHeight - height) > 0.5 { infoHeight = height }
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design and measurements")
    }

    private var isShowingProgram: Bool { project != nil && isProgramExpanded }

    private var projectInfo: some View {
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
        }
    }

    private func programDisclosure(_ project: ModelSpec) -> some View {
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
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
        }.font(.system(size: 10))
    }
}

private struct ProjectInfoHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
