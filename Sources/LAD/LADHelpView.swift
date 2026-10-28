import SwiftUI

struct LADHelpView: View {
    var body: some View {
        Form {
            Section("Viewport controls") {
                control("Left-click", "Toggle a vertex, edge, or face")
                control("Parts tree", "Select whole parts or folders")
                control("Right-click", "Context menu")
                control("Right-drag", "Rotate about the design’s geometric center")
                control("Scroll / pinch", "Zoom toward the cursor")
                control("Middle-drag / Shift-right-drag", "Pan")
                control("Double-click empty space / Escape", "Deselect all")
                control("F", "Fit design")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 480)
    }

    private func control(_ key: String, _ action: String) -> some View {
        LabeledContent(key) { Text(action).foregroundStyle(.secondary) }.font(.caption)
    }
}
