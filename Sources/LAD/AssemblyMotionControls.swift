import SwiftUI

struct AssemblyMotionControls: View {
    @ObservedObject var state: AppState
    let motion: AssemblyMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("MOTION").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted)
                Spacer()
                if state.isSolvingAssembly { ProgressView().controlSize(.mini) }
                Button("Reset") { state.resetAssemblyMotion() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .accessibilityLabel("Reset assembly motion")
            }
            ForEach(motion.joints.filter(\.isMovable)) { joint in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(joint.name).lineLimit(2)
                        Spacer(minLength: 4)
                        TextField(joint.name, value: position(joint), format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                            .accessibilityLabel("\(joint.name) position")
                        Text(joint.unit).foregroundStyle(Palette.muted)
                    }.font(.system(size: 10))
                    if range(joint).lowerBound < range(joint).upperBound {
                        Slider(value: position(joint), in: range(joint))
                            .controlSize(.mini).tint(Palette.accent)
                            .accessibilityLabel("\(joint.name) motion")
                            .accessibilityValue("\(state.jointPosition(joint).formatted()) \(joint.unit)")
                    }
                }
            }
            if let error = state.assemblyMotionError {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(state.isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assembly motion")
    }

    private func position(_ joint: AssemblyJoint) -> Binding<Double> {
        Binding(get: { state.jointPosition(joint) }, set: { state.setJointPosition(joint.id, to: $0) })
    }

    private func range(_ joint: AssemblyJoint) -> ClosedRange<Double> {
        if let limits = joint.limits, limits.count == 2 { return limits[0]...limits[1] }
        let extent = joint.type == .revolute ? 180.0 : 100.0
        // Text entry remains unbounded when the joint has no travel limits.
        let center = (joint.position / extent).rounded(.towardZero) * extent
        let current = state.jointPosition(joint)
        return min(center - extent, current)...max(center + extent, current)
    }
}
