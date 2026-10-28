import AppKit
import UniformTypeIdentifiers

/// A failed autosave is resolved at quit: save a complete copy, or cancel the
/// save panel to leave without saving. Ordinary successful autosaves stay silent.
@MainActor
enum ProjectQuitSave {
    static func save(
        _ state: AppState,
        chooseURL: @MainActor (AppState) -> URL? = chooseDestination,
        onFailure: @MainActor (Error) -> Void = showError
    ) async {
        while state.hasUnsavedChanges {
            guard let url = chooseURL(state) else { return }
            do { try await state.saveProjectForQuit(to: url) }
            catch { onFailure(error) }
        }
    }

    private static func chooseDestination(_ state: AppState) -> URL? {
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.SaveUnsavedProject")
        panel.title = "Save Unsaved Design"
        panel.message = "Cancel quits without saving this design."
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .data]
        panel.nameFieldStringValue = "\(ProjectAutosaveStore.filenameStem(state.title)).lad"
        panel.directoryURL = state.projectURL?.deletingLastPathComponent()
        return SavePanelPresentation.runModal(panel) == .OK ? panel.url : nil
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The design could not be saved."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
