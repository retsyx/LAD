import AppKit

@MainActor
final class STEPExportOptionsView: NSView {
    private let arrange = NSButton(checkboxWithTitle: "Arrange for 3D printing", target: nil, action: nil)

    var arrangeFor3DPrinting: Bool { arrange.state == .on }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        arrange.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrange)
        NSLayoutConstraint.activate([
            arrange.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            arrange.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrange.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
