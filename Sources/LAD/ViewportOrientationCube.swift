import AppKit
import simd

enum ViewportCubeFace: String, CaseIterable, Hashable {
    case front, back, left, right, top, bottom

    var title: String { rawValue.capitalized }

    var opposite: ViewportCubeFace {
        switch self {
        case .front: return .back
        case .back: return .front
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

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

    // Their cross product is the outward normal, keeping visible labels unmirrored.
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

enum ViewportCubeCorner: String, CaseIterable, Hashable {
    case leftFrontBottom, leftFrontTop, leftBackBottom, leftBackTop
    case rightFrontBottom, rightFrontTop, rightBackBottom, rightBackTop

    var signs: SIMD3<Double> {
        switch self {
        case .leftFrontBottom: return [-1, -1, -1]
        case .leftFrontTop: return [-1, -1, 1]
        case .leftBackBottom: return [-1, 1, -1]
        case .leftBackTop: return [-1, 1, 1]
        case .rightFrontBottom: return [1, -1, -1]
        case .rightFrontTop: return [1, -1, 1]
        case .rightBackBottom: return [1, 1, -1]
        case .rightBackTop: return [1, 1, 1]
        }
    }

    var direction: SIMD3<Double> { signs / sqrt(3) }
    var title: String {
        "\(signs.x < 0 ? "Left" : "Right") \(signs.y < 0 ? "front" : "back") \(signs.z < 0 ? "bottom" : "top")"
    }

    init(signs: SIMD3<Double>) {
        switch (signs.x > 0, signs.y > 0, signs.z > 0) {
        case (false, false, false): self = .leftFrontBottom
        case (false, false, true): self = .leftFrontTop
        case (false, true, false): self = .leftBackBottom
        case (false, true, true): self = .leftBackTop
        case (true, false, false): self = .rightFrontBottom
        case (true, false, true): self = .rightFrontTop
        case (true, true, false): self = .rightBackBottom
        case (true, true, true): self = .rightBackTop
        }
    }
}

enum ViewportCubeTarget: Hashable {
    case face(ViewportCubeFace)
    case oppositeFace(ViewportCubeFace)
    case corner(ViewportCubeCorner)

    fileprivate var title: String {
        switch self {
        case .face(let face): return "\(face.title) view"
        case .oppositeFace(let face): return "\(face.opposite.title) view"
        case .corner(let corner): return "\(corner.title) view"
        }
    }

    fileprivate var identifier: String {
        switch self {
        case .face(let face): return face.rawValue
        case .oppositeFace(let face): return "opposite-\(face.rawValue)"
        case .corner(let corner): return corner.rawValue
        }
    }
}

/// Both drawing and picking use this face-local geometry, in the square from -1 to 1.
private enum CubeFaceLayout {
    static let panelExtent = 0.76
    static let panelRadius = 0.38
    static let cornerRadius = 0.24
    static let cornerSigns: [SIMD2<Double>] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]

    static func corner(on face: ViewportCubeFace, signs: SIMD2<Double>) -> ViewportCubeCorner {
        ViewportCubeCorner(signs: face.normal + face.horizontal * signs.x + face.vertical * signs.y)
    }

    static func target(at point: NSPoint, on face: ViewportCubeFace) -> ViewportCubeTarget? {
        let x = abs(point.x), y = abs(point.y)
        guard x <= 1 + 1e-8, y <= 1 + 1e-8 else { return nil }
        if hypot(1 - x, 1 - y) <= cornerRadius {
            return .corner(corner(on: face, signs: [point.x < 0 ? -1 : 1, point.y < 0 ? -1 : 1]))
        }
        if x <= panelExtent, y <= panelExtent {
            let dx = max(0, x - (panelExtent - panelRadius))
            let dy = max(0, y - (panelExtent - panelRadius))
            if dx * dx + dy * dy <= panelRadius * panelRadius { return .face(face) }
        }
        return .oppositeFace(face)
    }

    static func panelPath() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: -panelExtent, y: -panelExtent,
                                         width: 2 * panelExtent, height: 2 * panelExtent),
                     xRadius: panelRadius, yRadius: panelRadius)
    }

    static func cornerPath(signs: SIMD2<Double>) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: signs.x - cornerRadius, y: signs.y - cornerRadius,
                                   width: 2 * cornerRadius, height: 2 * cornerRadius))
    }

    static func perimeterPath() -> NSBezierPath {
        let path = NSBezierPath(rect: NSRect(x: -1, y: -1, width: 2, height: 2))
        path.windingRule = .evenOdd
        for signs in cornerSigns { path.append(cornerPath(signs: signs)) }
        return path
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
        let scale: Double

        var frame: NSRect {
            let xs = points.map(\.x), ys = points.map(\.y)
            return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }

        func point(at local: NSPoint) -> NSPoint {
            NSPoint(x: center.x + scale * (horizontal.dx * local.x + vertical.dx * local.y),
                    y: center.y + scale * (horizontal.dy * local.x + vertical.dy * local.y))
        }

        func localPoint(at point: NSPoint) -> NSPoint? {
            let determinant = horizontal.dx * vertical.dy - horizontal.dy * vertical.dx
            guard scale > 0, determinant > 1e-10 else { return nil }
            let x = (point.x - center.x) / scale, y = (point.y - center.y) / scale
            return NSPoint(x: (vertical.dy * x - vertical.dx * y) / determinant,
                           y: (horizontal.dx * y - horizontal.dy * x) / determinant)
        }

        func contains(_ point: NSPoint) -> Bool {
            guard let local = localPoint(at: point) else { return false }
            return abs(local.x) <= 1 + 1e-8 && abs(local.y) <= 1 + 1e-8
        }
    }

    let faces: [Face]
    let projectedTargetCenters: [ViewportCubeTarget: NSPoint]

    init(bounds: NSRect, right: SIMD3<Double>, up: SIMD3<Double>, backward: SIMD3<Double>) {
        let safeSpan = max(0, min(bounds.width, bounds.height) - 8)
        let targetArea = safeSpan * safeSpan / 2
        let projectedNormal = simd_cross(right, up)
        let projectedArea = 4 * (abs(projectedNormal.x) + abs(projectedNormal.y) + abs(projectedNormal.z))
        // Normalize coverage instead of bounding dimensions so angled and face-on views retain the same apparent size.
        let scale = projectedArea > 1e-8 ? sqrt(targetArea / projectedArea) : 0
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
                        facing: facing, scale: scale)
        }.sorted { $0.facing < $1.facing }
        var centers: [ViewportCubeTarget: NSPoint] = [:]
        // Later, more frontal faces provide the safest shared-corner targets.
        for face in faces {
            centers[.face(face.direction)] = face.center
            centers[.oppositeFace(face.direction)] = face.point(at: NSPoint(x: 0, y: 0.88))
            for signs in CubeFaceLayout.cornerSigns {
                let corner = CubeFaceLayout.corner(on: face.direction, signs: signs)
                centers[.corner(corner)] = face.point(at: NSPoint(x: signs.x * 0.92, y: signs.y * 0.92))
            }
        }
        projectedTargetCenters = centers
    }

    func face(at point: NSPoint) -> ViewportCubeFace? {
        faces.reversed().first { $0.contains(point) }?.direction
    }

    func hitTarget(at point: NSPoint) -> ViewportCubeTarget? {
        for face in faces.reversed() {
            if let local = face.localPoint(at: point), let target = CubeFaceLayout.target(at: local, on: face.direction) {
                return target
            }
        }
        return nil
    }
}

/// A camera-synced set of face, opposite-face perimeter, and physical-corner buttons.
final class ViewportOrientationCube: NSView {
    var onSelectFace: ((ViewportCubeFace) -> Void)?
    var onSelectCorner: ((ViewportCubeCorner) -> Void)?

    private var right = SIMD3<Double>(sqrt(0.5), sqrt(0.5), 0)
    private var up = SIMD3<Double>(-1 / sqrt(6), 1 / sqrt(6), sqrt(2.0 / 3))
    private var backward = SIMD3<Double>(1 / sqrt(3), -1 / sqrt(3), 1 / sqrt(3))
    private var projection: ViewportCubeProjection?
    private var projectionBounds = NSRect.null
    private var hover: ViewportCubeTarget?
    private var pointerArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var press: Press?
    private var targetElements: [CubeTargetAccessibilityElement] = []

    private struct Press {
        let start: NSPoint
        let target: ViewportCubeTarget?
        var cancelled = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("View orientation")
        setAccessibilityIdentifier("viewportOrientationCube")
        let targets = ViewportCubeFace.allCases.map(ViewportCubeTarget.face)
            + ViewportCubeCorner.allCases.map(ViewportCubeTarget.corner)
        targetElements = targets.map { CubeTargetAccessibilityElement(cube: self, target: $0) }
        setAccessibilityChildren(targetElements)
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
        press = nil
        setHover(nil)
        needsDisplay = true
    }

    var projectedFaces: [ViewportCubeProjection.Face] { currentProjection.faces }
    var projectedTargetCenters: [ViewportCubeTarget: NSPoint] { currentProjection.projectedTargetCenters }

    func face(at point: NSPoint) -> ViewportCubeFace? { currentProjection.face(at: point) }
    func hitTarget(at point: NSPoint) -> ViewportCubeTarget? { currentProjection.hitTarget(at: point) }

    private var currentProjection: ViewportCubeProjection {
        if projection == nil || projectionBounds != bounds {
            projection = ViewportCubeProjection(bounds: bounds, right: right, up: up, backward: backward)
            projectionBounds = bounds
        }
        return projection!
    }

    override func draw(_ dirtyRect: NSRect) {
        for face in projectedFaces { draw(face) }
    }

    private func draw(_ face: ViewportCubeProjection.Face) {
        guard face.scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: face.horizontal.dx * face.scale,
            m12: face.horizontal.dy * face.scale, m21: face.vertical.dx * face.scale,
            m22: face.vertical.dy * face.scale, tX: face.center.x, tY: face.center.y)
        transform.concat()
        NSBezierPath(rect: NSRect(x: -1, y: -1, width: 2, height: 2)).addClip()

        if case .corner(let hoveredCorner) = hover {
            NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.36, alpha: 0.85).setFill()
            for signs in CubeFaceLayout.cornerSigns where CubeFaceLayout.corner(on: face.direction, signs: signs) == hoveredCorner {
                CubeFaceLayout.cornerPath(signs: signs).fill()
            }
        }

        let perimeter = CubeFaceLayout.perimeterPath()
        let brightness = 0.43 + 0.08 * simd_dot(face.direction.normal, up) + 0.04 * face.facing
        if hover == .oppositeFace(face.direction) {
            NSColor(calibratedRed: 0.71, green: 0.55, blue: 0.34, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: brightness, alpha: 1).setFill()
        }
        perimeter.fill()
        perimeter.lineWidth = 0.7 / face.scale
        NSColor(calibratedWhite: 0.22, alpha: 1).setStroke()
        NSGraphicsContext.saveGraphicsState()
        perimeter.addClip()
        perimeter.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let panel = CubeFaceLayout.panelPath()
        if hover == .face(face.direction) {
            NSColor(calibratedRed: 1, green: 0.86, blue: 0.64, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 0.85 + 0.06 * simd_dot(face.direction.normal, up), alpha: 1).setFill()
        }
        panel.fill()
        panel.lineWidth = 0.6 / face.scale
        NSColor(calibratedWhite: 1, alpha: 0.2).setStroke()
        panel.stroke()
        NSGraphicsContext.restoreGraphicsState()
        drawLabel(on: face)
    }

    private func drawLabel(on face: ViewportCubeProjection.Face) {
        guard face.facing > 0.08 else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: face.horizontal.dx, m12: face.horizontal.dy,
            m21: face.vertical.dx, m22: face.vertical.dy, tX: face.center.x, tY: face.center.y)
        transform.concat()
        let label = NSAttributedString(string: face.direction.title, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1)
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInActiveApp, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(with event: NSEvent) {
        guard press?.cancelled != true else { return }
        setHover(hitTarget(at: convert(event.locationInWindow, from: nil)))
    }

    private func setHover(_ target: ViewportCubeTarget?) {
        guard hover != target else { return }
        hover = target
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        let point = convert(event.locationInWindow, from: nil)
        press = Press(start: point, target: hitTarget(at: point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - press.start.x, point.y - press.start.y) >= 3 {
            press.cancelled = true
            self.press = press
            setHover(nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        let point = convert(event.locationInWindow, from: nil)
        let target = hitTarget(at: point)
        if !press.cancelled, hypot(point.x - press.start.x, point.y - press.start.y) < 3,
           let target, press.target == target {
            activate(target)
        }
        setHover(bounds.contains(point) ? hitTarget(at: point) : nil)
    }

    fileprivate func activate(_ target: ViewportCubeTarget) {
        switch target {
        case .face(let face): onSelectFace?(face)
        case .oppositeFace(let face): onSelectFace?(face.opposite)
        case .corner(let corner): onSelectCorner?(corner)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        clearPress()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
        windowObserver = nil
        applicationObserver = nil
        if let newWindow {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: newWindow, queue: .main) { [weak self] _ in self?.clearPress() }
            applicationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.clearPress() }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func clearPress() {
        press = nil
        setHover(nil)
    }

    fileprivate func accessibilityRect(for target: ViewportCubeTarget) -> NSRect {
        let rect: NSRect
        if let point = projectedTargetCenters[target] {
            rect = NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        } else {
            rect = bounds
        }
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }
}

private final class CubeTargetAccessibilityElement: NSAccessibilityElement {
    private weak var cube: ViewportOrientationCube?
    private let target: ViewportCubeTarget

    init(cube: ViewportOrientationCube, target: ViewportCubeTarget) {
        self.cube = cube
        self.target = target
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(target.title)
        setAccessibilityIdentifier("viewportOrientationCube-\(target.identifier)")
        setAccessibilityEnabled(true)
        setAccessibilityParent(cube)
    }

    override func accessibilityFrame() -> NSRect { cube?.accessibilityRect(for: target) ?? .zero }

    override func accessibilityPerformPress() -> Bool {
        guard let cube else { return false }
        cube.activate(target)
        return true
    }
}
