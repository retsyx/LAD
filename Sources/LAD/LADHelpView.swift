import SwiftUI

struct LADHelpView: View {
    var body: some View {
        Form {
            Section("Viewport controls") {
                control("Left-click", "Toggle a vertex, edge, or face")
                control("Command-left-drag", "Move a mechanism part within its mates and travel limits")
                control("Parts tree", "Select whole parts or folders")
                control("Right-click", "Context menu")
                control("Right-drag", "Rotate about the design’s geometric center")
                control("Click cube face", "Fit design from that direction")
                control("Click cube face border", "Fit design from the opposite direction")
                control("Click cube corner", "Fit design from that isometric direction")
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
