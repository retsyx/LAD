import SwiftUI

struct MeasurementInfoView: View {
    @ObservedObject var state: AppState
    var contentPadding: CGFloat = 15

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
                metricList(partMetrics)
            }

            ForEach(state.selectedFeatures) { feature in
                metricList(metrics.filter { $0.id.hasPrefix(feature.id + ":") })
            }

            if let error = state.measurementError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(error).font(.system(size: 10)).textSelection(.enabled)
                }
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(contentPadding).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Measurements")
    }

    private func metricList(_ values: [CADMeasurementMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(values) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metricLabel(metric))
                        .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.formattedValue).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: metric.formattedValue, label: "Copy \(metricLabel(metric))")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func metricLabel(_ metric: CADMeasurementMetric) -> String {
        metric.label.components(separatedBy: " · ").last ?? metric.label
    }

    private var copyText: String {
        let values = metrics.map { "\(metricLabel($0)): \($0.formattedValue)" }
        return (["Measurements"] + values).joined(separator: "\n")
    }
}
