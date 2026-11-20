import AppKit
import SwiftUI
import simd

/// The viewport's section handles and the native numeric editor they activate.
final class CADSectionManipulator: NSView, NSTextFieldDelegate {
    private enum OffsetShape: Equatable {
        case arrow(length: Double)
        case depth(towardViewer: Bool)
    }

    @MainActor private struct Layout: Equatable {
        static let fullArrowLength = 50.0

        let center: SIMD2<Double>
        let direction: SIMD2<Double>
        let pointsPerMillimeter: Double
        let relativeDepthChange: Double
        let offsetShape: OffsetShape
        let offsetInFront: Bool

        var drawingOrder: [CADSectionHandle] {
            offsetInFront ? [.horizontal, .vertical, .offset] : [.offset, .horizontal, .vertical]
        }

        func line(for handle: CADSectionHandle) -> (start: SIMD2<Double>, end: SIMD2<Double>) {
            switch handle {
            case .offset:
                if case let .arrow(length) = offsetShape { return (center, center + length * direction) }
                return (center, center)
            case .vertical: return (center - SIMD2(0, 28), center + SIMD2(0, 37))
            case .horizontal: return (center + SIMD2(28, 0), center - SIMD2(37, 0))
            }
        }

        var drawingBounds: NSRect {
            NSRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120)
        }

        func offsetChange(for drag: SIMD2<Double>) -> Double {
            let travel = simd_dot(drag, direction)
            // Perspective travel is pointsPerMillimeter * offset / (1 + depth change).
            // Invert it and bound the gain near the line's vanishing point.
            let rate = max(pointsPerMillimeter - travel * relativeDepthChange, 0.1 * pointsPerMillimeter)
            return travel / rate
        }

        static func make(plane: CADSectionPlane, projection: CameraRig.Projection) -> Self? {
            guard projection.width > 0, projection.height > 0 else { return nil }
            let hub = projection.project(plane.origin)
            guard hub.depth > 0, hub.screen.x.isFinite, hub.screen.y.isFinite else { return nil }
            let extent = projection.orthographic ? projection.orthographicScale : hub.depth * projection.tangent
            let unitsPerPoint = 2 * extent / projection.height
            guard unitsPerPoint.isFinite, unitsPerPoint > 0 else { return nil }

            let facing = simd_dot(plane.normal, projection.backward)
            let depthChange = projection.orthographic ? 0 : -facing / hub.depth
            let screenCenter = SIMD2(projection.width, projection.height) / 2
            let normalInView = SIMD2(simd_dot(plane.normal, projection.right), simd_dot(plane.normal, projection.up))
            let velocity = normalInView / unitsPerPoint - (hub.screen - screenCenter) * depthChange
            let speed = simd_length(velocity)
            guard speed.isFinite else { return nil }
            let projectedGain = speed * unitsPerPoint
            if projectedGain < 0.12 {
                // Near the sightline, the normal has little screen extent.
                // Show its depth direction and use vertical motion for offset.
                return Self(center: hub.screen, direction: SIMD2(0, 1),
                            pointsPerMillimeter: 1 / unitsPerPoint, relativeDepthChange: 0,
                            offsetShape: .depth(towardViewer: facing > 0), offsetInFront: true)
            }
            // The rotation bars lie at the hub's depth. Preserve their order
            // when the arrow lies in that same screen plane.
            return Self(center: hub.screen, direction: velocity / speed,
                        pointsPerMillimeter: speed, relativeDepthChange: depthChange,
                        offsetShape: .arrow(length: fullArrowLength * min(1, projectedGain / 0.48)),
                        offsetInFront: facing > 1e-9)
        }
    }

    @MainActor private struct HandleGeometry {
        let handle: CADSectionHandle
        let shaft: NSBezierPath?
        let grip: NSBezierPath
        private let shaftOutline: CGPath?

        init(_ handle: CADSectionHandle, layout: Layout) {
            self.handle = handle
            let line = layout.line(for: handle)
            guard line.start != line.end else {
                shaft = nil
                shaftOutline = nil
                // The depth handle's ring has an 18-point centerline and a
                // two-point stroke. Its filled interior also receives clicks.
                grip = NSBezierPath(ovalIn: NSRect(x: line.end.x - 10, y: line.end.y - 10, width: 20, height: 20))
                return
            }

            let arrowScale = handle == .offset ? simd_distance(line.start, line.end) / Layout.fullArrowLength : 1
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(line.start))
            shaft.line(to: NSPoint(handle == .offset ? line.end - 12 * arrowScale * layout.direction : line.end))
            shaft.lineWidth = handle == .offset ? max(3, 6 * arrowScale) : 4
            shaft.lineCapStyle = .round
            self.shaft = shaft
            shaftOutline = shaft.cgPath.copy(strokingWithWidth: shaft.lineWidth, lineCap: .round,
                                             lineJoin: .miter, miterLimit: shaft.miterLimit)

            if handle == .offset {
                let direction = layout.direction
                let tangent = SIMD2(-direction.y, direction.x)
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(line.end))
                arrow.line(to: NSPoint(line.end + arrowScale * (-16 * direction + 11 * tangent)))
                arrow.line(to: NSPoint(line.end + arrowScale * (-16 * direction - 11 * tangent)))
                arrow.close()
                grip = arrow
            } else {
                let rect = handle == .vertical
                    ? NSRect(x: line.end.x - 6, y: line.end.y - 9, width: 12, height: 18)
                    : NSRect(x: line.end.x - 9, y: line.end.y - 6, width: 18, height: 12)
                grip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            }
        }

        func contains(_ point: NSPoint) -> Bool {
            grip.contains(point) || shaftOutline?.contains(point) == true
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
    private var handleGeometry: [HandleGeometry] = []
    private var edit: Edit?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredHandle: CADSectionHandle?
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

    func update(plane: CADSectionPlane?, projection: CameraRig.Projection) {
        self.plane = plane
        guard let plane, let layout = Layout.make(plane: plane, projection: projection) else {
            setHoveredHandle(nil)
            finishEdit()
            handles = nil
            handleGeometry = []
            isHidden = true
            return
        }
        isHidden = false
        let layoutChanged = handles != layout
        if layoutChanged {
            invalidateHandles()
            handles = layout
            handleGeometry = layout.drawingOrder.map { HandleGeometry($0, layout: layout) }
            invalidateHandles()
        }
        updateEditorPosition()
        if layoutChanged {
            if let window, window.isKeyWindow, NSEvent.pressedMouseButtons == 0 {
                updateHover(at: window.mouseLocationOutsideOfEventStream)
            } else {
                setHoveredHandle(nil)
            }
        }
    }

    func cancelInteraction() {
        defer { setHoveredHandle(nil) }
        guard let edit else { return }
        finishEdit()
        if edit.dragging { onChange(edit.startingPlane) }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            setHoveredHandle(nil)
            finishEdit()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { setHoveredHandle(nil) }

    private func updateHover(at pointInWindow: NSPoint) {
        let point = convert(pointInWindow, from: nil)
        guard edit?.dragging != true, let handle = handle(at: SIMD2(point.x, point.y)) else {
            setHoveredHandle(nil)
            return
        }
        // Tracking spans the viewport, including locations covered by its
        // controls. Highlight a handle only when it would receive the click.
        if let content = window?.contentView, content.hitTest(convert(point, to: content.superview)) !== self {
            setHoveredHandle(nil)
            return
        }
        setHoveredHandle(handle)
    }

    private func setHoveredHandle(_ handle: CADSectionHandle?) {
        guard handle != hoveredHandle else { return }
        hoveredHandle = handle
        invalidateHandles()
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
        updateHover(at: event.locationInWindow)
    }

    private func pointer(_ event: NSEvent) -> SIMD2<Double> {
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2(point.x, point.y)
    }

    private func handle(at point: SIMD2<Double>) -> CADSectionHandle? {
        let location = NSPoint(point)
        guard !isHidden, bounds.contains(location), editor.isHidden || !editor.frame.contains(location),
              let handles else { return nil }
        let hitRadius = 14.0
        let reach = Layout.fullArrowLength + hitRadius
        guard simd_length_squared(point - handles.center) <= reach * reach else { return nil }
        // Match the pixels under the pointer before using the larger targets.
        if let visible = handleGeometry.reversed().first(where: { $0.contains(location) }) { return visible.handle }
        var nearest = hitRadius
        var target: CADSectionHandle?
        for handle in CADSectionHandle.allCases {
            let distance = simd_distance(point, handles.line(for: handle).end)
            if distance <= nearest {
                target = handle
                nearest = distance
            }
        }
        if let target { return target }
        for handle in CADSectionHandle.allCases {
            let line = handles.line(for: handle)
            let delta = line.end - line.start
            let lengthSquared = simd_length_squared(delta)
            guard lengthSquared > 0 else { continue }
            let fraction = min(1, max(0, simd_dot(point - line.start, delta) / lengthSquared))
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
        for geometry in handleGeometry {
            guard let shaft = geometry.shaft else { continue }
            let color = handleColor(geometry.handle, gold: gold)
            color.setStroke()
            color.setFill()
            shaft.stroke()
            geometry.grip.fill()
        }
        if case let .depth(towardViewer) = handles.offsetShape {
            drawDepthHandle(at: handles.center, towardViewer: towardViewer, color: handleColor(.offset, gold: gold))
        } else {
            gold.setFill()
            NSBezierPath(ovalIn: NSRect(x: handles.center.x - 6, y: handles.center.y - 6,
                                       width: 12, height: 12)).fill()
        }
    }

    private func handleColor(_ handle: CADSectionHandle, gold: NSColor) -> NSColor {
        if hoveredHandle == handle { return gold.blended(withFraction: 0.4, of: .white) ?? gold }
        return gold.withAlphaComponent(edit == nil || edit?.handle == handle ? 1 : 0.53)
    }

    private func drawDepthHandle(at center: SIMD2<Double>, towardViewer: Bool, color: NSColor) {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
        NSColor(Palette.panel).setFill()
        ring.fill()
        color.setStroke()
        ring.lineWidth = 2
        ring.stroke()
        if towardViewer {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
        } else {
            let cross = NSBezierPath()
            for slope in [-3.0, 3.0] {
                let diagonal = SIMD2(3, slope)
                cross.move(to: NSPoint(center - diagonal))
                cross.line(to: NSPoint(center + diagonal))
            }
            cross.lineWidth = 2
            cross.lineCapStyle = .round
            cross.stroke()
        }
    }

    fileprivate func beginEditing(_ handle: CADSectionHandle, mouseStart: SIMD2<Double>? = nil) {
        guard let plane, let handles, window != nil else { return }
        finishEdit()
        onBegin()
        edit = Edit(handle: handle, startingPlane: plane, mouseStart: mouseStart,
                    layout: handles, dragging: mouseStart != nil)
        setHoveredHandle(nil)
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
        case .offset: change = edit.layout.offsetChange(for: delta)
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
        let rect = NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
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
