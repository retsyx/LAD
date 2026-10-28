import AppKit
import SwiftUI

struct PartColorPicker: View {
    let initialColor: PartColor?
    let recentColors: [PartColor]
    let onApply: (PartColor?) -> Void
    let onCancel: () -> Void
    @State private var customColor: Color

    init(initialColor: PartColor?, recentColors: [PartColor],
         onApply: @escaping (PartColor?) -> Void, onCancel: @escaping () -> Void) {
        self.initialColor = initialColor
        self.recentColors = recentColors
        self.onApply = onApply
        self.onCancel = onCancel
        _customColor = State(initialValue: initialColor?.swatchColor ?? Color(red: 0.68, green: 0.74, blue: 0.82))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Part Color").font(.headline)
            swatches(PartColor.curated)
            if !recentColors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(.subheadline).foregroundStyle(.secondary)
                    swatches(recentColors)
                }
            }
            Divider()
            HStack {
                Text("Custom Color").font(.subheadline)
                Spacer()
                AnchoredPartColorWell(color: $customColor).frame(width: 44, height: 24)
            }
            HStack(spacing: 8) {
                Button("Default Color") { onApply(nil) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let color = PartColor.fromPicker(customColor) { onApply(color) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 304)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }

    private func swatches(_ colors: [PartColor]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button { onApply(color) } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.swatchColor)
                        .frame(width: 32, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        }
                        .overlay {
                            if color == initialColor {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(color.isLight ? Color.black.opacity(0.8) : Color.white)
                            }
                        }
                        .padding(2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(color == initialColor ? Palette.accent : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(color.hexLabel)
                .accessibilityLabel("Use color \(color.hexLabel)")
                .accessibilityAddTraits(color == initialColor ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Choose a side before clamping so a remembered system-panel position never
/// sends the custom picker away from the part's swatches.
enum PartColorPanelPosition {
    static func frame(for size: NSSize, beside anchor: NSRect, in visibleFrame: NSRect) -> NSRect {
        let inset = visibleFrame.insetBy(dx: 8, dy: 8)
        let available = inset.width > 0 && inset.height > 0 ? inset : visibleFrame
        let size = NSSize(width: min(size.width, available.width), height: min(size.height, available.height))
        let gap: CGFloat = 10
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - size.width
        let preferredX: CGFloat
        if right + size.width <= available.maxX { preferredX = right }
        else if left >= available.minX { preferredX = left }
        else {
            let rightSpace = available.maxX - anchor.maxX
            let leftSpace = anchor.minX - available.minX
            preferredX = rightSpace >= leftSpace ? right : left
        }
        return NSRect(x: min(max(preferredX, available.minX), available.maxX - size.width),
                      y: min(max(anchor.maxY - size.height, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

private struct AnchoredPartColorWell: NSViewRepresentable {
    @Binding var color: Color

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PartColorWell {
        let well = PartColorWell(frame: .zero)
        well.colorWellStyle = .default
        well.supportsAlpha = false
        well.color = NSColor(color)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        well.setAccessibilityLabel("Custom part color")
        return well
    }

    func updateNSView(_ well: PartColorWell, context: Context) {
        context.coordinator.parent = self
        let resolved = NSColor(color)
        if !well.color.isEqual(resolved) { well.color = resolved }
    }

    static func dismantleNSView(_ well: PartColorWell, coordinator: Coordinator) {
        well.deactivate()
        well.target = nil
        well.action = nil
    }

    final class Coordinator: NSObject {
        var parent: AnchoredPartColorWell
        init(_ parent: AnchoredPartColorWell) { self.parent = parent }

        @objc func colorChanged(_ sender: NSColorWell) {
            parent.color = Color(nsColor: sender.color)
        }
    }
}

private final class PartColorWell: NSColorWell {
    private static weak var panelOwner: PartColorWell?
    private var panelObservers: [NSObjectProtocol] = []

    override func activate(_ exclusive: Bool) {
        Self.panelOwner?.releasePanel(hide: false)
        Self.panelOwner = self
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        positionPanel()
        super.activate(exclusive)
        attachPanel()
        positionPanel()
        // AppKit can restore the palette's saved frame while ordering it in.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, Self.panelOwner === self else { return }
            self.attachPanel()
            self.positionPanel()
        }
    }

    override func deactivate() {
        super.deactivate()
        releasePanel(hide: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { deactivate() }
    }

    private func attachPanel() {
        guard Self.panelOwner === self, let host = window else { return }
        let panel = NSColorPanel.shared
        if panel.parent !== host {
            panel.parent?.removeChildWindow(panel)
            host.addChildWindow(panel, ordered: .above)
        }
        removePanelObservers()
        for (name, object) in [(NSWindow.didMoveNotification, host), (NSWindow.didResizeNotification, host),
                               (NSWindow.didResizeNotification, panel)] {
            panelObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, Self.panelOwner === self else { return }
                    self.positionPanel()
                }
            })
        }
    }

    private func removePanelObservers() {
        for observer in panelObservers { NotificationCenter.default.removeObserver(observer) }
        panelObservers.removeAll()
    }

    private func positionPanel() {
        guard Self.panelOwner === self, let host = window, let screen = host.screen ?? NSScreen.main else { return }
        let panel = NSColorPanel.shared
        let frame = PartColorPanelPosition.frame(for: panel.frame.size, beside: host.frame, in: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    private func releasePanel(hide: Bool) {
        removePanelObservers()
        guard Self.panelOwner === self else { return }
        let panel = NSColorPanel.shared
        panel.parent?.removeChildWindow(panel)
        if hide { panel.orderOut(nil) }
        Self.panelOwner = nil
    }
}

private extension PartColor {
    var swatchColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var isLight: Bool { red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.62 }
    var hexLabel: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    static func fromPicker(_ color: Color) -> PartColor? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return PartColor(red: min(1, max(0, Double(rgb.redComponent))), green: min(1, max(0, Double(rgb.greenComponent))),
                         blue: min(1, max(0, Double(rgb.blueComponent))))
    }
}
