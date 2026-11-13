import AppKit
import SceneKit
import SwiftUI
import simd

enum ViewportProjectionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case perspective, isometric
    var id: String { rawValue }
}

enum ViewportDisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case shaded, edges, translucent, wireframe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shaded: return "Shaded"
        case .edges: return "Shaded + edges"
        case .translucent: return "Translucent"
        case .wireframe: return "Wireframe"
        }
    }
}

struct ViewportCommand: Equatable {
    enum Action { case fit, isometric, front, back, left, right, top, bottom }
    let id = UUID()
    let action: Action
    init(_ action: Action) { self.action = action }
}

/// Screen-space picking keeps small CAD features usable at any zoom level.
/// Tessellation vertices and triangle edges are deliberately not selectable.
enum ViewportFeaturePicking {
    struct Vertex {
        var id: CADFeatureID
        var world: SIMD3<Double>
        var screen: SIMD2<Double>
        var depth: Double
    }
    struct Edge {
        var id: CADFeatureID
        var start: Vertex
        var end: Vertex
    }

    static func pick(at point: SIMD2<Double>, vertices: [Vertex], edges: [Edge], face: @autoclosure () -> CADFeatureID?,
                     vertexTolerance: Double = 12, edgeTolerance: Double = 6,
                     orthographic: Bool = false,
                     isVisible: (SIMD3<Double>, SIMD2<Double>) -> Bool = { _, _ in true }) -> CADFeatureID? {
        let vertexHits = vertices.compactMap { vertex -> (Vertex, Double)? in
            let distance = simd_length_squared(vertex.screen - point)
            return vertex.depth > 0 && distance <= vertexTolerance * vertexTolerance ? (vertex, distance) : nil
        }.sorted {
            abs($0.1 - $1.1) > 0.01 ? $0.1 < $1.1 : $0.0.depth < $1.0.depth
        }
        for (vertex, _) in vertexHits where isVisible(vertex.world, vertex.screen) { return vertex.id }

        let edgeHits = edges.compactMap { edge -> (CADFeatureID, SIMD3<Double>, SIMD2<Double>, Double, Double)? in
            guard edge.start.depth > 0, edge.end.depth > 0 else { return nil }
            let delta = edge.end.screen - edge.start.screen
            let length = simd_length_squared(delta)
            let t = length > 1e-12 ? min(1, max(0, simd_dot(point - edge.start.screen, delta) / length)) : 0
            let screen = edge.start.screen + delta * t
            let distance = simd_length_squared(screen - point)
            guard distance <= edgeTolerance * edgeTolerance else { return nil }
            // A screen-space fraction is perspective-corrected before the
            // occlusion query; long edges can have very different end depths.
            let worldT = orthographic ? t : t * edge.start.depth / ((1 - t) * edge.end.depth + t * edge.start.depth)
            let world = edge.start.world + (edge.end.world - edge.start.world) * worldT
            let depth = edge.start.depth + (edge.end.depth - edge.start.depth) * worldT
            return (edge.id, world, screen, distance, depth)
        }.sorted {
            abs($0.3 - $1.3) > 0.01 ? $0.3 < $1.3 : $0.4 < $1.4
        }
        for (id, world, screen, _, _) in edgeHits where isVisible(world, screen) { return id }
        return face()
    }

    static func toggling(_ feature: CADFeatureID, in selection: [CADFeatureID]) -> [CADFeatureID] {
        selection.contains(feature) ? selection.filter { $0 != feature } : selection + [feature]
    }
}

struct CADViewport: NSViewRepresentable {
    var mesh: PreviewMesh?
    var displayMode: ViewportDisplayMode
    var projectionMode: ViewportProjectionMode
    var showGrid: Bool
    var command: ViewportCommand?
    var selectedSolids: Set<Int>
    var hiddenSolids: Set<Int>
    var solidColors: [Int: PartColor] = [:]
    var selectedFeatures: [CADFeatureID] = []
    var solidTransforms: [Int: [Double]] = [:]
    var onSelectionChanged: ((Set<Int>) -> Void)? = nil
    var onFeatureSelectionChanged: (([CADFeatureID]) -> Void)? = nil
    var onDeselectAll: (() -> Void)? = nil
    var onHideSelected: (() -> Void)? = nil
    var onShowAll: (() -> Void)? = nil
    var canExport = false
    var onExportFaceDXF: ((CADFeatureID) -> Void)? = nil
    var onViewReady: ((CADSceneView) -> Void)? = nil
    var assemblyGrabbingEnabled = false
    var onAssemblyGrabBegan: ((Int, [Double], AssemblyGrabProjection) -> Bool)? = nil
    var onAssemblyGrabMoved: (([Double]) -> Void)? = nil
    var onAssemblyGrabEnded: (() -> Void)? = nil
    var onAssemblyGrabCancelled: (() -> Void)? = nil

    func makeNSView(context: Context) -> CADSceneView {
        CADSceneView(frame: .zero)
    }

    func updateNSView(_ view: CADSceneView, context: Context) {
        view.onSelectionChanged = onSelectionChanged
        view.onFeatureSelectionChanged = onFeatureSelectionChanged
        view.onDeselectAll = onDeselectAll
        view.onHideSelected = onHideSelected
        view.onShowAll = onShowAll
        view.canExport = canExport
        view.onExportFaceDXF = onExportFaceDXF
        view.onActivated = onViewReady
        view.onAssemblyGrabBegan = onAssemblyGrabBegan
        view.onAssemblyGrabMoved = onAssemblyGrabMoved
        view.onAssemblyGrabEnded = onAssemblyGrabEnded
        view.onAssemblyGrabCancelled = onAssemblyGrabCancelled
        view.assemblyGrabbingEnabled = assemblyGrabbingEnabled
        view.update(mesh: mesh, mode: displayMode, grid: showGrid, command: command,
                    selectedSolids: selectedSolids, hiddenSolids: hiddenSolids, projection: projectionMode,
                    solidColors: solidColors, selectedFeatures: selectedFeatures, solidTransforms: solidTransforms)
        onViewReady?(view)
    }
}

final class CADSceneView: NSView {
    // CAD translucency fades the whole lit face, including PBR specular
    // reflections, as premultiplied color accumulated without depth testing.
    private static let translucentFragment = """
    #pragma opaque
    #pragma body
    _output.color *= \(CADTranslucency.alpha);
    """
    private static let opaqueFragment = """
    #pragma opaque
    #pragma body
    _output.color.a = 1.0;
    """
    /// Each translucent face layer multiplies the remaining transmittance.
    private static let revealageFragment = """
    #pragma body
    _output.color = float4(\(1 - CADTranslucency.alpha));
    """
    private static let selectionColor = NSColor(srgbRed: 0.92, green: 0.61, blue: 0.24, alpha: 1)
    private static let edgeInk = NSColor(srgbRed: 0.025, green: 0.035, blue: 0.05, alpha: 1)
    private static let hoveredFeatureColor = selectionColor.blended(withFraction: 0.25, of: .white) ?? selectionColor
    private static let hoveredFeatureHalo = selectionColor.blended(withFraction: 0.70, of: .white) ?? selectionColor
    /// The viewport's constant background, also composited under translucent faces.
    static let sceneBackgroundColor = NSColor(srgbRed: 0.071, green: 0.086, blue: 0.106, alpha: 1)
    static let highlightPalette = CADHighlightPalette(selected: selectionColor, hover: hoveredFeatureColor,
        hoverHalo: hoveredFeatureHalo, ink: edgeInk, background: sceneBackgroundColor)

    let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let modelNode = SCNNode()
    private let edgeNode = SCNNode()
    private let gridNode = SCNNode()
    private let featureNode = SCNNode()
    private var sceneSource: CADViewportSceneSource!
    /// The design camera. Rendering never changes it.
    var pointOfView: SCNNode? { cameraNode }
    private let device = MTLCreateSystemDefaultDevice()
    /// Shared with the render thread, which is its only renderer. Main-thread
    /// use is limited to asynchronous resource preparation.
    private lazy var renderer: SCNRenderer = {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.usesReverseZ = true
        renderer.autoenablesDefaultLighting = false
        return renderer
    }()
    private var renderLoop: ViewportRenderLoop?
    private var windowVisibilityObservation: NSKeyValueObservation?
    /// The studio lights are the scene's only illumination.
    var autoenablesDefaultLighting: Bool { renderer.autoenablesDefaultLighting }
    private var rig = CameraRig()
    private var cameraTransitionTask: Task<Void, Never>?
    private var cameraTransitionID: UUID?
    var isAnimatingCamera: Bool { cameraTransitionID != nil }
    private var loadedPath: String?
    private var loadedNativePath: String?
    private var meshBounds: [Double] = [-40, -40, 0, 40, 40, 60]
    private var lastCommand: UUID?
    private var mode: ViewportDisplayMode = .edges
    private var tracking: NSTrackingArea?
    private var zoomAnchor: SIMD3<Double>?
    private var gridVisible = true
    private var hasModel = false
    private var needsInitialFit = false
    private var selectedSolids = Set<Int>()
    private var selectedFeatures = [CADFeatureID]()
    private var hoveredFeature: CADFeatureID?
    private var hiddenSolids = Set<Int>() { didSet { resumeCaptureWaitersIfReady() } }
    private var solidColors: [Int: PartColor] = [:]
    private var ownedEdgeSolids = Set<Int>()
    private var hasOwnedEdges = false
    private var rightDownPoint: NSPoint?
    private var rightDragPoint: NSPoint?
    private var otherDragPoint: NSPoint?
    private struct AssemblyGrabGesture {
        var solid: Int
        var start: NSPoint
        var lastDelivered: NSPoint?
    }
    private var commandGrabGesture = false
    private var assemblyGrab: AssemblyGrabGesture?
    private var pointerPoint: NSPoint?
    private var commandPressed = false
    private var commandCursorSet = false
    private var modifierMonitor: Any?
    var isGrabbingAssembly: Bool { assemblyGrab != nil }
    private var rightDragging = false
    private var topology: CADTopology?
    private var solidTransforms: [Int: [Double]] = [:]
    private var solidMatrices: [Int: simd_double4x4] = [:]
    private var solidBounds: [Int: [Double]] = [:]
    private var originalMeshBounds: [Double] = []
    private var faceIDsBySolid = [Int: [CADFeatureID?]]()
    private var faceIndices = [CADFeatureID: [Int32]]()
    private var faceBounds = [CADFeatureID: CADSilhouetteBatching.Bounds]()
    private var meshSources = [SCNGeometrySource]()
    private var solidNodes = [Int: SCNNode]()
    /// Highlight geometry for the unoccluded overlay, created on first use.
    private var meshPositions: (any MTLBuffer)?
    private var partMasks = [Int: CADHighlightBuffers.Mask]()
    private var featureSeeds = [CADFeatureID: CADHighlightBuffers.Seeds]()
    private var featureMasks = [CADFeatureID: CADHighlightBuffers.Mask]()
    /// Lit face overlays drawn by the scene pass.
    private var featureNodes = [CADFeatureID: SCNNode]() { didSet { resumeCaptureWaitersIfReady() } }
    private var featureCreationOrder = [CADFeatureID]()
    /// Retained highlight resources, active or cached. Regression tests compare it.
    var cachedFeatureHighlightCount: Int { featureCreationOrder.count }
    private var featureSelectionStyles = [CADFeatureID: Bool]()
    private var preparedFeatures = Set<CADFeatureID>() { didSet { resumeCaptureWaitersIfReady() } }
    private var featurePreparationID = UUID()
    private var highlightedFeatures = [CADFeatureID]() { didSet { resumeCaptureWaitersIfReady() } }
    private var highlightedSelection = Set<CADFeatureID>()
    private struct ProjectedFeatures {
        var vertices: [ViewportFeaturePicking.Vertex]
        var edges: [ViewportFeaturePicking.Edge]
    }
    private var projectedFeatures: ProjectedFeatures?
    private var projectionSize = NSSize.zero
    private struct RenderStyle: Equatable {
        var mode: ViewportDisplayMode
        var selected: Set<Int>
        var hidden: Set<Int>
        var colors: [Int: PartColor]
    }
    private var appliedStyle: RenderStyle?
    private var resourcePreparationID = UUID()
    private var meshPreparationTask: Task<Void, Never>?
    private var pendingMesh: PreviewMesh?
    private var requestedSolidTransforms: [Int: [Double]] = [:]
    private enum PendingCamera {
        case command(ViewportCommand.Action)
        case orientation(yaw: Double, elevation: Double)
        case agent(name: String, camera: CADAgentCamera)
    }
    private var pendingCamera: PendingCamera?
    private var framePublicationScheduled = false
    private var publishedGeneration: UInt64 = 0
    /// The newest frame generation the GPU has completed in this view.
    private(set) var renderedGeneration: UInt64 = 0
    /// Frames this view has completed. Diagnostics and tests compare it.
    private(set) var renderedFrameCount = 0
    /// The design camera's world transform in the newest completed frame.
    private(set) var renderedCameraTransform: simd_float4x4?
    private var publishedCameraTransforms: [(generation: UInt64, transform: simd_float4x4)] = []
    /// True until the GPU has completed a frame showing the latest change.
    var hasPendingFrames: Bool { framePublicationScheduled || renderedGeneration < publishedGeneration }
    var onFrameRendered: (() -> Void)?
    private(set) var isPreparingResources = false {
        didSet { resumeCaptureWaitersIfReady() }
    }
    /// A detached surface that only builds scenes for independent captures.
    /// Each capture prepares its cloned scene on its own renderer, so this
    /// view does not also prepare its unused renderer's resources.
    var preparesRendererResources = true
    var hasRenderableGeometry: Bool { hasModel }
    var isPreparingCaptureResources: Bool {
        isPreparingResources || highlightedFeatures.contains {
            featureNodes[$0] != nil && !hiddenSolids.contains($0.solidIndex) && !preparedFeatures.contains($0)
        }
    }
    private var captureWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Waits without polling until capture resources are prepared. Returns
    /// false at the deadline, and throws if the waiting task is canceled.
    func waitForCaptureResources(until deadline: ContinuousClock.Instant) async throws -> Bool {
        while isPreparingCaptureResources {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return false }
            let waiter = UUID()
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                self?.resumeCaptureWaiter(waiter)
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { captureWaiters[waiter] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.resumeCaptureWaiter(waiter) }
            }
            timeout.cancel()
        }
        try Task.checkCancellation()
        return true
    }

    private func resumeCaptureWaiter(_ waiter: UUID) {
        captureWaiters.removeValue(forKey: waiter)?.resume()
    }

    /// Every input of `isPreparingCaptureResources` reports its changes here.
    /// Waiters recheck when they resume, so intermediate states are harmless.
    private func resumeCaptureWaitersIfReady() {
        guard !captureWaiters.isEmpty, !isPreparingCaptureResources else { return }
        let waiters = Array(captureWaiters.values)
        captureWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Public capture facts, read directly from the camera node that will be
    /// cloned by the renderer. Reading them never changes the user's view.
    var agentCaptureMetadata: [String: Any] {
        let pointOfView = cameraNode
        let transform = pointOfView.simdWorldTransform
        let values = (0..<4).flatMap { column in (0..<4).map { row in Double(transform[column][row]) } }
        let camera = pointOfView.camera
        return [
            "cameraTransform": values,
            "cameraTransformLayout": "column-major",
            "cameraPosition": [Double(pointOfView.simdWorldPosition.x), Double(pointOfView.simdWorldPosition.y), Double(pointOfView.simdWorldPosition.z)],
            "cameraTarget": [rig.target.x, rig.target.y, rig.target.z],
            "cameraDistance": rig.distance,
            "usesOrthographicProjection": camera?.usesOrthographicProjection ?? false,
            "orthographicScale": camera.map { Double($0.orthographicScale) } ?? rig.orthographicScale,
            "fieldOfViewDegrees": camera.map { Double($0.fieldOfView) } ?? rig.fieldOfView,
            "viewportSize": [Double(bounds.width), Double(bounds.height)],
            "backingScaleFactor": Double(window?.backingScaleFactor ?? 1),
            "display": mode.rawValue,
            "gridVisible": gridVisible,
            "hiddenSolidIndices": hiddenSolids.sorted(),
            "selectedSolidIndices": selectedSolids.sorted(),
            "solidTransformLayout": "row-major",
            "solidTransforms": solidTransforms.keys.sorted().map { ["solid": $0, "matrix": solidTransforms[$0]!] as [String: Any] },
            "selectedFeatures": selectedFeatures.map {
                ["id": $0.id, "kind": $0.kind.rawValue, "solidIndex": $0.solidIndex, "localIndex": $0.localIndex] as [String: Any]
            }
        ]
    }
    var onSelectionChanged: ((Set<Int>) -> Void)?
    var onFeatureSelectionChanged: (([CADFeatureID]) -> Void)?
    var onDeselectAll: (() -> Void)?
    var onHideSelected: (() -> Void)?
    var onShowAll: (() -> Void)?
    /// Whether the design can currently be exported; menu state only.
    var canExport = false
    var onExportFaceDXF: ((CADFeatureID) -> Void)?
    var onActivated: ((CADSceneView) -> Void)?
    var assemblyGrabbingEnabled = false {
        didSet {
            guard assemblyGrabbingEnabled != oldValue else { return }
            if !assemblyGrabbingEnabled { cancelAssemblyGrab() }
            refreshPointerFeedback()
        }
    }
    var onAssemblyGrabBegan: ((Int, [Double], AssemblyGrabProjection) -> Bool)?
    var onAssemblyGrabMoved: (([Double]) -> Void)?
    var onAssemblyGrabEnded: (() -> Void)?
    var onAssemblyGrabCancelled: (() -> Void)?
    private(set) var gridSpacing: Double = 0
    var onGridSpacingChanged: ((Double) -> Void)? {
        didSet { onGridSpacingChanged?(gridSpacing) }
    }
    var onCameraOrientationChanged: ((SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) -> Void)? {
        didSet { notifyCameraOrientation() }
    }

    var cameraOrientation: (right: SIMD3<Double>, up: SIMD3<Double>, backward: SIMD3<Double>) {
        let transform = cameraNode.simdTransform
        return (SIMD3<Double>(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
                SIMD3<Double>(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
                SIMD3<Double>(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
    }

    private func notifyCameraOrientation() {
        guard let onCameraOrientationChanged else { return }
        let orientation = cameraOrientation
        onCameraOrientationChanged(orientation.right, orientation.up, orientation.backward)
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    deinit {
        meshPreparationTask?.cancel()
        renderLoop?.stop()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = CADViewportPasses.colorFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.backgroundColor = Self.sceneBackgroundColor.cgColor
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    private func setup() {
        wantsLayer = true
        // The render thread owns the layer's contents.
        layerContentsRedrawPolicy = .never
        scene.background.contents = Self.sceneBackgroundColor
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = rig.fieldOfView
        cameraNode.camera?.projectionDirection = .vertical
        // Fit the clipping planes to the scene on every frame instead of
        // excluding geometry beyond an application-defined draw distance.
        cameraNode.camera?.automaticallyAdjustsZRange = true
        cameraNode.camera?.wantsHDR = false
        cameraNode.camera?.exposureOffset = 0
        scene.rootNode.addChildNode(cameraNode)
        sceneSource = CADViewportSceneSource.install(in: scene, camera: cameraNode)
        scene.rootNode.addChildNode(modelNode)
        scene.rootNode.addChildNode(edgeNode)
        scene.rootNode.addChildNode(gridNode)
        scene.rootNode.addChildNode(featureNode)
        modelNode.categoryBitMask = CADViewportCategory.faces
        edgeNode.categoryBitMask = CADViewportCategory.decorations
        gridNode.categoryBitMask = CADViewportCategory.decorations
        featureNode.categoryBitMask = CADViewportCategory.featureFaces
        addLight(type: .ambient, intensity: 480, color: NSColor(srgbRed: 0.63, green: 0.70, blue: 0.82, alpha: 1), parent: scene.rootNode)
        // Camera-local studio lights keep the main illumination above-right
        // and the softer fill above-left throughout orbit, pan, and zoom.
        // Surface normals still produce natural highlights on curved parts.
        addLight(type: .directional, intensity: 1_350, color: NSColor(srgbRed: 1, green: 0.96, blue: 0.87, alpha: 1),
                 parent: cameraNode, rotation: SCNVector3(-0.4, 0.35, 0))
        addLight(type: .directional, intensity: 700, color: NSColor(srgbRed: 0.62, green: 0.76, blue: 1, alpha: 1),
                 parent: cameraNode, rotation: SCNVector3(-0.15, -0.85, 0))
        rebuildGrid()
        applyCamera()
    }

    private func addLight(type: SCNLight.LightType, intensity: CGFloat, color: NSColor, parent: SCNNode, rotation: SCNVector3 = SCNVector3Zero) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = color
        node.light = light
        node.eulerAngles = rotation
        parent.addChildNode(node)
    }

    func update(mesh: PreviewMesh?, mode: ViewportDisplayMode, grid: Bool, command: ViewportCommand?,
                selectedSolids: Set<Int>, hiddenSolids: Set<Int>, projection: ViewportProjectionMode = .perspective,
                solidColors: [Int: PartColor] = [:], selectedFeatures: [CADFeatureID] = [],
                solidTransforms: [Int: [Double]] = [:]) {
        let orthographic = projection == .isometric
        let projectionChanged = rig.usesOrthographicProjection != orthographic
        let gridChanged = gridVisible != grid
        let meshChanged = mesh?.stepPath != loadedPath || mesh?.brepPath != loadedNativePath
        let visibilityChanged = self.hiddenSolids != hiddenSolids
        let modeChanged = self.mode != mode
        if meshChanged || projectionChanged {
            cancelAssemblyGrab()
            cancelCameraTransition()
        }
        if let grab = assemblyGrab, hiddenSolids.contains(grab.solid) { cancelAssemblyGrab() }
        rig.usesOrthographicProjection = orthographic
        // Selection and visibility belong to the project state, including when
        // a sidebar selection arrives before a newly installed mesh.
        self.mode = mode
        gridVisible = grid
        self.selectedSolids = selectedSolids
        var seenFeatures = Set<CADFeatureID>()
        self.selectedFeatures = selectedFeatures.filter { seenFeatures.insert($0).inserted }
        self.hiddenSolids = hiddenSolids
        if visibilityChanged {
            projectedFeatures = nil
            hoveredFeature = nil
        }
        var finishes = PartColorState.solidColors(in: mesh?.parts ?? [], overrides: [:])
        finishes.merge(solidColors.filter { (0..<4_096).contains($0.key) && $0.value.isValid },
                       uniquingKeysWith: { _, override in override })
        self.solidColors = finishes
        requestedSolidTransforms = solidTransforms
        if gridChanged { gridNode.isHidden = !grid }
        var installedModel = false
        if meshChanged {
            loadedPath = mesh?.stepPath
            loadedNativePath = mesh?.brepPath
            invalidateResourcePreparation()
            modelNode.isHidden = true
            edgeNode.isHidden = true
            appliedStyle = nil
            if let mesh {
                // Copies of a preview share its converted buffers, so a version
                // or image another view already prepared installs directly.
                let shared = CADViewportPreparedMesh.shared(for: mesh)
                if shared == nil, CADViewportPreparedMesh.requiresBackgroundPreparation(mesh) {
                    prepareMesh(mesh)
                } else if let prepared = try? shared ?? CADViewportPreparedMesh.prepareShared(mesh) {
                    install(prepared)
                    installedModel = hasModel
                } else { clearModel() }
            } else {
                clearModel()
            }
        }
        if pendingMesh != nil {
            if let command, command.id != lastCommand {
                lastCommand = command.id
                pendingCamera = .command(command.action)
            }
            if projectionChanged { applyCamera() }
            if meshChanged || projectionChanged || visibilityChanged || modeChanged || gridChanged { requestRedraw() }
            return
        }
        let poseChanged = updateSolidTransforms(solidTransforms, reinstalling: meshChanged)
        let styleChanged = applyStyle()
        let featuresChanged = updateFeatureHighlights()
        if let command, command.id != lastCommand {
            lastCommand = command.id
            perform(command.action)
        } else if projectionChanged {
            applyCamera()
        }
        // Colors and selection change existing material uniforms. They do not
        // need a new preparation pass or invalidate the one already running.
        if installedModel || (styleChanged && isPreparingResources && modeChanged) {
            prepareModelResources()
        } else {
            updateModelVisibility()
        }
        if meshChanged || poseChanged || styleChanged || featuresChanged || gridChanged { requestRedraw() }
    }

    /// Moving a rigid body changes node poses only. Display buffers, native
    /// feature identities, and materials stay attached to the original preview.
    @discardableResult
    private func updateSolidTransforms(_ requested: [Int: [Double]], reinstalling: Bool) -> Bool {
        if !reinstalling, requested == solidTransforms { return false }
        var matrices: [Int: simd_double4x4] = [:]
        let valid = requested.count <= 4_096 && requested.allSatisfy { solid, values in
            guard solidBounds[solid] != nil, let matrix = ViewportRigidTransform.matrix(values) else { return false }
            matrices[solid] = matrix
            return true
        }
        let next = valid ? requested : [:]
        guard reinstalling || next != solidTransforms else { return false }
        solidTransforms = next
        solidMatrices = valid ? matrices : [:]
        projectedFeatures = nil
        hoveredFeature = nil
        zoomAnchor = nil
        let sceneMatrices = solidMatrices.mapValues(ViewportRigidTransform.sceneMatrix)
        func apply(_ node: SCNNode, solid: Int) {
            let matrix = sceneMatrices[solid] ?? matrix_identity_float4x4
            if node.simdTransform != matrix { node.simdTransform = matrix }
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for node in modelNode.childNodes {
            if let solid = solidIndex(of: node) { apply(node, solid: solid) }
        }
        for node in edgeNode.childNodes {
            if let solid = solidIndex(of: node, prefix: "edges:") { apply(node, solid: solid) }
        }
        for (feature, node) in featureNodes { apply(node, solid: feature.solidIndex) }
        SCNTransaction.commit()
        if next.isEmpty {
            if !originalMeshBounds.isEmpty { meshBounds = originalMeshBounds }
        } else {
            let bounds = solidBounds.map { solid, bounds in
                ViewportRigidTransform.bounds(bounds, matrix: solidMatrices[solid] ?? matrix_identity_double4x4)
            }
            if !bounds.isEmpty {
                meshBounds = (0..<3).map { axis in bounds.map { $0[axis] }.min()! }
                    + (0..<3).map { axis in bounds.map { $0[axis + 3] }.max()! }
            }
        }
        if reinstalling, !next.isEmpty {
            rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
            applyCamera()
        }
        return true
    }

    private func install(_ prepared: CADViewportPreparedMesh) {
        let mesh = prepared.mesh
        appliedStyle = nil
        func makeSource(_ data: Data, semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: prepared.vertexCount,
                usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: 3 * MemoryLayout<Float>.size)
        }
        let source = makeSource(prepared.vertexData, semantic: .vertex)
        let normalSource = makeSource(prepared.normalData, semantic: .normal)
        resetFeatureResources()
        topology = mesh.topology
        meshSources = [source, normalSource]
        let groups = prepared.groups
        faceIDsBySolid = prepared.faceIDsBySolid
        faceIndices = prepared.faceIndices
        faceBounds = prepared.faceBounds
        modelNode.childNodes.forEach { $0.removeFromParentNode() }
        modelNode.geometry = nil
        solidNodes.removeAll()
        for solid in groups.keys.sorted() {
            let geometry = SCNGeometry(sources: [source, normalSource],
                                       elements: [SCNGeometryElement(indices: groups[solid]!, primitiveType: .triangles)])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = NSColor(srgbRed: 0.70, green: 0.75, blue: 0.80, alpha: 1)
            material.metalness.contents = 0.28
            material.roughness.contents = 0.42
            material.isDoubleSided = false
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = "solid:\(solid)"
            node.categoryBitMask = CADViewportCategory.faces
            modelNode.addChildNode(node)
            solidNodes[solid] = node
            // Translucent passes draw the same shared buffers with their own
            // fixed materials. Children follow the solid's pose and hiding.
            for category in [CADViewportCategory.visibility, CADViewportCategory.revealage] {
                node.addChildNode(Self.translucentCopy(of: geometry, category: category, visible: mode == .translucent))
            }
        }
        solidBounds = prepared.solidBounds
        originalMeshBounds = mesh.bounds
        installEdges(prepared)
        edgeNode.renderingOrder = 1
        meshBounds = mesh.bounds
        let first = !hasModel
        hasModel = true
        needsInitialFit = bounds.width < 10 || bounds.height < 10
        rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
        if first { rig.yaw = -.pi / 4; rig.elevation = 0.6154797087 }
        rebuildGrid()
        applyCamera()
    }

    private func clearModel() {
        invalidateResourcePreparation()
        resetFeatureResources()
        modelNode.geometry = nil
        modelNode.childNodes.forEach { $0.removeFromParentNode() }
        solidNodes.removeAll()
        edgeNode.geometry = nil
        edgeNode.childNodes.forEach { $0.removeFromParentNode() }
        ownedEdgeSolids.removeAll()
        hasOwnedEdges = false
        hasModel = false
        solidBounds.removeAll()
        originalMeshBounds.removeAll()
        solidTransforms.removeAll()
        solidMatrices.removeAll()
        appliedStyle = nil
        updateModelVisibility()
    }

    /// A depth-only or transmittance copy of a solid's faces, sharing its
    /// geometry buffers. Shown only in translucent mode.
    static func translucentCopy(of geometry: SCNGeometry, category: Int, visible: Bool) -> SCNNode {
        let copy = SCNGeometry(sources: geometry.sources, elements: geometry.elements)
        let material = SCNMaterial()
        material.isDoubleSided = true
        if category == CADViewportCategory.visibility {
            // Nearest solid depth belongs only to ordinary decorations. Highlighted
            // face overlays test against it at equal depth, so this copy shares
            // their lighting model and SceneKit's vertex transform; a constant
            // material rasterizes slightly different depths, which fight.
            material.lightingModel = .physicallyBased
            material.colorBufferWriteMask = []
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
        } else {
            // Multiplicative transmittance is independent of draw order and
            // never rejected by depth.
            material.lightingModel = .constant
            material.shaderModifiers = [.fragment: Self.revealageFragment]
            material.blendMode = .multiply
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
        }
        copy.materials = [material]
        let node = SCNNode(geometry: copy)
        node.categoryBitMask = category
        node.isHidden = !visible
        return node
    }

    /// Switches a solid's face material between opaque shading and additive
    /// translucent accumulation. Convex-only dual-layer sorting changes with
    /// the view on CAD shells. Translucent faces instead add premultiplied
    /// color without depth testing, so every contribution is independent of
    /// object and triangle submission order; depth-only and transmittance
    /// copies supply decoration occlusion and coverage.
    static func configureFaceMaterial(_ material: SCNMaterial, translucent: Bool) {
        material.transparency = 1
        material.shaderModifiers = [.fragment: translucent ? translucentFragment : opaqueFragment]
        material.transparencyMode = .aOne
        material.blendMode = translucent ? .add : .alpha
        material.writesToDepthBuffer = !translucent
        material.readsFromDepthBuffer = !translucent
        material.isDoubleSided = translucent
    }

    private func invalidateResourcePreparation() {
        meshPreparationTask?.cancel()
        meshPreparationTask = nil
        pendingMesh = nil
        pendingCamera = nil
        resourcePreparationID = UUID()
        isPreparingResources = false
    }

    private func prepareMesh(_ mesh: PreviewMesh) {
        let token = UUID()
        resourcePreparationID = token
        pendingMesh = mesh
        isPreparingResources = true
        updateModelVisibility()
        meshPreparationTask = Task { @MainActor [weak self] in
            do {
                let prepared = try await CADViewportPreparedMesh.prepareSharedInBackground(mesh)
                guard !Task.isCancelled, let self, self.resourcePreparationID == token else { return }
                self.meshPreparationTask = nil
                self.pendingMesh = nil
                guard let prepared else { self.clearModel(); self.requestRedraw(); return }
                self.install(prepared)
                _ = self.updateSolidTransforms(self.requestedSolidTransforms, reinstalling: true)
                _ = self.applyStyle()
                _ = self.updateFeatureHighlights()
                let camera = self.pendingCamera
                self.pendingCamera = nil
                switch camera {
                case .command(let action): self.perform(action)
                case .orientation(let yaw, let elevation):
                    var destination = self.rig
                    destination.yaw = yaw; destination.elevation = elevation
                    self.fitOrientationCubeView(destination)
                case .agent(let name, let camera): try self.configureAgentView(named: name, camera: camera)
                case nil: break
                }
                self.prepareModelResources()
                self.requestRedraw()
            } catch {
                guard let self, self.resourcePreparationID == token else { return }
                self.clearModel()
                self.requestRedraw()
            }
        }
    }

    private func prepareModelResources() {
        guard pendingMesh == nil, hasModel else { return }
        let token = UUID()
        resourcePreparationID = token
        guard preparesRendererResources else {
            isPreparingResources = false
            updateModelVisibility()
            return
        }
        isPreparingResources = true
        updateModelVisibility()
        // Upload geometry and prepare the material/light pipelines before the
        // model is revealed, rather than compiling on the first orbit frame.
        // The renderer's asynchronous overload performs this work off the UI
        // thread, on the renderer the render thread draws with. Including the
        // scene root gives it the complete light setup. Keep the view alive
        // through completion, then release its final capture on the main
        // queue even if the containing SwiftUI view has been removed.
        renderer.prepare([scene.rootNode], completionHandler: { [self] _ in
            DispatchQueue.main.async {
                guard self.resourcePreparationID == token else { return }
                self.isPreparingResources = false
                // Even if preparation fails, let SceneKit attempt its normal
                // rendering path rather than leaving the model hidden.
                self.updateModelVisibility()
                self.requestRedraw()
            }
        })
    }

    private func updateModelVisibility() {
        let hidden = !hasModel || isPreparingResources
        if modelNode.isHidden != hidden { modelNode.isHidden = hidden }
        let edgesHidden = hidden || mode == .shaded
        if edgeNode.isHidden != edgesHidden { edgeNode.isHidden = edgesHidden }
        if featureNode.isHidden != hidden { featureNode.isHidden = hidden }
    }

    private func resetFeatureResources() {
        featurePreparationID = UUID()
        hoveredFeature = nil
        projectedFeatures = nil
        featureNode.childNodes.forEach { $0.removeFromParentNode() }
        featureNodes.removeAll()
        featureSeeds.removeAll()
        featureMasks.removeAll()
        partMasks.removeAll()
        meshPositions = nil
        featureCreationOrder.removeAll()
        featureSelectionStyles.removeAll()
        preparedFeatures.removeAll()
        highlightedFeatures.removeAll()
        highlightedSelection.removeAll()
        faceIDsBySolid.removeAll()
        faceIndices.removeAll()
        faceBounds.removeAll()
        meshSources.removeAll()
        topology = nil
    }

    @discardableResult
    private func updateFeatureHighlights() -> Bool {
        let selected = Set(selectedFeatures)
        var active = selectedFeatures
        if let hoveredFeature, !selected.contains(hoveredFeature), !selectedSolids.contains(hoveredFeature.solidIndex) {
            active.append(hoveredFeature)
        }
        var changed = highlightedFeatures != active || highlightedSelection != selected
        highlightedFeatures = active
        highlightedSelection = selected
        var newNodes = [(CADFeatureID, SCNNode)]()
        for feature in active where featureNodes[feature] == nil && featureSeeds[feature] == nil {
            switch feature.kind {
            case .face:
                guard let geometry = featureGeometry(for: feature), let mask = faceMask(feature) else { continue }
                let node = SCNNode(geometry: geometry)
                node.name = "feature:\(feature.kind.rawValue):\(feature.solidIndex):\(feature.localIndex)"
                node.categoryBitMask = CADViewportCategory.featureFaces
                node.renderingOrder = 3
                node.isHidden = true
                node.simdTransform = ViewportRigidTransform.sceneMatrix(solidMatrices[feature.solidIndex] ?? matrix_identity_double4x4)
                featureNode.addChildNode(node)
                featureNodes[feature] = node
                featureMasks[feature] = mask
                newNodes.append((feature, node))
            case .edge, .vertex:
                // Overlay buffers need no renderer preparation.
                guard let seeds = seedBuffer(for: feature) else { continue }
                featureSeeds[feature] = seeds
                preparedFeatures.insert(feature)
            }
            featureCreationOrder.append(feature)
            changed = true
        }
        let activeSet = Set(active)
        // Hover can visit every face in a large assembly. Retain selected and
        // active overlays, with only a small cache of inactive drawing resources.
        var excess = featureCreationOrder.count - (activeSet.count + 64)
        if excess > 0 {
            var evicted = Set<CADFeatureID>()
            for feature in featureCreationOrder where excess > 0 && !activeSet.contains(feature) {
                featureNodes.removeValue(forKey: feature)?.removeFromParentNode()
                featureSeeds.removeValue(forKey: feature)
                featureMasks.removeValue(forKey: feature)
                featureSelectionStyles.removeValue(forKey: feature)
                preparedFeatures.remove(feature)
                evicted.insert(feature)
                excess -= 1
            }
            featureCreationOrder.removeAll { evicted.contains($0) }
        }
        for (feature, node) in featureNodes {
            let isSelected = selected.contains(feature)
            if featureSelectionStyles[feature] != isSelected {
                node.geometry?.firstMaterial?.diffuse.contents = isSelected ? Self.selectionColor : Self.hoveredFeatureColor
                featureSelectionStyles[feature] = isSelected
                changed = true
            }
            let hidden = !activeSet.contains(feature) || hiddenSolids.contains(feature.solidIndex) || !preparedFeatures.contains(feature)
            if node.isHidden != hidden { node.isHidden = hidden; changed = true }
        }
        if !newNodes.isEmpty {
            let token = featurePreparationID
            // Hover and selection reuse preview geometry. Upload an overlay once,
            // without delaying the scene or rebuilding CAD geometry.
            renderer.prepare(newNodes.map(\.1), completionHandler: { [self] _ in
                DispatchQueue.main.async {
                    guard self.featurePreparationID == token else { return }
                    // A quickly visited hover overlay may have been evicted
                    // and recreated while its first upload was still pending.
                    for (feature, node) in newNodes where self.featureNodes[feature] === node {
                        self.preparedFeatures.insert(feature)
                    }
                    self.updateFeatureHighlights()
                    self.requestRedraw()
                }
            })
        }
        return changed
    }

    /// The lit overlay a highlighted face adds to the scene pass.
    private func featureGeometry(for feature: CADFeatureID) -> SCNGeometry? {
        guard feature.kind == .face, let indices = faceIndices[feature], !indices.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: meshSources,
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = Self.selectionColor
        material.transparencyMode = .singleLayer
        material.metalness.contents = 0.28
        material.roughness.contents = 0.42
        material.emission.contents = NSColor(srgbRed: 0.12, green: 0.05, blue: 0.005, alpha: 1)
        material.isDoubleSided = false
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    /// Native edge centerlines or a vertex center for the unoccluded overlay.
    private func seedBuffer(for feature: CADFeatureID) -> CADHighlightBuffers.Seeds? {
        guard let topology, let device else { return nil }
        func point(_ value: [Double]) -> SIMD3<Float> { SIMD3(Float(value[0]), Float(value[1]), Float(value[2])) }
        switch feature.kind {
        case .edge:
            guard let edge = topology.edges.first(where: { $0.id == feature }) else { return nil }
            let points = edge.polyline.filter { validFeaturePoint($0) }.map(point)
            guard points.count > 1 else { return nil }
            var segments = [SIMD3<Float>]()
            segments.reserveCapacity((points.count - 1) * 2)
            for (start, end) in zip(points, points.dropFirst()) { segments += [start, end] }
            return CADHighlightBuffers.Seeds(device: device, points: segments, primitive: .line)
        case .vertex:
            guard let vertex = topology.vertices.first(where: { $0.id == feature }), validFeaturePoint(vertex.position) else { return nil }
            return CADHighlightBuffers.Seeds(device: device, points: [point(vertex.position)], primitive: .point)
        case .face:
            return nil
        }
    }

    /// The preview's positions, uploaded once for projected outline masks.
    private func highlightPositions() -> (any MTLBuffer)? {
        if let meshPositions { return meshPositions }
        guard let device, let data = meshSources.first?.data, !data.isEmpty else { return nil }
        meshPositions = data.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: data.count, options: .storageModeShared) }
        }
        return meshPositions
    }

    /// A face's filled projection plus its triangle edges, so a face viewed
    /// edge-on keeps a line projection that filled coverage would drop.
    private func faceMask(_ feature: CADFeatureID) -> CADHighlightBuffers.Mask? {
        guard let device, let positions = highlightPositions(), let indices = faceIndices[feature], !indices.isEmpty else { return nil }
        return CADHighlightBuffers.Mask(device: device, positions: positions,
                                        triangleIndices: indices.withUnsafeBufferPointer { Data(buffer: $0) }, includeLines: true)
    }

    /// A selected part's filled projection, sharing its scene geometry indices.
    private func partMask(_ solid: Int) -> CADHighlightBuffers.Mask? {
        if let mask = partMasks[solid] { return mask }
        guard let device, let positions = highlightPositions(),
              let element = solidNodes[solid]?.geometry?.elements.first, element.bytesPerIndex == MemoryLayout<Int32>.size,
              let mask = CADHighlightBuffers.Mask(device: device, positions: positions, triangleIndices: element.data,
                                                  includeLines: false) else { return nil }
        partMasks[solid] = mask
        return mask
    }

    /// Highlight geometry and parameters for one frame of `width`×`height`
    /// pixels. Captures call this with their own output size.
    func makeFrame(width: Int, height: Int) -> CADViewportFrame {
        var frame = CADViewportFrame(width: width, height: height, referenceHeight: Double(bounds.height),
                                     translucent: mode == .translucent, palette: Self.highlightPalette)
        guard hasModel, !isPreparingResources, width > 0, height > 0 else { return frame }
        let projection = assemblyGrabProjection(viewportSize: CGSize(width: width, height: height))
        let pixels = SIMD2(Double(width), Double(height))
        var area: CADSilhouetteBatching.Rect?
        func include(_ rect: CADSilhouetteBatching.Rect) { area = area.map { $0.union(rect) } ?? rect }
        func model(_ solid: Int) -> simd_float4x4 {
            ViewportRigidTransform.sceneMatrix(solidMatrices[solid] ?? matrix_identity_double4x4)
        }
        // A missing projection conservatively covers the whole frame; a box
        // entirely behind the eye or outside the frame contributes nothing.
        func project(_ bounds: [Double], _ transform: simd_float4x4) -> CADSilhouetteBatching.Rect? {
            guard let projection else { return .full }
            return CADSilhouetteBatching.project(bounds: bounds, transform: transform, projection: projection, pixels: pixels)
        }
        let selected = highlightedSelection
        for feature in highlightedFeatures where feature.kind != .face && !hiddenSolids.contains(feature.solidIndex) {
            guard preparedFeatures.contains(feature), let seeds = featureSeeds[feature] else { continue }
            let transform = model(feature.solidIndex)
            guard let rect = project(seeds.bounds, transform) else { continue }
            include(rect)
            let isSelected = selected.contains(feature)
            let channel: CADViewportFrame.SeedChannel = feature.kind == .edge
                ? (isSelected ? .selectedEdge : .hoveredEdge)
                : (isSelected ? .selectedVertex : .hoveredVertex)
            frame.seeds.append(.init(buffer: seeds, channel: channel, model: transform))
        }
        var masks = [CADViewportFrame.Mask](), rectangles = [CADSilhouetteBatching.Rect?]()
        for solid in selectedSolids.sorted() where !hiddenSolids.contains(solid) {
            guard let mask = partMask(solid) else { continue }
            let transform = model(solid)
            masks.append(.init(buffer: mask, selected: true, model: transform))
            rectangles.append(project(solidBounds[solid] ?? originalMeshBounds, transform))
        }
        for feature in highlightedFeatures where feature.kind == .face && !hiddenSolids.contains(feature.solidIndex) {
            guard preparedFeatures.contains(feature), let mask = featureMasks[feature] else { continue }
            let transform = model(feature.solidIndex)
            masks.append(.init(buffer: mask, selected: selected.contains(feature), model: transform))
            rectangles.append(project(faceBounds[feature]?.values ?? solidBounds[feature.solidIndex] ?? originalMeshBounds, transform))
        }
        // Disjoint masks share one projection and contour pass; overlapping
        // masks keep separate passes so nested parts keep their own outline.
        for batch in CADSilhouetteBatching.make(rectangles) {
            include(batch.rect)
            frame.batches.append(.init(rect: batch.rect, masks: batch.items.map { masks[$0] }))
        }
        frame.highlightBounds = area
        frame.verticesEnabled = highlightedFeatures.contains { $0.kind == .vertex && !hiddenSolids.contains($0.solidIndex) }
        return frame
    }

    private func validFeaturePoint(_ point: [Double]) -> Bool {
        point.count == 3 && point.allSatisfy { $0.isFinite && abs($0) < 1e12 }
    }

    private func installEdges(_ prepared: CADViewportPreparedMesh) {
        edgeNode.geometry = nil
        edgeNode.childNodes.forEach { $0.removeFromParentNode() }
        ownedEdgeSolids.removeAll()
        hasOwnedEdges = prepared.hasOwnedEdges
        for solid in prepared.edges.keys.sorted() {
            let node = SCNNode(geometry: CADStrokeGeometry.make(prepared.edges[solid]!, color: Self.edgeInk,
                viewportHeight: bounds.height))
            node.name = solid < 0 ? "legacy-edges" : "edges:\(solid)"
            node.categoryBitMask = CADViewportCategory.decorations
            node.renderingOrder = 1
            node.geometry?.firstMaterial?.writesToDepthBuffer = false
            node.geometry?.firstMaterial?.isDoubleSided = true
            edgeNode.addChildNode(node)
            if solid >= 0 { ownedEdgeSolids.insert(solid) }
        }
    }

    @discardableResult
    private func applyStyle() -> Bool {
        let style = RenderStyle(mode: mode, selected: selectedSolids, hidden: hiddenSolids, colors: solidColors)
        guard appliedStyle != style else { return false }
        let previous = appliedStyle
        appliedStyle = style
        let translucent = mode == .translucent
        let coloredLegacyWire = !hasOwnedEdges && mode == .wireframe && !solidColors.isEmpty
        let selectionColor = Self.selectionColor
        for node in edgeNode.childNodes {
            let solid = solidIndex(of: node, prefix: "edges:")
            let hidden = solid.map { hiddenSolids.contains($0) } ?? (!hiddenSolids.isEmpty || coloredLegacyWire)
            if let previous, previous.mode == mode,
               (solid.map { previous.hidden.contains($0) } ?? (!previous.hidden.isEmpty ||
                    (!hasOwnedEdges && previous.mode == .wireframe && !previous.colors.isEmpty))) == hidden,
               mode != .wireframe || solid.map({ previous.colors[$0] == solidColors[$0] }) != false {
                continue
            }
            // Older projects have one combined edge buffer. Never keep that
            // buffer visible after hiding a part, since its lines include it.
            node.isHidden = hidden
            node.geometry?.firstMaterial?.diffuse.contents = mode == .wireframe ? solid.flatMap { assignedColor(for: $0) } ?? NSColor(srgbRed: 0.70, green: 0.75, blue: 0.80, alpha: 1)
                : Self.edgeInk
            node.geometry?.firstMaterial?.readsFromDepthBuffer = mode != .wireframe
            node.geometry?.firstMaterial?.transparency = translucent ? 0.8 : 1
        }
        for node in modelNode.childNodes {
            guard let solid = solidIndex(of: node) else { continue }
            let selected = selectedSolids.contains(solid)
            if let previous, previous.mode == mode,
               previous.selected.contains(solid) == selected,
               previous.hidden.contains(solid) == hiddenSolids.contains(solid),
               selected || previous.colors[solid] == solidColors[solid],
               hasOwnedEdges || (previous.hidden.isEmpty == hiddenSolids.isEmpty && previous.colors.isEmpty == solidColors.isEmpty) {
                continue
            }
            // Native analytic wire edges are preferred. Fall back to each
            // solid's triangle wireframe when edge ownership is unavailable,
            // so hidden legacy solids cannot leave ghost edges behind.
            let needsTriangleWire = hasOwnedEdges ? !ownedEdgeSolids.contains(solid)
                : !hiddenSolids.isEmpty || coloredLegacyWire || edgeNode.childNodes.isEmpty
            node.isHidden = hiddenSolids.contains(solid) || (mode == .wireframe && !needsTriangleWire)
            node.geometry?.firstMaterial?.fillMode = mode == .wireframe ? .lines : .fill
            // Let interior parts show through the filled surfaces. Restore
            // depth writing and opaque materials when leaving this mode.
            if let material = node.geometry?.firstMaterial { Self.configureFaceMaterial(material, translucent: translucent) }
            for copy in node.childNodes where copy.isHidden == translucent { copy.isHidden = !translucent }
            node.geometry?.firstMaterial?.diffuse.contents = selected && mode != .wireframe
                ? selectionColor
                : assignedColor(for: solid) ?? NSColor(srgbRed: 0.70, green: 0.75, blue: 0.80, alpha: 1)
            node.geometry?.firstMaterial?.emission.contents = selected && mode != .wireframe
                ? NSColor(srgbRed: 0.12, green: 0.05, blue: 0.005, alpha: 1) : NSColor.black
        }
        return true
    }

    private func assignedColor(for solid: Int) -> NSColor? {
        guard let color = solidColors[solid] else { return nil }
        return NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    }

    private func solidIndex(of node: SCNNode, prefix: String = "solid:") -> Int? {
        guard let name = node.name, name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    private func lineGeometry(_ segments: [[Double]], color: NSColor) -> SCNGeometry {
        var vertices = [SCNVector3]()
        vertices.reserveCapacity(segments.count * 2)
        for s in segments {
            vertices.append(SCNVector3(s[0], s[1], s[2]))
            vertices.append(SCNVector3(s[3], s[4], s[5]))
        }
        let element = SCNGeometryElement(indices: Array(0..<Int32(vertices.count)), primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        // Only solid faces write visibility depth; guides read it.
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private func rebuildGrid() {
        gridNode.childNodes.forEach { $0.removeFromParentNode() }
        let extent = max(rig.radius * 2.8, 1)
        let ideal = extent / 16
        let scale = pow(10, floor(log10(ideal)))
        let step = (ideal / scale < 2 ? 1.0 : ideal / scale < 5 ? 2.0 : 5.0) * scale
        let count = Int(ceil(extent / step))
        // The view's reference frame follows the model's geometric center.
        // This only positions guides; CAD vertices and part coordinates stay
        // untouched, including models imported far from CAD world zero.
        let center = rig.orbitCenter
        let centerX = center.x
        let centerY = center.y
        let z = meshBounds[2] - max(rig.radius * 0.0005, 0.0001)
        var minor = [[Double]]()
        var major = [[Double]]()
        for i in -count...count {
            let p = Double(i) * step
            let lines = [[centerX + p, centerY - extent, z, centerX + p, centerY + extent, z],
                         [centerX - extent, centerY + p, z, centerX + extent, centerY + p, z]]
            if i % 5 == 0 { major.append(contentsOf: lines) } else { minor.append(contentsOf: lines) }
        }
        gridNode.addChildNode(SCNNode(geometry: lineGeometry(minor, color: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.19, alpha: 1))))
        gridNode.addChildNode(SCNNode(geometry: lineGeometry(major, color: NSColor(srgbRed: 0.18, green: 0.21, blue: 0.25, alpha: 1))))
        // Guides must not intercept solid selection or cursor zoom hit tests.
        // They draw after the faces whose depth they read.
        for node in gridNode.childNodes {
            node.categoryBitMask = CADViewportCategory.decorations
            node.renderingOrder = 1
        }
        gridNode.isHidden = !gridVisible
        if gridSpacing != step {
            gridSpacing = step
            onGridSpacingChanged?(step)
        }
    }

    private func perform(_ action: ViewportCommand.Action) {
        if pendingMesh != nil { pendingCamera = .command(action); return }
        cancelCameraTransition()
        switch action {
        case .fit:
            zoomAnchor = nil
            rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
        case .isometric: rig.yaw = -.pi / 4; rig.elevation = 0.6154797087
        case .front: rig.yaw = -.pi / 2; rig.elevation = 0
        case .back: rig.yaw = .pi / 2; rig.elevation = 0
        case .left: rig.yaw = .pi; rig.elevation = 0
        case .right: rig.yaw = 0; rig.elevation = 0
        case .top: rig.yaw = -.pi / 2; rig.elevation = .pi / 2 - 0.00001
        case .bottom: rig.yaw = -.pi / 2; rig.elevation = -.pi / 2 + 0.00001
        }
        applyCamera()
    }

    func selectOrientationCubeFace(_ face: ViewportCubeFace) {
        var destination = rig
        switch face {
        case .front: destination.yaw = -.pi / 2; destination.elevation = 0
        case .back: destination.yaw = .pi / 2; destination.elevation = 0
        case .left: destination.yaw = .pi; destination.elevation = 0
        case .right: destination.yaw = 0; destination.elevation = 0
        case .top: destination.yaw = -.pi / 2; destination.elevation = .pi / 2 - 0.00001
        case .bottom: destination.yaw = -.pi / 2; destination.elevation = -.pi / 2 + 0.00001
        }
        fitOrientationCubeView(destination)
    }

    func selectOrientationCubeCorner(_ corner: ViewportCubeCorner) {
        var destination = rig
        let direction = corner.direction
        destination.yaw = atan2(direction.y, direction.x)
        destination.elevation = asin(direction.z)
        fitOrientationCubeView(destination)
    }

    private func fitOrientationCubeView(_ destination: CameraRig) {
        cancelAssemblyGrab()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        cancelCameraTransition()
        if pendingMesh != nil {
            pendingCamera = .orientation(yaw: destination.yaw, elevation: destination.elevation)
            return
        }
        zoomAnchor = nil
        var destination = destination
        destination.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
        // Activation and occlusion notifications can lag the click that
        // brings a design window forward. Do not let those bits skip motion.
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            rig = destination
            applyCamera()
            return
        }
        let transition = CameraTransition(from: rig, to: destination)
        let token = UUID()
        cameraTransitionID = token
        cameraTransitionTask = Task { @MainActor [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let progress = min((ProcessInfo.processInfo.systemUptime - started) / 0.32, 1)
                // The rig, picker and cube all follow the same pose, rather
                // than diverging from a SceneKit-only presentation animation.
                guard self?.advanceCameraTransition(transition, token: token, progress: progress) == true else { return }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        requestRedraw()
    }

    private func advanceCameraTransition(_ transition: CameraTransition, token: UUID, progress: Double) -> Bool {
        guard cameraTransitionID == token else { return false }
        rig = transition.rig(at: progress)
        applyCamera()
        // An orientation observer may have started another transition.
        guard cameraTransitionID == token else { return false }
        if progress >= 1 {
            cameraTransitionID = nil
            cameraTransitionTask = nil
            return false
        }
        return true
    }

    private func cancelCameraTransition() {
        if case .orientation = pendingCamera { pendingCamera = nil }
        cameraTransitionID = nil
        cameraTransitionTask?.cancel()
        cameraTransitionTask = nil
    }

    /// Used only by an independent offscreen tool view. The live viewport's
    /// camera and project display preferences are never changed by rendering.
    func configureAgentView(named name: String, camera: CADAgentCamera = CADAgentCamera()) throws {
        cancelAssemblyGrab()
        cancelCameraTransition()
        if let pendingMesh {
            // Preserve callers that configure an independent view immediately
            // after supplying a large preview. Resolve the final pose only once
            // validated bounds and current rigid placements have been installed.
            _ = try camera.resolved(view: name, bounds: pendingMesh.bounds, width: Double(bounds.width),
                                    height: Double(bounds.height), orthographic: rig.usesOrthographicProjection)
            pendingCamera = .agent(name: name, camera: camera)
            return
        }
        var fittingBounds = meshBounds
        if !hiddenSolids.isEmpty {
            let visible = solidBounds.compactMap { solid, bounds -> [Double]? in
                guard !hiddenSolids.contains(solid) else { return nil }
                return ViewportRigidTransform.bounds(bounds, matrix: solidMatrices[solid] ?? matrix_identity_double4x4)
            }
            if !visible.isEmpty {
                fittingBounds = (0..<3).map { axis in visible.map { $0[axis] }.min()! }
                    + (0..<3).map { axis in visible.map { $0[axis + 3] }.max()! }
            }
        }
        let pose = try camera.resolved(view: name, bounds: fittingBounds, width: Double(bounds.width),
                                       height: Double(bounds.height), orthographic: rig.usesOrthographicProjection)
        rig = pose.rig
        needsInitialFit = false
        projectedFeatures = nil
        setHoveredFeature(nil)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        cameraNode.simdTransform = simd_float4x4(columns: (
            SIMD4(SIMD3<Float>(pose.right), 0), SIMD4(SIMD3<Float>(pose.up), 0),
            SIMD4(SIMD3<Float>(pose.backward), 0), SIMD4(SIMD3<Float>(pose.position), 1)))
        cameraNode.camera?.usesOrthographicProjection = rig.usesOrthographicProjection
        cameraNode.camera?.orthographicScale = pose.orthographicScale
        sceneSource.synchronizeCameras()
        SCNTransaction.commit()
        notifyCameraOrientation()
        requestRedraw()
    }

    private func applyCamera() {
        cancelAssemblyGrab()
        projectedFeatures = nil
        setHoveredFeature(nil)
        let right = SIMD3<Float>(rig.right)
        let up = SIMD3<Float>(rig.up)
        let backward = SIMD3<Float>(rig.backward)
        let position = SIMD3<Float>(rig.position)
        // Commit the camera atomically without implicit animation. This
        // keeps pointer motion immediate without flushing unrelated changes.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        cameraNode.simdTransform = simd_float4x4(columns: (
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(backward, 0), SIMD4(position, 1)))
        if cameraNode.camera?.usesOrthographicProjection != rig.usesOrthographicProjection {
            cameraNode.camera?.usesOrthographicProjection = rig.usesOrthographicProjection
        }
        if cameraNode.camera?.orthographicScale != rig.orthographicScale {
            cameraNode.camera?.orthographicScale = rig.orthographicScale
        }
        sceneSource?.synchronizeCameras()
        SCNTransaction.commit()
        notifyCameraOrientation()
        requestRedraw()
    }

    override func layout() {
        super.layout()
        let sizeChanged = projectionSize != bounds.size
        if sizeChanged {
            cancelAssemblyGrab()
            cancelCameraTransition()
            projectionSize = bounds.size
            projectedFeatures = nil
            setHoveredFeature(nil)
            updateStrokeViewportHeight()
        }
        if needsInitialFit, bounds.width >= 10, bounds.height >= 10 {
            cancelCameraTransition()
            needsInitialFit = false
            rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
            applyCamera()
        }
        if sizeChanged { requestRedraw() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        requestRedraw()
    }

    /// Publishes the view's state to the render thread once per main-queue
    /// turn, however many changes that turn made. The render thread draws
    /// exactly the frames published; nothing renders while nothing changes.
    private func requestRedraw() {
        guard !framePublicationScheduled else { return }
        framePublicationScheduled = true
        DispatchQueue.main.async { [weak self] in self?.publishFrame() }
    }

    private func publishFrame() {
        framePublicationScheduled = false
        // Changes made while the window cannot draw are published when it is
        // revealed or deminiaturized.
        guard canDrawViewport, let loop = renderLoop ?? startRenderLoop() else { return }
        let size = convertToBacking(bounds).size
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return }
        // Commit this turn's implicit scene changes before the render thread
        // reads the scene, so the frame shows all of them together.
        SCNTransaction.flush()
        publishedGeneration &+= 1
        publishedCameraTransforms.append((publishedGeneration, cameraNode.simdWorldTransform))
        if publishedCameraTransforms.count > 16 { publishedCameraTransforms.removeFirst() }
        loop.submit(.init(frame: makeFrame(width: width, height: height), source: sceneSource,
                          generation: publishedGeneration))
    }

    private func startRenderLoop() -> ViewportRenderLoop? {
        guard renderLoop == nil, let layer = layer as? CAMetalLayer else { return renderLoop }
        renderLoop = ViewportRenderLoop(layer: layer, renderer: renderer) { [weak self] generation in
            MainActor.assumeIsolated { self?.frameCompleted(generation) }
        }
        return renderLoop
    }

    private func frameCompleted(_ generation: UInt64) {
        renderedFrameCount += 1
        renderedGeneration = max(renderedGeneration, generation)
        if let published = publishedCameraTransforms.last(where: { $0.generation == generation }) {
            renderedCameraTransform = published.transform
        }
        publishedCameraTransforms.removeAll { $0.generation <= generation }
        onFrameRendered?()
    }

    private var canDrawViewport: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return false }
        // Direct input and window captures can arrive while AppKit's occlusion
        // state is stale, so occlusion alone never suppresses a frame.
        return true
    }

    private func updateStrokeViewportHeight() {
        for node in edgeNode.childNodes {
            if let geometry = node.geometry { CADStrokeGeometry.setViewportHeight(bounds.height, on: geometry) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        trackPointer(with: event)
        updatePointerCursor()
    }
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateModifiers(with: event)
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancelAssemblyGrab(); setHoveredFeature(nil) }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        clearPointerFeedback()
        cancelAssemblyGrab()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
        windowVisibilityObservation = nil
        setHoveredFeature(nil)
        resetNavigationGesture()
        cancelCameraTransition()
        if newWindow == nil {
            renderLoop?.cancelPending()
            if pendingMesh != nil {
                // Retain the requested input for reattachment, but discard work
                // and completions owned by the detached rendering surface.
                resourcePreparationID = UUID()
                meshPreparationTask?.cancel()
                meshPreparationTask = nil
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            layer?.contentsScale = window.backingScaleFactor
            if let pendingMesh, meshPreparationTask == nil { prepareMesh(pendingMesh) }
            window.acceptsMouseMovedEvents = true
            // Modifier events go to the first responder, which may be the
            // composer even while the pointer is over this viewport.
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.updateModifiers(with: event) }
                return event
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            // Ordering a window in or out changes this synchronously, while
            // occlusion notifications arrive later through the event loop.
            windowVisibilityObservation = window.observe(\.isVisible) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    if window.isVisible { self?.requestRedraw() }
                }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowDeminiaturized),
                                                   name: NSWindow.didDeminiaturizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportEnvironmentWoke),
                                                   name: NSApplication.didBecomeActiveNotification, object: NSApp)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportEnvironmentWoke),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(viewportEnvironmentWoke),
                                                              name: NSWorkspace.didWakeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(viewportEnvironmentWoke),
                                                              name: NSWorkspace.screensDidWakeNotification, object: nil)
            if window.isKeyWindow { onActivated?(self) }
            requestRedraw()
        } else {
            renderLoop?.cancelPending()
        }
    }

    @objc private func windowResignedKey() {
        clearPointerFeedback()
        cancelAssemblyGrab()
        cancelCameraTransition()
        setHoveredFeature(nil)
        resetNavigationGesture()
    }
    @objc private func windowBecameKey() {
        onActivated?(self)
        requestRedraw()
    }
    @objc private func windowDeminiaturized() { requestRedraw() }

    @objc private func windowVisibilityChanged() {
        if window?.occlusionState.contains(.visible) == true {
            requestRedraw()
        } else {
            cancelAssemblyGrab()
            cancelCameraTransition()
        }
    }

    /// Display and color changes, activation and wake redraw the current
    /// state once; idle views otherwise draw nothing.
    @objc private func viewportEnvironmentWoke() {
        cancelAssemblyGrab()
        guard window != nil else { return }
        requestRedraw()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { clearPointerFeedback() }

    private func ownsPointer(_ point: NSPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return false }
        guard let window else { return true }
        guard let content = window.contentView,
              let hit = content.hitTest(convert(point, to: content.superview)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func trackPointer(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerPoint = ownsPointer(point) ? point : nil
        commandPressed = event.modifierFlags.contains(.command)
    }

    private func updateModifiers(with event: NSEvent) {
        if let window {
            guard window.isKeyWindow, NSApp.isActive, event.window == nil || event.window === window else { return }
            // A key event's location can be stale. Query the pointer and hit
            // target so overlays and the composer retain their own cursors.
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let owned = ownsPointer(point) ? point : nil
            let pressed = event.modifierFlags.contains(.command)
            guard pressed != commandPressed || owned != pointerPoint else { return }
            commandPressed = pressed
            pointerPoint = owned
        } else {
            let pressed = event.modifierFlags.contains(.command)
            guard pressed != commandPressed else { return }
            commandPressed = pressed
        }
        refreshPointerFeedback()
    }

    private func updatePointerCursor() {
        if rightDragging || otherDragPoint != nil {
            NSCursor.closedHand.set()
        } else if pointerPoint != nil && assemblyGrabbingEnabled && commandPressed {
            NSCursor.closedHand.set()
            commandCursorSet = true
        } else {
            if pointerPoint != nil || (commandCursorSet && NSCursor.current === NSCursor.closedHand) {
                NSCursor.arrow.set()
            }
            commandCursorSet = false
        }
    }

    private func clearPointerFeedback() {
        pointerPoint = nil
        commandPressed = false
        if (commandCursorSet || rightDragging || otherDragPoint != nil), NSCursor.current === NSCursor.closedHand {
            NSCursor.arrow.set()
        }
        commandCursorSet = false
        setHoveredFeature(nil)
    }

    private func refreshPointerFeedback() {
        updatePointerCursor()
        guard let point = pointerPoint, !(assemblyGrabbingEnabled && commandPressed),
              !commandGrabGesture, !isAnimatingCamera, rightDownPoint == nil,
              NSEvent.pressedMouseButtons == 0 else {
            setHoveredFeature(nil)
            return
        }
        setHoveredFeature(feature(at: point))
    }

    private func updateHover(with event: NSEvent) {
        trackPointer(with: event)
        refreshPointerFeedback()
    }

    private func setHoveredFeature(_ feature: CADFeatureID?) {
        guard hoveredFeature != feature else { return }
        hoveredFeature = feature
        if updateFeatureHighlights() { requestRedraw() }
    }

    override func mouseDown(with event: NSEvent) {
        trackPointer(with: event)
        cancelAssemblyGrab()
        cancelCameraTransition()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if assemblyGrabbingEnabled, event.modifierFlags.contains(.command) {
            commandGrabGesture = true
            resetNavigationGesture()
            setHoveredFeature(nil)
            updatePointerCursor()
            guard bounds.contains(point), let hit = visibleHit(at: point),
                  let solid = solidIndex(of: hit.node), let projection = assemblyGrabProjection() else { return }
            let original = (solidMatrices[solid].map(simd_inverse) ?? matrix_identity_double4x4)
                * SIMD4(Double(hit.worldCoordinates.x), Double(hit.worldCoordinates.y), Double(hit.worldCoordinates.z), 1)
            guard onAssemblyGrabBegan?(solid, [original.x, original.y, original.z], projection) == true else { return }
            assemblyGrab = AssemblyGrabGesture(solid: solid, start: point)
            return
        }
        if event.modifierFlags.contains(.option) {
            setHoveredFeature(nil)
            let hit = bounds.contains(point) ? visibleHit(at: point) : nil
            if event.clickCount >= 2 {
                if hit == nil { deselectAll() }
                return
            }
            if let hit, let solid = solidIndex(of: hit.node) {
                select(selectedSolids.symmetricDifference([solid]))
            }
            return
        }
        let feature = feature(at: point)
        setHoveredFeature(feature)
        if event.clickCount >= 2 {
            if feature == nil && visibleHit(at: point) == nil { deselectAll() }
            return
        }
        if let feature { selectFeatures(ViewportFeaturePicking.toggling(feature, in: selectedFeatures)) }
    }
    override func mouseUp(with event: NSEvent) {
        trackPointer(with: event)
        if commandGrabGesture {
            deliverAssemblyGrab(at: convert(event.locationInWindow, from: nil))
            let accepted = assemblyGrab != nil
            assemblyGrab = nil
            commandGrabGesture = false
            if accepted { onAssemblyGrabEnded?() }
        }
        updatePointerCursor()
    }
    override func mouseDragged(with event: NSEvent) {
        trackPointer(with: event)
        updatePointerCursor()
        setHoveredFeature(nil)
        if commandGrabGesture { deliverAssemblyGrab(at: convert(event.locationInWindow, from: nil)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !commandGrabGesture else { return }
        cancelCameraTransition()
        window?.makeFirstResponder(self)
        setHoveredFeature(nil)
        rightDownPoint = convert(event.locationInWindow, from: nil)
        rightDragPoint = rightDownPoint
        rightDragging = false
    }
    override func rightMouseUp(with event: NSEvent) {
        guard rightDownPoint != nil else { return }
        trackPointer(with: event)
        let wasDragging = rightDragging
        resetNavigationGesture()
        if !wasDragging {
            showContextMenu(event)
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let start = rightDownPoint, let previous = rightDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        if !rightDragging {
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            rightDragging = true
            NSCursor.closedHand.set()
        }
        rightDragPoint = point
        // Some mouse/remote input paths report zero NSEvent deltas even as
        // their locations move. Track actual cursor travel in view points.
        // AppKit view Y points up; CameraRig's existing mouse Y points down.
        let dx = Double(point.x - previous.x)
        let dy = Double(previous.y - point.y)
        guard dx != 0 || dy != 0 else { return }
        if event.modifierFlags.contains(.shift) {
            rig.pan(dx: dx, dy: dy, height: bounds.height)
        } else {
            rig.orbitAroundCenter(dx: dx, dy: dy)
        }
        applyCamera()
    }
    override func otherMouseDown(with event: NSEvent) {
        guard !commandGrabGesture else { return }
        cancelCameraTransition()
        window?.makeFirstResponder(self)
        setHoveredFeature(nil)
        otherDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }
    override func otherMouseUp(with event: NSEvent) {
        guard !commandGrabGesture else { return }
        trackPointer(with: event)
        otherDragPoint = nil
        updatePointerCursor()
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard let previous = otherDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        otherDragPoint = point
        let dx = Double(point.x - previous.x)
        let dy = Double(previous.y - point.y)
        guard dx != 0 || dy != 0 else { return }
        rig.pan(dx: dx, dy: dy, height: bounds.height)
        applyCamera()
    }

    private func deliverAssemblyGrab(at point: NSPoint) {
        guard var grab = assemblyGrab, point.x.isFinite, point.y.isFinite,
              grab.lastDelivered != point,
              grab.lastDelivered != nil || hypot(point.x - grab.start.x, point.y - grab.start.y) >= 3 else { return }
        grab.lastDelivered = point
        assemblyGrab = grab
        onAssemblyGrabMoved?([Double(point.x), Double(point.y)])
    }

    private func cancelAssemblyGrab() {
        let accepted = assemblyGrab != nil
        assemblyGrab = nil
        commandGrabGesture = false
        if accepted { onAssemblyGrabCancelled?() }
        if accepted { updatePointerCursor() }
    }

    /// Freeze actual camera XY/w projection once for a grab. Camera-local
    /// axes preserve custom roll as well as the ordinary orbit camera basis.
    private func assemblyGrabProjection(viewportSize: CGSize? = nil) -> AssemblyGrabProjection? {
        let node = pointOfView ?? cameraNode
        let size = viewportSize ?? bounds.size
        guard let camera = node.camera, size.width > 0, size.height > 0 else { return nil }
        let transform = node.simdWorldTransform
        let right = SIMD3<Double>(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
        let up = SIMD3<Double>(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
        let backward = SIMD3<Double>(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let position = SIMD3<Double>(SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
        let vertical = camera.usesOrthographicProjection ? camera.orthographicScale
            : tan(Double(camera.fieldOfView) * .pi / 360)
        let horizontal = vertical * Double(size.width / size.height)
        guard vertical.isFinite, horizontal.isFinite, vertical > 0, horizontal > 0 else { return nil }
        let x = right / horizontal, y = up / vertical
        let w = camera.usesOrthographicProjection ? SIMD3<Double>.zero : -backward
        let offset = camera.usesOrthographicProjection ? 1 : simd_dot(position, backward)
        let matrix = [x.x, x.y, x.z, -simd_dot(x, position),
                      y.x, y.y, y.z, -simd_dot(y, position),
                      0, 0, 0, 0, w.x, w.y, w.z, offset]
        guard matrix.allSatisfy(\.isFinite) else { return nil }
        return AssemblyGrabProjection(worldToClip: matrix, viewportSize: [Double(size.width), Double(size.height)])
    }

    private func resetNavigationGesture() {
        rightDownPoint = nil
        rightDragPoint = nil
        otherDragPoint = nil
        rightDragging = false
        updatePointerCursor()
    }

    private func select(_ solids: Set<Int>) {
        guard solids != selectedSolids else { return }
        selectedSolids = solids
        if applyStyle(), isPreparingResources { prepareModelResources() }
        onSelectionChanged?(solids)
        requestRedraw()
    }

    private func selectFeatures(_ features: [CADFeatureID]) {
        guard features != selectedFeatures else { return }
        selectedFeatures = features
        updateFeatureHighlights()
        onFeatureSelectionChanged?(features)
        requestRedraw()
    }

    private func deselectAll() {
        setHoveredFeature(nil)
        select([])
        selectFeatures([])
        onDeselectAll?()
    }

    private func showContextMenu(_ event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Opening a context menu preserves both part and feature selections.
        let menu = NSMenu(title: "Viewport")
        if selectedFeatures.count == 1, let face = selectedFeatures.first, face.kind == .face,
           self.face(at: convert(event.locationInWindow, from: nil)) == face {
            let export = menu.addItem(withTitle: "Export DXF…", action: #selector(menuExportFaceDXF(_:)), keyEquivalent: "")
            export.target = self
            export.representedObject = face
            // A drawing is flat; curved faces have no exact 2D outline.
            export.isEnabled = canExport && topology?.face(for: face)?.type == "PLANE"
            menu.addItem(.separator())
        }
        let fit = menu.addItem(withTitle: "Fit Design", action: #selector(menuFit), keyEquivalent: "")
        fit.target = self
        let reset = menu.addItem(withTitle: "Reset Isometric View", action: #selector(menuReset), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        let views = NSMenu(title: "Standard Views")
        for (title, tag) in [("Front", 1), ("Back", 4), ("Left", 5), ("Right", 3), ("Top", 2), ("Bottom", 6)] {
            let item = views.addItem(withTitle: title, action: #selector(menuView(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        let viewsItem = menu.addItem(withTitle: "Standard Views", action: nil, keyEquivalent: "")
        viewsItem.submenu = views
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide Selected Parts", action: #selector(menuHideSelected), keyEquivalent: "")
        hide.target = self
        let selectedOwners = selectedSolids.union(selectedFeatures.map(\.solidIndex))
        hide.isEnabled = !selectedOwners.subtracting(hiddenSolids).isEmpty
        if !hiddenSolids.isEmpty {
            let showAll = menu.addItem(withTitle: "Show All Parts", action: #selector(menuShowAll), keyEquivalent: "")
            showAll.target = self
        }
        menu.addItem(.separator())
        let deselect = menu.addItem(withTitle: "Deselect All", action: #selector(menuDeselect), keyEquivalent: "")
        deselect.target = self
        deselect.isEnabled = !selectedSolids.isEmpty || !selectedFeatures.isEmpty
        menu.autoenablesItems = false
        return menu
    }

    @objc private func menuFit() { perform(.fit) }
    @objc private func menuReset() { perform(.isometric); perform(.fit) }
    @objc private func menuDeselect() { deselectAll() }
    @objc private func menuHideSelected() { onHideSelected?() }
    @objc private func menuShowAll() { onShowAll?() }
    @objc private func menuExportFaceDXF(_ sender: NSMenuItem) {
        guard let face = sender.representedObject as? CADFeatureID else { return }
        onExportFaceDXF?(face)
    }
    @objc private func menuView(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: perform(.front)
        case 2: perform(.top)
        case 3: perform(.right)
        case 4: perform(.back)
        case 5: perform(.left)
        case 6: perform(.bottom)
        default: break
        }
    }

    private func anchor(at point: NSPoint) -> SIMD3<Double> {
        if let p = visibleHit(at: point)?.worldCoordinates { return SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
        return rig.planeAnchor(x: point.x, y: point.y, width: bounds.width, height: bounds.height)
    }

    func feature(at point: NSPoint) -> CADFeatureID? {
        guard hasModel, !isPreparingResources, let topology else { return nil }
        let cursor = SIMD2(Double(point.x), Double(point.y))
        if projectedFeatures == nil { projectedFeatures = projectFeatures(topology) }
        guard let projectedFeatures else { return nil }
        return ViewportFeaturePicking.pick(at: cursor, vertices: projectedFeatures.vertices, edges: projectedFeatures.edges, face: face(at: point),
                                          orthographic: rig.usesOrthographicProjection,
                                          isVisible: { [self] world, screen in
            // Test at the candidate's screen position so a nearby visible
            // corner remains pickable even when the cursor is just outside
            // its silhouette. Never select topology through another part.
            guard let hit = visibleHit(at: NSPoint(x: screen.x, y: screen.y)) else { return true }
            let hitWorld = SIMD3(Double(hit.worldCoordinates.x), Double(hit.worldCoordinates.y), Double(hit.worldCoordinates.z))
            let unitsPerPoint = 2 * rig.orthographicScale / max(bounds.height, 1)
            return simd_dot(hitWorld - world, rig.backward) <= max(rig.radius * 1e-5, unitsPerPoint * 1.5)
        })
    }

    /// The nearest visible native face, ignoring nearby vertices and edges.
    private func face(at point: NSPoint) -> CADFeatureID? {
        guard let hit = visibleHit(at: point), let solid = solidIndex(of: hit.node),
              let faces = faceIDsBySolid[solid], faces.indices.contains(hit.faceIndex) else { return nil }
        return faces[hit.faceIndex]
    }

    private func projectFeatures(_ topology: CADTopology) -> ProjectedFeatures {
        // Snapshot the camera once. Recomputing its trigonometric basis for
        // every polyline endpoint stalls the first hover after navigation.
        let projection = rig.projection(width: Double(bounds.width), height: max(Double(bounds.height), 1))
        func projected(_ position: [Double], id: CADFeatureID) -> ViewportFeaturePicking.Vertex? {
            guard validFeaturePoint(position), !hiddenSolids.contains(id.solidIndex) else { return nil }
            let original = SIMD4(position[0], position[1], position[2], 1)
            let transformed = solidMatrices[id.solidIndex].map { $0 * original } ?? original
            let world = SIMD3(transformed.x, transformed.y, transformed.z)
            let (screen, depth) = projection.project(world)
            guard depth > 0, screen.x.isFinite, screen.y.isFinite else { return nil }
            return .init(id: id, world: world, screen: screen, depth: depth)
        }
        let vertices = topology.vertices.compactMap { projected($0.position, id: $0.id) }
        var edges = [ViewportFeaturePicking.Edge]()
        edges.reserveCapacity(topology.edges.count * 4)
        for edge in topology.edges where !hiddenSolids.contains(edge.id.solidIndex) {
            var previous: ViewportFeaturePicking.Vertex?
            for point in edge.polyline {
                let current = projected(point, id: edge.id)
                if let start = previous, let end = current { edges.append(.init(id: edge.id, start: start, end: end)) }
                previous = current
            }
        }
        return ProjectedFeatures(vertices: vertices, edges: edges)
    }

    private func visibleHit(at point: NSPoint) -> SCNHitTestResult? {
        guard !isPreparingResources else { return nil }
        // Wireframe solids can be visually hidden while their analytic edges
        // remain visible. Query those surfaces too, then explicitly discard
        // user-hidden parts before either selecting or anchoring a zoom.
        let search = hiddenSolids.isEmpty ? SCNHitTestSearchMode.closest : .all
        // The deprecated sortResults option overrides nearest-hit ordering,
        // even with searchMode.closest, and can return a farther solid first.
        return hitTest(point, options: [.categoryBitMask: CADViewportCategory.faces, .ignoreHiddenNodes: false,
                                 .searchMode: search.rawValue])
            .first { hit in
                guard let solid = solidIndex(of: hit.node) else { return false }
                return !hiddenSolids.contains(solid)
            }
    }

    /// Scene hits along the design camera's ray through a point in view
    /// coordinates, ordered from the eye like the rendered frame's depth.
    func hitTest(_ point: NSPoint, options: [SCNHitTestOption: Any] = [:]) -> [SCNHitTestResult] {
        guard let ray = cameraRay(at: point) else { return [] }
        var native = [String: Any]()
        for (key, value) in options { native[key.rawValue] = value }
        return scene.rootNode.hitTestWithSegment(from: SCNVector3(ray.from), to: SCNVector3(ray.to), options: native)
    }

    /// Projects a world point to view coordinates with a bottom-left origin,
    /// using the design camera. Z is the point's distance in front of the eye.
    func projectPoint(_ point: SCNVector3) -> SCNVector3 {
        guard let basis = cameraBasis() else { return SCNVector3Zero }
        let delta = SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z)) - basis.position
        let depth = -simd_dot(delta, basis.backward)
        let height = basis.orthographic ? basis.halfHeight : depth * basis.halfHeight
        let width = height * Double(bounds.width / max(bounds.height, 1))
        let x = (simd_dot(delta, basis.right) / width + 1) / 2 * Double(bounds.width)
        let y = (simd_dot(delta, basis.up) / height + 1) / 2 * Double(bounds.height)
        return SCNVector3(x, y, depth)
    }

    /// The camera's world axes and vertical half-extent: the orthographic
    /// scale, or the tangent of half the vertical field of view.
    private func cameraBasis() -> (position: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>,
                                    backward: SIMD3<Double>, orthographic: Bool, halfHeight: Double)? {
        guard let camera = cameraNode.camera, bounds.width > 0, bounds.height > 0 else { return nil }
        let t = cameraNode.simdWorldTransform
        func axis(_ column: SIMD4<Float>) -> SIMD3<Double> { SIMD3<Double>(Double(column.x), Double(column.y), Double(column.z)) }
        let orthographic = camera.usesOrthographicProjection
        let halfHeight = orthographic ? camera.orthographicScale : tan(Double(camera.fieldOfView) * .pi / 360)
        guard halfHeight.isFinite, halfHeight > 0 else { return nil }
        return (axis(t.columns.3), simd_normalize(axis(t.columns.0)), simd_normalize(axis(t.columns.1)),
                simd_normalize(axis(t.columns.2)), orthographic, halfHeight)
    }

    /// A segment from the eye through a view point to beyond the design.
    private func cameraRay(at point: NSPoint) -> (from: SIMD3<Double>, to: SIMD3<Double>)? {
        guard let basis = cameraBasis(), point.x.isFinite, point.y.isFinite else { return nil }
        let x = Double(point.x / bounds.width) * 2 - 1, y = Double(point.y / bounds.height) * 2 - 1
        let aspect = Double(bounds.width / bounds.height)
        var reach = 1.0
        if meshBounds.count == 6 {
            for corner in 0..<8 {
                let p = SIMD3(meshBounds[corner & 1 == 0 ? 0 : 3], meshBounds[corner & 2 == 0 ? 1 : 4],
                              meshBounds[corner & 4 == 0 ? 2 : 5])
                reach = max(reach, simd_length(p - basis.position))
            }
        }
        reach *= 2
        let from: SIMD3<Double>, direction: SIMD3<Double>
        if basis.orthographic {
            from = basis.position + basis.right * (x * basis.halfHeight * aspect) + basis.up * (y * basis.halfHeight)
            direction = -basis.backward
        } else {
            from = basis.position
            direction = simd_normalize(basis.right * (x * basis.halfHeight * aspect) + basis.up * (y * basis.halfHeight)
                                       - basis.backward)
        }
        let to = from + direction * reach
        guard from.x.isFinite, from.y.isFinite, from.z.isFinite, to.x.isFinite, to.y.isFinite, to.z.isFinite else { return nil }
        return (from, to)
    }

    override func scrollWheel(with event: NSEvent) {
        cancelAssemblyGrab()
        cancelCameraTransition()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            rig.pan(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, height: bounds.height)
        } else {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.055)
            rig.zoom(factor: exp(-max(-2, min(2, delta))), anchor: anchor(at: point))
        }
        applyCamera()
    }

    override func magnify(with event: NSEvent) {
        cancelAssemblyGrab()
        cancelCameraTransition()
        let point = convert(event.locationInWindow, from: nil)
        if event.phase == .began || zoomAnchor == nil { zoomAnchor = anchor(at: point) }
        rig.zoom(factor: exp(-event.magnification), anchor: zoomAnchor!)
        if event.phase == .ended || event.phase == .cancelled { zoomAnchor = nil }
        applyCamera()
    }

    override func keyDown(with event: NSEvent) {
        cancelCameraTransition()
        if event.keyCode == 53 { cancelAssemblyGrab(); deselectAll(); return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": perform(.fit)
        case "0": perform(.isometric)
        case "1": perform(.front)
        case "2": perform(.top)
        case "3": perform(.right)
        default: super.keyDown(with: event)
        }
    }
}
