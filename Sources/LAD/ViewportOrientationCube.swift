import AppKit
import simd

enum ViewportCubeFace: String, CaseIterable {
    case front, back, left, right, top, bottom

    var title: String { rawValue.capitalized }

    var normal: SIMD3<Double> {
        switch self {
        case .front: return [0, -1, 0]
        case .back: return [0, 1, 0]
        case .left: return [-1, 0, 0]
        case .right: return [1, 0, 0]
        case .top: return [0, 0, 1]
        case .bottom: return [0, 0, -1]
        }
    }

    // These axes keep each label upright when looking directly at its face.
    // Their cross product is the outward face normal, so visible text is never mirrored.
    fileprivate var horizontal: SIMD3<Double> {
        switch self {
        case .front, .top, .bottom: return [1, 0, 0]
        case .back: return [-1, 0, 0]
        case .left: return [0, -1, 0]
        case .right: return [0, 1, 0]
        }
    }

    fileprivate var vertical: SIMD3<Double> {
        switch self {
        case .front, .back, .left, .right: return [0, 0, 1]
        case .top: return [0, 1, 0]
        case .bottom: return [0, -1, 0]
        }
    }
}

struct ViewportCubeProjection {
    struct Face {
        let direction: ViewportCubeFace
        let points: [NSPoint]
        let center: NSPoint
        let horizontal: CGVector
        let vertical: CGVector
        let facing: Double

        var frame: NSRect {
            let xs = points.map(\.x), ys = points.map(\.y)
            return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }

        func contains(_ point: NSPoint) -> Bool {
            // Projection preserves the counterclockwise winding of an outward-facing face.
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                if (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) < -1e-6 {
                    return false
                }
            }
            return true
        }
    }

    let faces: [Face]

    init(bounds: NSRect, right: SIMD3<Double>, up: SIMD3<Double>, backward: SIMD3<Double>) {
        let scale = max(0, min(bounds.width, bounds.height) - 12) / (2 * sqrt(3))
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        func project(_ point: SIMD3<Double>) -> NSPoint {
            NSPoint(x: center.x + simd_dot(point, right) * scale,
                    y: center.y + simd_dot(point, up) * scale)
        }
        faces = ViewportCubeFace.allCases.compactMap { direction in
            let facing = simd_dot(direction.normal, backward)
            guard facing > 1e-8 else { return nil }
            let horizontal = direction.horizontal, vertical = direction.vertical, normal = direction.normal
            return Face(direction: direction,
                        points: [project(normal - horizontal - vertical), project(normal + horizontal - vertical),
                                 project(normal + horizontal + vertical), project(normal - horizontal + vertical)],
                        center: project(normal),
                        horizontal: CGVector(dx: simd_dot(horizontal, right), dy: simd_dot(horizontal, up)),
                        vertical: CGVector(dx: simd_dot(vertical, right), dy: simd_dot(vertical, up)),
                        facing: facing)
        }.sorted { $0.facing < $1.facing }
    }

    func face(at point: NSPoint) -> ViewportCubeFace? {
        faces.reversed().first { $0.contains(point) }?.direction
    }
}

/// A camera indicator and navigation surface. It redraws only when its pose or hover changes.
final class ViewportOrientationCube: NSView {
    var onOrbit: ((Double, Double) -> Void)?
    var onSelectFace: ((ViewportCubeFace) -> Void)?

    private var right = SIMD3<Double>(sqrt(0.5), sqrt(0.5), 0)
    private var up = SIMD3<Double>(-1 / sqrt(6), 1 / sqrt(6), sqrt(2.0 / 3))
    private var backward = SIMD3<Double>(1 / sqrt(3), -1 / sqrt(3), 1 / sqrt(3))
    private var projection: ViewportCubeProjection?
    private var projectionBounds = NSRect.null
    private var hover: ViewportCubeFace?
    private var pointerArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var gesture: Gesture?
    private var faceElements: [CubeFaceAccessibilityElement] = []

    private struct Gesture {
        let start: NSPoint
        let face: ViewportCubeFace?
        var last: NSPoint
        var dragging = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("View orientation")
        setAccessibilityIdentifier("viewportOrientationCube")
        faceElements = ViewportCubeFace.allCases.map { CubeFaceAccessibilityElement(cube: self, face: $0) }
        setAccessibilityChildren(faceElements)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 92) }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setOrientation(right: SIMD3<Double>, up: SIMD3<Double>, backward: SIMD3<Double>) {
        guard self.right != right || self.up != up || self.backward != backward else { return }
        self.right = right
        self.up = up
        self.backward = backward
        projection = nil
        setHover(nil)
        needsDisplay = true
    }

    var projectedFaces: [ViewportCubeProjection.Face] { currentProjection.faces }

    func face(at point: NSPoint) -> ViewportCubeFace? { currentProjection.face(at: point) }

    private var currentProjection: ViewportCubeProjection {
        if projection == nil || projectionBounds != bounds {
            projection = ViewportCubeProjection(bounds: bounds, right: right, up: up, backward: backward)
            projectionBounds = bounds
        }
        return projection!
    }

    override func draw(_ dirtyRect: NSRect) {
        let faces = projectedFaces
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        for face in faces { fill(face) }
        NSGraphicsContext.restoreGraphicsState()
        for face in faces {
            let path = path(for: face)
            path.lineWidth = 1
            path.lineJoinStyle = .round
            NSColor(calibratedWhite: 0.64, alpha: 0.65).setStroke()
            path.stroke()
            drawLabel(on: face)
        }
    }

    private func fill(_ face: ViewportCubeProjection.Face) {
        let color: NSColor
        if face.direction == hover {
            color = NSColor(calibratedRed: 0.59, green: 0.43, blue: 0.25, alpha: 1)
        } else {
            let brightness = 0.22 + 0.065 * simd_dot(face.direction.normal, up) + 0.045 * face.facing
            color = NSColor(calibratedRed: brightness * 0.91, green: brightness * 0.97,
                            blue: brightness * 1.10, alpha: 1)
        }
        color.setFill()
        path(for: face).fill()
    }

    private func path(for face: ViewportCubeProjection.Face) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: face.points[0])
        for point in face.points.dropFirst() { path.line(to: point) }
        path.close()
        return path
    }

    private func drawLabel(on face: ViewportCubeProjection.Face) {
        guard face.facing > 0.08 else { return }
        NSGraphicsContext.saveGraphicsState()
        path(for: face).addClip()
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: face.horizontal.dx, m12: face.horizontal.dy,
                                                            m21: face.vertical.dx, m22: face.vertical.dy,
                                                            tX: face.center.x, tY: face.center.y)
        transform.concat()
        let label = NSAttributedString(string: face.direction.title, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1)
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInActiveApp, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(with event: NSEvent) {
        guard gesture?.dragging != true else { return }
        setHover(face(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHover(_ face: ViewportCubeFace?) {
        guard hover != face else { return }
        hover = face
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        let point = convert(event.locationInWindow, from: nil)
        gesture = Gesture(start: point, face: face(at: point), last: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !gesture.dragging {
            guard hypot(point.x - gesture.start.x, point.y - gesture.start.y) >= 3 else { return }
            gesture.dragging = true
            setHover(nil)
        }
        let dx = point.x - gesture.last.x, dy = point.y - gesture.last.y
        gesture.last = point
        self.gesture = gesture
        if dx != 0 || dy != 0 { onOrbit?(Double(dx), Double(dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        let point = convert(event.locationInWindow, from: nil)
        let face = face(at: point)
        if !gesture.dragging, hypot(point.x - gesture.start.x, point.y - gesture.start.y) < 3,
           let face, gesture.face == face {
            onSelectFace?(face)
        }
        setHover(bounds.contains(point) ? self.face(at: point) : nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        clearGesture()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
        windowObserver = nil
        applicationObserver = nil
        if let newWindow {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: newWindow, queue: .main) { [weak self] _ in self?.clearGesture() }
            applicationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.clearGesture() }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func clearGesture() {
        gesture = nil
        setHover(nil)
    }

    fileprivate func accessibilityRect(for face: ViewportCubeFace) -> NSRect {
        let rect = projectedFaces.first { $0.direction == face }?.frame ?? bounds
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }
}

private final class CubeFaceAccessibilityElement: NSAccessibilityElement {
    private weak var cube: ViewportOrientationCube?
    private let face: ViewportCubeFace

    init(cube: ViewportOrientationCube, face: ViewportCubeFace) {
        self.cube = cube
        self.face = face
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(face.title) view")
        setAccessibilityIdentifier("viewportOrientationCube-\(face.rawValue)")
        setAccessibilityEnabled(true)
        setAccessibilityParent(cube)
    }

    override func accessibilityFrame() -> NSRect { cube?.accessibilityRect(for: face) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard let cube else { return false }
        cube.onSelectFace?(face)
        return true
    }
}
