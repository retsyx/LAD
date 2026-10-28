import SwiftUI

struct MeasurementInfoView: View {
    @ObservedObject var state: AppState

    private var metrics: [CADMeasurementMetric] { state.measurementReport?.metrics ?? [] }
    private var summaryMetrics: [CADMeasurementMetric] {
        metrics.filter { $0.id.hasPrefix("pair:") || $0.id.hasPrefix("triangle:") || $0.id.hasPrefix("edges:") || $0.id.hasPrefix("faces:") }
    }
    private var partMetrics: [CADMeasurementMetric] { metrics.filter { $0.id.hasPrefix("parts:") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("MEASUREMENTS")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                CopyButton(text: copyText, label: "Copy measurements").disabled(metrics.isEmpty)
                Button { state.clearSelections() } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("Clear selection").accessibilityLabel("Clear selection")
            }

            if state.isMeasuring {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring separation…").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
            }

            if !summaryMetrics.isEmpty { metricList(summaryMetrics) }

            if !state.selectedSolids.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    selectedParts
                    metricList(partMetrics)
                }
            }

            ForEach(Array(state.selectedFeatures.enumerated()), id: \.element.id) { index, feature in
                VStack(alignment: .leading, spacing: 8) {
                    featureHeading(feature, index: index)
                    metricList(metrics.filter { $0.id.hasPrefix(feature.id + ":") }, removingSelectionPrefix: true)
                }
            }

            if let error = state.measurementError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(error).font(.system(size: 10)).textSelection(.enabled)
                }
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Measurements")
    }

    private func metricList(_ values: [CADMeasurementMetric], removingSelectionPrefix: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(values) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(removingSelectionPrefix ? metric.label.components(separatedBy: " · ").last ?? metric.label : metric.label)
                        .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.formattedValue).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: metric.formattedValue, label: "Copy \(metric.label)")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func featureHeading(_ feature: CADFeatureID, index: Int) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: feature.kind == .vertex ? "circle.fill" : feature.kind == .edge ? "line.diagonal" : "square.fill")
                .font(.system(size: feature.kind == .vertex ? 5 : 10))
                .foregroundStyle(Palette.accent).frame(width: 12, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(feature.title)").font(.system(size: 10, weight: .semibold))
                Text([featureType(feature), partName(feature.solidIndex)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, summaryMetrics.isEmpty && index == 0 ? 0 : 4)
    }

    @ViewBuilder
    private var selectedParts: some View {
        let names = state.selectedSolids.sorted().map { partName($0) }
        if names.count == 1, let name = names.first {
            Label(name, systemImage: "cube")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.system(size: 9)).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 5)
            } label: {
                Text("\(names.count) selected parts").font(.system(size: 10, weight: .semibold))
            }
            .tint(Palette.muted)
        }
    }

    private func partName(_ solidIndex: Int) -> String {
        let nodes = state.partTree.flatMap(\.flattened)
        return nodes.first { !$0.isGroup && $0.solidIndices.contains(solidIndex) }?.name
            ?? nodes.first { $0.solidIndices.contains(solidIndex) }?.name
            ?? "Part \(solidIndex + 1)"
    }

    private func featureType(_ feature: CADFeatureID) -> String? {
        guard let topology = state.mesh?.topology else { return nil }
        let type: String?
        switch feature.kind {
        case .vertex: type = nil
        case .edge: type = topology.edge(for: feature)?.type
        case .face: type = topology.face(for: feature)?.type
        }
        return type?.lowercased().capitalized
    }

    private var copyText: String {
        let features = state.selectedFeatures.enumerated().map { index, feature in
            "\(index + 1). \(feature.title) · \(partName(feature.solidIndex))"
        }
        let parts = state.selectedSolids.sorted().map { partName($0) }
        let values = metrics.map { "\($0.label): \($0.formattedValue)" }
        return (["Measurements"] + features + parts + values).joined(separator: "\n")
    }
}
