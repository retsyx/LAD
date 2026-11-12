import SwiftUI

struct AssemblyMotionControls: View {
    @ObservedObject var state: AppState
    let motion: AssemblyMotion
    /// The turn a continuous revolute slider is centered on while it is dragged.
    @State private var heldTurns: [String: Double] = [:]

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
                if let driver = motion.driver(of: joint.id) {
                    // A coupled joint moves with its driver and is not set directly.
                    HStack(spacing: 4) {
                        Text(joint.name).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(state.jointPosition(joint), format: .number.precision(.fractionLength(0...2)))
                            .monospacedDigit()
                        Text(joint.unit).foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 10))
                    .help("Follows \(driver.name)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(joint.name) position")
                    .accessibilityValue("\(state.jointPosition(joint).formatted()) \(joint.unit), follows \(driver.name)")
                } else {
                    control(joint)
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

    private func control(_ joint: AssemblyJoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(joint.name).lineLimit(2)
                Spacer(minLength: 4)
                TextField(joint.name, value: position(joint), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                    .accessibilityLabel("\(joint.name) position")
                Text(joint.unit).foregroundStyle(Palette.muted)
            }.font(.system(size: 10))
            let bounds = Self.sliderRange(joint, current: state.jointPosition(joint), heldTurn: heldTurns[joint.id])
            if bounds.lowerBound < bounds.upperBound {
                Slider(value: position(joint), in: bounds, onEditingChanged: { editing in
                    heldTurns[joint.id] = editing ? Self.turn(state.jointPosition(joint)) : nil
                })
                    .controlSize(.mini).tint(Palette.accent)
                    .accessibilityLabel("\(joint.name) motion")
                    .accessibilityValue("\(state.jointPosition(joint).formatted()) \(joint.unit)")
            }
        }
    }

    private func position(_ joint: AssemblyJoint) -> Binding<Double> {
        Binding(get: { state.jointPosition(joint) }, set: { state.setJointPosition(joint.id, to: $0) })
    }

    /// The nearest whole-turn angle to a revolute coordinate.
    static func turn(_ degrees: Double) -> Double { (degrees / 360).rounded() * 360 }

    /// Text entry remains unbounded when the joint has no travel limits. A
    /// continuous revolute slider spans one revolution around the current turn,
    /// while the coordinate itself keeps counting turns for couplings. The
    /// window holds during a drag so the thumb does not jump, unless the
    /// position has moved outside it by other means.
    static func sliderRange(_ joint: AssemblyJoint, current: Double, heldTurn: Double?) -> ClosedRange<Double> {
        if let limits = joint.limits, limits.count == 2 { return limits[0]...limits[1] }
        if joint.type == .revolute {
            let center = heldTurn.flatMap { abs(current - $0) <= 180 ? $0 : nil } ?? turn(current)
            return center - 180...center + 180
        }
        let extent = 100.0
        let center = (joint.position / extent).rounded(.towardZero) * extent
        return min(center - extent, current)...max(center + extent, current)
    }
}
