import AppKit
import SwiftUI
import simd

/// The viewport's section handles and the native numeric editor they activate.
final class CADSectionManipulator: NSView, NSTextFieldDelegate {
    @MainActor private struct Layout: Equatable {
        let center: SIMD2<Double>
        let direction: SIMD2<Double>
        let unitsPerPoint: Double
        let sitsLeft: Bool

        func line(for handle: CADSectionHandle) -> (start: SIMD2<Double>, end: SIMD2<Double>) {
            switch handle {
            case .offset: return (center, center + 64 * direction)
            case .vertical: return (center - SIMD2(0, 25), center + SIMD2(0, 35))
            case .horizontal: return (center + SIMD2(25, 0), center - SIMD2(35, 0))
            }
        }

        var drawingBounds: NSRect {
            NSRect(x: center.x - 76, y: center.y - 76, width: 152, height: 152)
        }

        static func make(plane: CADSectionPlane, projection: CameraRig.Projection, bounds: [Double],
                         editing: Layout?, rotates: Bool) -> Self? {
            guard projection.width > 0, projection.height > 0, bounds.count == 6 else { return nil }
            let low = SIMD3(bounds[0], bounds[1], bounds[2])
            let high = SIMD3(bounds[3], bounds[4], bounds[5])
            let corners = (0..<8).map {
                SIMD3($0 & 1 == 0 ? low.x : high.x, $0 & 2 == 0 ? low.y : high.y, $0 & 4 == 0 ? low.z : high.z)
            }
            let distances = corners.map { simd_dot($0 - plane.origin, plane.normal) }
            var cut = [SIMD3<Double>]()
            for index in corners.indices {
                for bit in [1, 2, 4] where index & bit == 0 {
                    let other = index | bit
                    let a = distances[index], b = distances[other]
                    if a == 0 { cut.append(corners[index]) }
                    if b == 0 { cut.append(corners[other]) }
                    if (a < 0 && b > 0) || (a > 0 && b < 0) {
                        cut.append(simd_mix(corners[index], corners[other], SIMD3(repeating: a / (a - b))))
                    }
                }
            }
            let points = (cut.isEmpty ? corners : cut).map(projection.project)
                .filter { $0.depth > 0 && $0.screen.x.isFinite && $0.screen.y.isFinite }.map(\.screen)
            let sample = cut.isEmpty ? plane.center : cut.reduce(.zero, +) / Double(cut.count)
            let start = projection.project(sample)
            let step = max(0.001, simd_length(high - low) * 0.001)
            let end = projection.project(sample + plane.normal * step)
            let projectedNormal = (end.screen - start.screen) / step
            let normalLength = simd_length(projectedNormal)
            let viewDepth = start.depth > 0 ? start.depth : projection.orthographicScale / projection.tangent
            let unitsPerPoint = 2 * (projection.orthographic ? projection.orthographicScale : viewDepth * projection.tangent)
                / projection.height
            let direction: SIMD2<Double>
            let dragScale: Double
            if end.depth > 0, start.depth > 0, normalLength.isFinite, normalLength * unitsPerPoint >= 0.12 {
                direction = projectedNormal / normalLength
                dragScale = 1 / normalLength
            } else {
                // A plane facing the camera has no useful projected normal.
                // Keep the arrow operable with a stable screen-space direction.
                direction = SIMD2(-0.8660254, -0.5)
                dragScale = unitsPerPoint
            }
            guard dragScale.isFinite, dragScale > 0 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            let left = editing?.sitsLeft ?? (direction.x <= 0)
            let x = left ? (xs.min() ?? projection.width / 2) - 38 : (xs.max() ?? projection.width / 2) + 38
            let y = ((ys.min() ?? projection.height / 2) + (ys.max() ?? projection.height / 2)) / 2
            let clampedCenter = SIMD2(
                min(max(x, min(82, projection.width / 2)), max(projection.width - 82, projection.width / 2)),
                min(max(y, min(110, projection.height / 2)), max(projection.height - 146, projection.height / 2))
            )
            return Self(center: rotates ? (editing?.center ?? clampedCenter) : clampedCenter,
                        direction: direction, unitsPerPoint: dragScale, sitsLeft: left)
        }
    }

    private struct Edit {
        let handle: CADSectionHandle
        let startingPlane: CADSectionPlane
        let mouseStart: SIMD2<Double>?
        let layout: Layout
        var dragging: Bool
        var typed = false
    }

    private let onBegin: () -> Void
    private let onChange: (CADSectionPlane) -> Void
    private var plane: CADSectionPlane?
    private var handles: Layout?
    private var edit: Edit?
    private let editor = NSView()
    private let valueField = NSTextField()
    private let unitLabel = NSTextField(labelWithString: "")
    private var settingReadout = false
    private lazy var accessibilityHandles = CADSectionHandle.allCases.map {
        SectionHandleAccessibilityElement(manipulator: self, handle: $0)
    }

    init(onBegin: @escaping () -> Void, onChange: @escaping (CADSectionPlane) -> Void) {
        self.onBegin = onBegin
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Section plane")

        editor.wantsLayer = true
        editor.layer?.backgroundColor = NSColor(Palette.panel).cgColor
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.cornerRadius = 6
        editor.layer?.borderWidth = 1
        editor.isHidden = true
        addSubview(editor)

        valueField.isEditable = true
        valueField.isSelectable = true
        valueField.isBezeled = false
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueField.focusRingType = .none
        valueField.delegate = self
        valueField.setAccessibilityIdentifier("sectionValueField")
        valueField.cell?.usesSingleLineMode = true
        valueField.cell?.lineBreakMode = .byTruncatingTail
        editor.addSubview(valueField)

        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = NSColor(Palette.muted)
        editor.addSubview(unitLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(plane: CADSectionPlane?, projection: CameraRig.Projection, bounds: [Double]) {
        self.plane = plane
        guard let plane, let layout = Layout.make(plane: plane, projection: projection, bounds: bounds,
                                                   editing: edit?.layout, rotates: edit.map { $0.handle != .offset } == true) else {
            finishEdit()
            handles = nil
            isHidden = true
            return
        }
        isHidden = false
        if handles != layout {
            invalidateHandles()
            handles = layout
            invalidateHandles()
        }
        updateEditorPosition()
    }

    func cancelInteraction() {
        guard let edit else { return }
        finishEdit()
        if edit.dragging { onChange(edit.startingPlane) }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { finishEdit() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func invalidateHandles() {
        if let handles { setNeedsDisplay(handles.drawingBounds) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .magnify:
            return nil
        default: break
        }
        if !editor.isHidden, editor.frame.contains(local) { return super.hitTest(point) }
        return handle(at: SIMD2(local.x, local.y)) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = pointer(event)
        guard let handle = handle(at: point) else { return }
        beginEditing(handle, mouseStart: point)
    }

    override func mouseDragged(with event: NSEvent) { moveHandle(to: pointer(event)) }

    override func mouseUp(with event: NSEvent) {
        moveHandle(to: pointer(event))
        edit?.dragging = false
    }

    private func pointer(_ event: NSEvent) -> SIMD2<Double> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(point.x, point.y)
    }

    private func handle(at point: SIMD2<Double>) -> CADSectionHandle? {
        guard let handles else { return nil }
        // A foreshortened normal can project on top of a rotation bar.
        // Give the visible rotation grips their own reliable targets.
        for bar in [CADSectionHandle.vertical, .horizontal] where simd_distance(point, handles.line(for: bar).end) < 9 {
            return bar
        }
        var nearest = 10.0
        var target: CADSectionHandle?
        for handle in CADSectionHandle.allCases {
            let line = handles.line(for: handle)
            let delta = line.end - line.start
            let fraction = min(1, max(0, simd_dot(point - line.start, delta) / simd_length_squared(delta)))
            let distance = simd_distance(point, line.start + fraction * delta)
            if distance < nearest {
                target = handle
                nearest = distance
            }
        }
        return target
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let handles else { return }
        let gold = NSColor(Palette.accent)
        for handle in [CADSectionHandle.offset, .horizontal, .vertical] {
            let line = handles.line(for: handle)
            let color = gold.withAlphaComponent(edit == nil || edit?.handle == handle ? 1 : 0.53)
            color.setStroke()
            color.setFill()
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(line.start))
            shaft.line(to: NSPoint(handle == .offset ? line.end - 11 * handles.direction : line.end))
            shaft.lineWidth = handle == .offset ? 3.5 : 1.75
            shaft.lineCapStyle = .round
            shaft.stroke()
            if handle == .offset {
                let direction = handles.direction
                let tangent = SIMD2(-direction.y, direction.x)
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(line.end))
                arrow.line(to: NSPoint(line.end - 13 * direction + 6 * tangent))
                arrow.line(to: NSPoint(line.end - 13 * direction - 6 * tangent))
                arrow.close()
                arrow.fill()
            } else {
                let grip = handle == .vertical
                    ? NSRect(x: line.end.x - 3, y: line.end.y - 7, width: 6, height: 14)
                    : NSRect(x: line.end.x - 7, y: line.end.y - 3, width: 14, height: 6)
                NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
            }
        }
        gold.setFill()
        NSBezierPath(ovalIn: NSRect(x: handles.center.x - 5, y: handles.center.y - 5,
                                   width: 10, height: 10)).fill()
    }

    fileprivate func beginEditing(_ handle: CADSectionHandle, mouseStart: SIMD2<Double>? = nil) {
        guard let plane, let handles, window != nil else { return }
        finishEdit()
        onBegin()
        edit = Edit(handle: handle, startingPlane: plane, mouseStart: mouseStart,
                    layout: handles, dragging: mouseStart != nil)
        unitLabel.stringValue = handle == .offset ? "mm" : "°"
        valueField.setAccessibilityLabel(handle.editorLabel)
        valueField.stringValue = display(plane.value(for: handle))
        editor.isHidden = false
        updateEditorPosition()
        valueField.selectText(nil)
        invalidateHandles()
    }

    private func moveHandle(to point: SIMD2<Double>) {
        guard let edit, edit.dragging, !edit.typed, let start = edit.mouseStart else { return }
        let delta = point - start
        let value = edit.startingPlane.value(for: edit.handle)
        let change: Double
        switch edit.handle {
        case .offset: change = simd_dot(delta, edit.layout.direction) * edit.layout.unitsPerPoint
        case .vertical: change = delta.y * 0.5
        case .horizontal: change = delta.x * 0.5
        }
        guard let next = edit.startingPlane.setting(value + change, for: edit.handle), next != plane else { return }
        onChange(next)
        setReadout(next.value(for: edit.handle))
    }

    private func display(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).sign(strategy: .always(includingZero: false))
            .precision(.fractionLength(1...3)))
    }

    private func setReadout(_ value: Double) {
        let text = display(value)
        settingReadout = true
        if let fieldEditor = valueField.currentEditor() as? NSTextView {
            fieldEditor.string = text
            fieldEditor.selectAll(nil)
        } else {
            valueField.stringValue = text
        }
        settingReadout = false
    }

    private func updateEditorPosition() {
        guard let handles, let edit else { return }
        let width: Double = 107
        let height: Double = 29
        let end = handles.line(for: edit.handle).end
        let proposedX = edit.handle == .vertical ? end.x + 13 : end.x - width / 2
        let proposedY = edit.handle == .vertical ? end.y - height / 2 : end.y - height - 12
        let x = min(max(6, proposedX), max(6, bounds.width - width - 6))
        let y = min(max(6, proposedY), max(6, bounds.height - height - 6))
        editor.frame = NSRect(x: x, y: y, width: width, height: height)
        valueField.frame = NSRect(x: 7, y: 5, width: 69, height: 19)
        unitLabel.frame = NSRect(x: 78, y: 6, width: 26, height: 17)
    }

    func controlTextDidChange(_ notification: Notification) {
        if !settingReadout { edit?.typed = true }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishEdit(restoreResponder: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let edit, let plane else { return false }
            if edit.typed {
                let separator = Locale.current.decimalSeparator ?? "."
                let input = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: separator, with: ".")
                    .replacingOccurrences(of: "−", with: "-")
                guard let value = Double(input), let next = plane.setting(value, for: edit.handle) else {
                    NSSound.beep()
                    textView.selectAll(nil)
                    return true
                }
                finishEdit()
                onChange(next)
            } else {
                finishEdit()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelInteraction()
            return true
        default:
            return false
        }
    }

    private func finishEdit(restoreResponder: Bool = true) {
        guard edit != nil else { return }
        edit = nil
        if restoreResponder, let window, window.firstResponder === valueField.currentEditor() {
            window.makeFirstResponder(superview)
        }
        editor.isHidden = true
        invalidateHandles()
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = accessibilityHandles
        if !editor.isHidden { children.append(valueField) }
        return children
    }

    fileprivate func accessibilityRect(for handle: CADSectionHandle) -> NSRect {
        guard let point = handles?.line(for: handle).end else { return .zero }
        let rect = NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }
}

private extension CADSectionHandle {
    var editorLabel: String {
        switch self {
        case .offset: "Section offset in millimeters"
        case .vertical: "Vertical section angle in degrees"
        case .horizontal: "Horizontal section angle in degrees"
        }
    }
}

private extension NSPoint {
    init(_ vector: SIMD2<Double>) { self.init(x: vector.x, y: vector.y) }
}

private final class SectionHandleAccessibilityElement: NSAccessibilityElement {
    private weak var manipulator: CADSectionManipulator?
    private let handle: CADSectionHandle

    init(manipulator: CADSectionManipulator, handle: CADSectionHandle) {
        self.manipulator = manipulator
        self.handle = handle
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(handle.editorLabel)
        setAccessibilityParent(manipulator)
    }

    override func accessibilityFrame() -> NSRect { manipulator?.accessibilityRect(for: handle) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard let manipulator else { return false }
        manipulator.beginEditing(handle)
        return true
    }
}
