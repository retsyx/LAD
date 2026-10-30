@testable import LAD

extension AppState {
    /// Establish a submitted request without launching Codex or CAD workers.
    /// Keep this synchronous so cancellation precedes the request task's turn.
    @MainActor
    func newProjectWithSubmittedRequest(_ request: String = "Create a design") {
        newProject()
        prompt = request
        submit()
        cancel()
    }
}
