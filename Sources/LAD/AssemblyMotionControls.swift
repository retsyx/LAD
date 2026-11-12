import SwiftUI

struct AssemblyMotionControls: View {
    @ObservedObject var state: AppState
    let motion: AssemblyMotion
    /// Each continuous revolute slider's current window center.
    @State private var revolutionCenters: [String: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("MOTION").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted)
                Spacer()
                if state.isSolvingAssembly { ProgressView().controlSize(.mini) }
                Button("Reset") { state.resetAssemblyMotion(); revolutionCenters.removeAll() }
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
            let bounds = Self.sliderRange(joint, current: state.jointPosition(joint), center: revolutionCenters[joint.id])
            if bounds.lowerBound < bounds.upperBound {
                Slider(value: position(joint), in: bounds, onEditingChanged: { editing in
                    guard joint.type == .revolute, joint.limits == nil else { return }
                    revolutionCenters[joint.id] = Self.revolutionCenter(current: state.jointPosition(joint),
                        held: revolutionCenters[joint.id], released: !editing)
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

    /// A continuous revolute slider spans one revolution, while the coordinate
    /// itself keeps counting turns for couplings. Its window stays put while it
    /// contains the position, so the thumb does not jump. Releasing a drag at
    /// either end recenters it on the position, so the joint can keep turning
    /// either way. A position that leaves the window by other means shows
    /// within its nearest whole turn.
    static func revolutionCenter(current: Double, held: Double?, released: Bool = false) -> Double {
        guard let held, abs(current - held) <= 180 else { return turn(current) }
        return released && abs(current - held) >= 180 - 1e-6 ? current : held
    }

    /// Text entry remains unbounded when the joint has no travel limits.
    static func sliderRange(_ joint: AssemblyJoint, current: Double, center: Double?) -> ClosedRange<Double> {
        if let limits = joint.limits, limits.count == 2 { return limits[0]...limits[1] }
        if joint.type == .revolute {
            let center = revolutionCenter(current: current, held: center)
            return center - 180...center + 180
        }
        let extent = 100.0
        let center = (joint.position / extent).rounded(.towardZero) * extent
        return min(center - extent, current)...max(center + extent, current)
    }
}
