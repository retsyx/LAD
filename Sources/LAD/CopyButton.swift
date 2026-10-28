import AppKit
import SwiftUI

@MainActor
struct CopyButton: View {
    private let textProvider: @MainActor () -> String
    var label: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    init(text: String, label: String = "Copy") {
        self.textProvider = { text }
        self.label = label
    }

    /// Large transcripts are assembled only for an explicit copy action, so
    /// measuring or moving the enclosing window never formats the whole log.
    init(label: String = "Copy", textProvider: @escaping @MainActor () -> String) {
        self.textProvider = textProvider
        self.label = label
    }

    /// Keep the data operation separate from visual copied feedback. This is
    /// also usable with a private pasteboard without touching the clipboard.
    @discardableResult
    func writeText(to pasteboard: NSPasteboard) -> Bool {
        let text = textProvider()
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    var body: some View {
        Button {
            guard writeText(to: .general) else { return }
            resetTask?.cancel()
            copied = true
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Color.green.opacity(0.85) : Palette.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : label)
        .accessibilityLabel(label)
        .accessibilityValue(copied ? "Copied" : "")
        .onDisappear { resetTask?.cancel() }
    }
}
