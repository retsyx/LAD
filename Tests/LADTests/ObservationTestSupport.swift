import Observation

/// Delivers a tracked expression's value after each change, on the main
/// actor. Changes made in one synchronous stretch arrive as their final value.
@MainActor
final class ObservationRecorder {
    private var active = true

    init<Value>(_ read: @escaping @MainActor () -> Value, onChange handle: @escaping @MainActor (Value) -> Void) {
        observe(read, handle, deliver: false)
    }

    func cancel() { active = false }

    private func observe<Value>(_ read: @escaping @MainActor () -> Value, _ handle: @escaping @MainActor (Value) -> Void,
                                deliver: Bool) {
        let value = withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.observe(read, handle, deliver: true)
            }
        }
        if deliver { handle(value) }
    }
}
