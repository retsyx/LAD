import AppKit
import UniformTypeIdentifiers

@MainActor
final class STEPExportOptionsView: NSView {
    private static let printingPreferenceKey = "stepExportFor3DPrinting"
    private static let individualPreferenceKey = "stepExportIndividualParts"
    private let printing = NSButton(checkboxWithTitle: "For 3D printing", target: nil, action: nil)
    private let individual = NSButton(checkboxWithTitle: "Export individual parts", target: nil, action: nil)
    private let defaults: UserDefaults
    private weak var panel: NSSavePanel?
    private let folderName: String
    private let stepTypes: [UTType]
    private let allowsOtherFileTypes: Bool
    private let extensionHidden: Bool
    private let nameLabel: String
    private var stepName: String

    var for3DPrinting: Bool { printing.state == .on }
    var exportIndividualParts: Bool { individual.state == .on }

    init(panel: NSSavePanel, projectName: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.panel = panel
        folderName = projectName
        stepTypes = panel.allowedContentTypes
        allowsOtherFileTypes = panel.allowsOtherFileTypes
        extensionHidden = panel.isExtensionHidden
        nameLabel = panel.nameFieldLabel
        stepName = panel.nameFieldStringValue
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        printing.state = defaults.bool(forKey: Self.printingPreferenceKey) ? .on : .off
        individual.state = defaults.bool(forKey: Self.individualPreferenceKey) ? .on : .off
        printing.target = self
        printing.action = #selector(printingChanged)
        individual.target = self
        individual.action = #selector(individualChanged)
        let stack = NSStackView(views: [printing, individual])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        if exportIndividualParts { updatePanelMode() }
    }

    @objc private func printingChanged() {
        defaults.set(for3DPrinting, forKey: Self.printingPreferenceKey)
    }

    @objc private func individualChanged() {
        defaults.set(exportIndividualParts, forKey: Self.individualPreferenceKey)
        updatePanelMode()
    }

    private func updatePanelMode() {
        guard let panel else { return }
        if exportIndividualParts {
            stepName = panel.nameFieldStringValue
            // The app publishes a complete directory after all exports finish.
            // Clearing the file type prevents AppKit from appending .step.
            panel.allowedContentTypes = []
            panel.allowsOtherFileTypes = true
            panel.isExtensionHidden = false
            panel.nameFieldLabel = "Folder:"
            panel.nameFieldStringValue = folderName
        } else {
            panel.allowedContentTypes = stepTypes
            panel.allowsOtherFileTypes = allowsOtherFileTypes
            panel.isExtensionHidden = extensionHidden
            panel.nameFieldLabel = nameLabel
            panel.nameFieldStringValue = stepName
        }
    }

    required init?(coder: NSCoder) { nil }
}
