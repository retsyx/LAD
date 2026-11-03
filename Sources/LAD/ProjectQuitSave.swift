import AppKit
import UniformTypeIdentifiers

/// Ordinary successful autosaves stay silent. A failed save never turns Cancel
/// into permission to discard a design or terminate the application.
@MainActor
enum ProjectQuitSave {
    enum Choice { case save, dontSave, cancel }

    @discardableResult
    static func save(
        _ state: AppState,
        chooseAction: @MainActor (AppState) -> Choice = chooseAction,
        chooseURL: @MainActor (AppState) -> URL? = chooseDestination,
        onFailure: @MainActor (Error) -> Void = showError
    ) async -> Bool {
        while state.hasUnsavedChanges {
            switch chooseAction(state) {
            case .dontSave: return true
            case .cancel: return false
            case .save: break
            }
            guard let url = chooseURL(state) else { return false }
            do { try await state.saveProjectForQuit(to: url) }
            catch { onFailure(error) }
        }
        return true
    }

    private static func chooseAction(_ state: AppState) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(state.title)” before quitting?"
        alert.informativeText = "Your latest changes could not be saved automatically."
        alert.addButton(withTitle: "Save…")
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    private static func chooseDestination(_ state: AppState) -> URL? {
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("LAD.SaveUnsavedProject")
        panel.title = "Save Unsaved Design"
        panel.allowedContentTypes = [UTType(filenameExtension: "lad") ?? .package]
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
