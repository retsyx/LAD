import AppKit
import SceneKit
import SwiftUI
import simd

enum ViewportProjectionMode: String, Codable, Sendable, CaseIterable {
    case perspective, isometric
}

enum ViewportDisplayMode: String, Codable, Sendable, CaseIterable {
    case shaded, edges, translucent, wireframe
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
    /// Replacing the mesh under the same key keeps the camera.
    var cameraKey: String? = nil
    var sectionEnabled = false
    var canSection = true
    var onSectionFromFace: (() -> Void)? = nil
    var onSelectionChanged: ((Set<Int>) -> Void)? = nil
    var onFeatureSelectionChanged: (([CADFeatureID]) -> Void)? = nil
    var onDeselectAll: (() -> Void)? = nil
    var onHideSelected: (() -> Void)? = nil
    var onShowAll: (() -> Void)? = nil
    var canExport = false
    var onExportSelectedPartsSTEP: (() -> Void)? = nil
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
        view.canSection = canSection
        view.onSectionFromFace = onSectionFromFace
        view.canExport = canExport
        view.onExportSelectedPartsSTEP = onExportSelectedPartsSTEP
        view.onExportFaceDXF = onExportFaceDXF
        view.onActivated = onViewReady
        view.onAssemblyGrabBegan = onAssemblyGrabBegan
        view.onAssemblyGrabMoved = onAssemblyGrabMoved
        view.onAssemblyGrabEnded = onAssemblyGrabEnded
        view.onAssemblyGrabCancelled = onAssemblyGrabCancelled
        view.assemblyGrabbingEnabled = assemblyGrabbingEnabled
        view.update(mesh: mesh, mode: displayMode, grid: showGrid, command: command,
                    selectedSolids: selectedSolids, hiddenSolids: hiddenSolids, projection: projectionMode,
                    solidColors: solidColors, selectedFeatures: selectedFeatures, solidTransforms: solidTransforms,
                    cameraKey: cameraKey, sectionEnabled: sectionEnabled)
        onViewReady?(view)
    }
}

final class CADSceneView: NSView {
    /// The shader argument holding a translucent face's opacity: the display's
    /// fixed translucency, or a part's color alpha in shaded and edge displays.
    static let opacityKey = "cadOpacity"
    // CAD translucency fades the whole lit face, including PBR specular
    // reflections, as premultiplied color accumulated without depth testing.
    private static let translucentFragment = """
    #pragma opaque
    #pragma arguments
    float cadOpacity;
    #pragma body
    _output.color *= cadOpacity;
    """
    private static let opaqueFragment = """
    #pragma opaque
    #pragma body
    _output.color.a = 1.0;
    """
    /// Removes exactly what `translucentFragment` adds for the same shading.
    private static let translucentRemovalFragment = """
    #pragma opaque
    #pragma arguments
    float cadOpacity;
    #pragma body
    _output.color *= -cadOpacity;
    """
    /// Each translucent face layer multiplies the remaining transmittance.
    private static let revealageFragment = """
    #pragma arguments
    float cadOpacity;
    #pragma body
    _output.color = float4(1.0 - cadOpacity);
    """
    private static let visibilityCopyName = "visibility"
    private static let revealageCopyName = "revealage"
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
    /// The camera key of the last installed model, retained while no model
    /// is shown, and whether the model being installed shares it.
    private var installedCameraKey: String?
    private var installingCameraKey: String?
    private var installKeepsCamera = false
    private var needsInitialFit = false
    private var selectedSolids = Set<Int>()
    private var selectedFeatures = [CADFeatureID]()
    private var hoveredFeature: CADFeatureID?
    /// The part an Option-click would toggle, previewed while Option is held.
    private var hoveredSolid: Int?
    private var hiddenSolids = Set<Int>() { didSet { resumeCaptureWaitersIfReady() } }
    private var solidColors: [Int: PartColor] = [:]
    /// How far opaque depth copies sit behind their surfaces in partial opacity passes.
    private var depthRecess: Float = 0.01
    private var ownedEdgeSolids = Set<Int>()
    private var hasOwnedEdges = false
    private struct RightMouseGesture {
        let start: NSPoint
        var previous: NSPoint
        var isDragging = false
    }
    private var rightGesture: RightMouseGesture?
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
    private var optionPressed = false
    private var commandCursorSet = false
    private var modifierMonitor: Any?
    var isGrabbingAssembly: Bool { assemblyGrab != nil }
    private var topology: CADTopology?
    private struct SolidPose {
        let transforms: [Int: [Double]]
        let matrices: [Int: simd_double4x4]
    }
    private var solidTransforms: [Int: [Double]] = [:]
    private var solidMatrices: [Int: simd_double4x4] = [:]
    private var solidBounds: [Int: [Double]] = [:]
    private var originalMeshBounds: [Double] = []
    private var sectionEnabled = false
    /// The manipulator can lead the cut while the matching cap is prepared.
    private(set) var sectionPlane: CADSectionPlane?
    private var presentedSectionPlane: CADSectionPlane?
    private var retainedSectionPlane: CADSectionPlane?
    private var sectionMesh: CADViewportPreparedMesh?
    private var sectionParts: [PartNode]?
    private var sectionPartOwners = [Int: Int]()
    private let sectionCaps = CADViewportSectionCaps()
    private var sectionManipulator: CADSectionManipulator?
    private struct SectionFaceTarget {
        let face: CADFeatureID
        let meshPath: String?
        let nativePath: String?
    }
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
        let mode: ViewportDisplayMode
        let selected: Set<Int>
        /// A visible, unselected part under an Option hover.
        let hovered: Int?
        let hidden: Set<Int>
        let colors: [Int: PartColor]
        /// Solids whose color alpha is below 1. Shaded and edge displays draw
        /// them over the opaque scene; the other displays ignore alpha.
        let partialSolids: Set<Int>
        /// Whether a visible solid is partially opaque.
        let composesPartialOpacity: Bool

        init(mode: ViewportDisplayMode, selected: Set<Int>, hovered: Int?, hidden: Set<Int>, colors: [Int: PartColor]) {
            self.mode = mode
            self.selected = selected
            self.hovered = hovered.flatMap { selected.contains($0) || hidden.contains($0) ? nil : $0 }
            self.hidden = hidden
            self.colors = colors
            partialSolids = mode == .shaded || mode == .edges ? Set(colors.compactMap { $0.value.alpha < 1 ? $0.key : nil }) : []
            composesPartialOpacity = !partialSolids.subtracting(hidden).isEmpty
        }

        func opacity(of solid: Int) -> Double { colors[solid]?.alpha ?? 1 }
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
    /// Whether the newest completed frame drew the model.
    private(set) var renderedShowsModel = false
    private var publishedCameraTransforms: [(generation: UInt64, transform: simd_float4x4, showsModel: Bool)] = []
    /// A model replaced by another display ready to install, such as the
    /// design and its 3D printing version, stays on screen in the last
    /// presented frame until the replacement and its highlights are prepared.
    /// Publishing meanwhile would present an empty interim frame.
    private var holdsFramesForReplacement = false
    private var hasHeldFrame = false
    /// True until the GPU has completed a frame showing the latest change.
    var hasPendingFrames: Bool { framePublicationScheduled || hasHeldFrame || renderedGeneration < publishedGeneration }
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
        isPreparingResources || sectionCaps.isPreparing || highlightedFeatures.contains {
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
    var canSection = true
    var onSectionFromFace: (() -> Void)?
    /// Whether the design can currently be exported; menu state only.
    var canExport = false
    var onExportSelectedPartsSTEP: (() -> Void)?
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
        scene.rootNode.addChildNode(sectionCaps.node)
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
                solidTransforms: [Int: [Double]] = [:], cameraKey: String? = nil, sectionEnabled: Bool = false) {
        let orthographic = projection == .isometric
        let projectionChanged = rig.usesOrthographicProjection != orthographic
        let gridChanged = gridVisible != grid
        let meshChanged = mesh?.stepPath != loadedPath || mesh?.brepPath != loadedNativePath
        let visibilityChanged = self.hiddenSolids != hiddenSolids
        let modeChanged = self.mode != mode
        let sectionStyleChanged = (self.mode == .wireframe) != (mode == .wireframe)
        self.sectionEnabled = canSection && sectionEnabled
        if meshChanged { retainedSectionPlane = nil }
        if meshChanged || !self.sectionEnabled { setSectionPlane(nil) }
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
            hoveredSolid = nil
        }
        var finishes = PartColorState.solidColors(in: mesh?.parts ?? [], overrides: [:])
        finishes.merge(solidColors.filter { (0..<4_096).contains($0.key) && $0.value.isValid },
                       uniquingKeysWith: { _, override in override })
        self.solidColors = finishes
        let sectionOwnersChanged = updateSectionPartOwners(mesh?.parts)
        let requestedPoseChanged = requestedSolidTransforms != solidTransforms
        requestedSolidTransforms = solidTransforms
        if gridChanged { gridNode.isHidden = !grid }
        var installedModel = false
        if meshChanged {
            let replacing = hasModel
            holdsFramesForReplacement = false
            loadedPath = mesh?.stepPath
            loadedNativePath = mesh?.brepPath
            invalidateResourcePreparation()
            modelNode.isHidden = true
            edgeNode.isHidden = true
            appliedStyle = nil
            if let mesh {
                // Another display of the model last shown under the same camera
                // key, even after an empty interim, keeps the user's camera.
                installKeepsCamera = cameraKey != nil && cameraKey == installedCameraKey
                installingCameraKey = cameraKey
                // Copies of a preview share its converted buffers, so a version
                // or image another view already prepared installs directly.
                let shared = CADViewportPreparedMesh.shared(for: mesh)
                if shared == nil, CADViewportPreparedMesh.requiresBackgroundPreparation(mesh) {
                    prepareMesh(mesh)
                } else if let prepared = try? shared ?? CADViewportPreparedMesh.prepareShared(mesh) {
                    install(prepared)
                    installedModel = hasModel
                    holdsFramesForReplacement = replacing && installedModel
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
        // A sectioned pose is published by the cap completion. Compare new
        // requests to each other so a move back to the displayed pose still queues.
        let poseChanged = sectionPlane == nil && (meshChanged || solidTransforms != self.solidTransforms)
            && applySolidPose(validatedPose(solidTransforms), reinstalling: meshChanged)
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
        if sectionPlane == nil {
            openSectionIfRequested()
        } else if requestedPoseChanged || visibilityChanged || sectionStyleChanged || sectionOwnersChanged {
            updateSectionCaps(replacingInputs: visibilityChanged || sectionStyleChanged || sectionOwnersChanged)
        }
        if meshChanged || poseChanged || styleChanged || featuresChanged || gridChanged { requestRedraw() }
    }

    private func openSectionIfRequested() {
        guard sectionEnabled, hasModel, sectionPlane == nil else { return }
        let faces = selectedFeatures.filter { $0.kind == .face }
        let selectedPlane = faces.count == 1 ? sectionPlane(for: faces[0]) : nil
        setSectionPlane(selectedPlane ?? retainedSectionPlane
                        ?? CADSectionPlane(bounds: meshBounds, toward: rig.backward, cameraRight: rig.right))
    }

    private func sectionPlane(for id: CADFeatureID) -> CADSectionPlane? {
        guard !hiddenSolids.contains(id.solidIndex), let face = topology?.face(for: id), face.type == "PLANE",
              let normal = face.normal, validFeaturePoint(normal), validFeaturePoint(face.center) else { return nil }
        let transform = solidMatrices[id.solidIndex] ?? matrix_identity_double4x4
        let center = transform * SIMD4(face.center[0], face.center[1], face.center[2], 1)
        let direction = transform * SIMD4(normal[0], normal[1], normal[2], 0)
        return CADSectionPlane(point: SIMD3(center.x, center.y, center.z),
                               normal: SIMD3(direction.x, direction.y, direction.z), cameraRight: rig.right)
    }

    func configureAgentSection(_ plane: CADSectionPlane) {
        setSectionPlane(plane)
    }

    private func setSectionPlane(_ plane: CADSectionPlane?) {
        guard sectionPlane != plane else { return }
        sectionPlane = plane
        if let plane { retainedSectionPlane = plane }
        updateSectionCaps()
        updateSectionManipulator()
    }

    private func presentSection(_ plane: CADSectionPlane?, cap: SCNGeometry?, pose: SolidPose?) {
        let changed = presentedSectionPlane != plane
        let poseChanged = pose.map { $0.transforms != solidTransforms } ?? false
        guard changed || poseChanged || sectionCaps.node.geometry !== cap else {
            resumeCaptureWaitersIfReady()
            return
        }
        presentedSectionPlane = plane
        projectedFeatures = nil
        zoomAnchor = nil
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        if let pose, applySolidPose(pose, reinstalling: false) {
            _ = applyStyle()
            _ = updateFeatureHighlights()
        } else {
            clearHover()
        }
        sectionCaps.show(cap)
        if changed {
            for node in edgeNode.childNodes {
                if let geometry = node.geometry { CADStrokeGeometry.setSectionPlane(plane, on: geometry) }
            }
            for root in [modelNode, featureNode] {
                root.enumerateChildNodes { node, _ in
                    for material in node.geometry?.materials ?? [] {
                        CADViewportSectionRendering.apply(plane, to: material)
                    }
                }
            }
        }
        SCNTransaction.commit()
        resumeCaptureWaitersIfReady()
        requestRedraw()
    }

    private func updateSectionPartOwners(_ parts: [PartNode]?) -> Bool {
        guard sectionParts != parts else { return false }
        sectionParts = parts
        // The prepared display cache shares geometry independently of the part tree.
        var owners = [Int: Int]()
        for part in (parts ?? []).flatMap(\.flattened) where !part.isGroup && part.solidIndices.count > 1 {
            guard let owner = part.solidIndices.min() else { continue }
            for solid in part.solidIndices where solid != owner { owners[solid] = owner }
        }
        guard owners != sectionPartOwners else { return false }
        sectionPartOwners = owners
        return true
    }

    private func updateSectionCaps(replacingInputs: Bool = false) {
        let pose = sectionPlane.map { _ in
            requestedSolidTransforms == solidTransforms
                ? SolidPose(transforms: solidTransforms, matrices: solidMatrices) : validatedPose(requestedSolidTransforms)
        }
        sectionCaps.update(plane: sectionPlane, mesh: sectionMesh, transforms: pose?.matrices ?? [:],
                           hidden: hiddenSolids, partOwners: sectionPartOwners, mode: mode,
                           renderer: preparesRendererResources ? renderer : nil,
                           replacingInputs: replacingInputs) { [weak self] plane, cap in
            guard let self else { return }
            // Visibility and wire styling can invalidate the displayed cap.
            // A pose update keeps the displayed geometry until its cap is ready.
            let resetCap = replacingInputs && plane == nil && self.sectionPlane != nil
            self.presentSection(resetCap ? self.presentedSectionPlane : plane, cap: cap, pose: plane == nil ? nil : pose)
        }
    }

    private func updateSectionManipulator() {
        guard sectionEnabled, let sectionPlane else {
            sectionManipulator?.removeFromSuperview()
            sectionManipulator = nil
            return
        }
        if sectionManipulator == nil {
            let manipulator = CADSectionManipulator(onBegin: { [weak self] in
                self?.cancelAssemblyGrab()
                self?.cancelCameraTransition()
                self?.clearPointerFeedback()
            }, onChange: { [weak self] plane in self?.setSectionPlane(plane) })
            manipulator.frame = bounds
            manipulator.autoresizingMask = [.width, .height]
            addSubview(manipulator)
            sectionManipulator = manipulator
        }
        sectionManipulator?.update(plane: sectionPlane,
                                   projection: rig.projection(width: bounds.width, height: bounds.height))
    }

    private func validatedPose(_ requested: [Int: [Double]]) -> SolidPose {
        var matrices: [Int: simd_double4x4] = [:]
        let valid = requested.count <= 4_096 && requested.allSatisfy { solid, values in
            guard solidBounds[solid] != nil, let matrix = ViewportRigidTransform.matrix(values) else { return false }
            matrices[solid] = matrix
            return true
        }
        return valid ? SolidPose(transforms: requested, matrices: matrices) : SolidPose(transforms: [:], matrices: [:])
    }

    /// Moving a rigid body changes node poses only. Display buffers, native
    /// feature identities, and materials stay attached to the original preview.
    @discardableResult
    private func applySolidPose(_ pose: SolidPose, reinstalling: Bool) -> Bool {
        guard reinstalling || pose.transforms != solidTransforms else { return false }
        solidTransforms = pose.transforms
        solidMatrices = pose.matrices
        projectedFeatures = nil
        hoveredFeature = nil
        hoveredSolid = nil
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
        meshBounds = bounds(for: pose)
        if reinstalling, !pose.transforms.isEmpty {
            if installKeepsCamera { rig.adoptBounds(meshBounds) }
            else { rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height) }
            rebuildGrid()
            applyCamera()
        }
        return true
    }

    private func install(_ prepared: CADViewportPreparedMesh) {
        let mesh = prepared.mesh
        sectionMesh = prepared
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
        depthRecess = CADTranslucency.depthRecess(bounds: mesh.bounds)
        sectionCaps.depthRecess = depthRecess
        installEdges(prepared)
        edgeNode.renderingOrder = 1
        meshBounds = mesh.bounds
        let first = !hasModel
        hasModel = true
        installedCameraKey = installingCameraKey
        if installKeepsCamera {
            rig.adoptBounds(meshBounds)
        } else {
            needsInitialFit = bounds.width < 10 || bounds.height < 10
            rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
            if first {
                rig.yaw = -.pi / 4
                rig.elevation = 0.6154797087
                rig.roll = 0
            }
        }
        rebuildGrid()
        applyCamera()
    }

    private func clearModel() {
        invalidateResourcePreparation()
        setSectionPlane(nil)
        sectionMesh = nil
        retainedSectionPlane = nil
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
    /// geometry buffers. Shown in translucent mode, and while shaded and edge
    /// displays draw partially opaque solids over the opaque scene.
    static func translucentCopy(of geometry: SCNGeometry, category: Int, visible: Bool) -> SCNNode {
        let copy = SCNGeometry(sources: geometry.sources, elements: geometry.elements)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        let visibility = category == CADViewportCategory.visibility
        if visibility {
            // Nearest solid depth belongs only to ordinary decorations, and
            // to partially opaque faces behind opaque solids.
            material.colorBufferWriteMask = []
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
        } else {
            // Multiplicative transmittance is independent of draw order and
            // never rejected by another translucent face's depth.
            material.shaderModifiers = [.fragment: Self.revealageFragment]
            material.setValue(NSNumber(value: CADTranslucency.alpha), forKey: opacityKey)
            material.blendMode = .multiply
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
        }
        copy.materials = [material]
        let node = SCNNode(geometry: copy)
        node.name = visibility ? visibilityCopyName : revealageCopyName
        node.categoryBitMask = category
        node.isHidden = !visible
        return node
    }

    /// Translucent mode shows every solid's copies with its fixed opacity.
    /// Shaded and edge displays use a partially opaque solid's copies with its
    /// color alpha, depth tested against opaque solids, whose visibility
    /// copies then draw their depth first in each of those passes.
    private static func styleCopies(of node: SCNNode, translucent: Bool, partial: Bool, layered: Bool, opacity: Float,
                                    recess: Float) {
        for copy in node.childNodes {
            switch copy.name {
            case visibilityCopyName:
                let opaqueDepth = layered && !partial
                if copy.isHidden == (translucent || layered) { copy.isHidden = !(translucent || layered) }
                copy.categoryBitMask = opaqueDepth ? CADViewportCategory.opaqueVisibility : CADViewportCategory.visibility
                copy.renderingOrder = opaqueDepth ? CADTranslucency.opaqueDepthRenderingOrder : 0
                if let material = copy.geometry?.firstMaterial {
                    CADTranslucency.recess(material, by: opaqueDepth ? recess : nil)
                }
            case revealageCopyName:
                if copy.isHidden == (translucent || partial) { copy.isHidden = !(translucent || partial) }
                if let material = copy.geometry?.firstMaterial {
                    material.setValue(NSNumber(value: opacity), forKey: opacityKey)
                    material.readsFromDepthBuffer = partial
                }
            default:
                break
            }
        }
    }

    private static let translucentFillName = "translucentFill"
    private static let translucentRemovalName = "translucentRemoval"

    /// A highlighted face's translucent fill. Translucent mode replaces the
    /// face's share of the accumulated color: the fill adds its highlight
    /// shading and the removal copy subtracts its part's shading, leaving the
    /// rest of the part and all transmittance unchanged. Both share the
    /// overlay's geometry buffers and draw only in the accumulation pass.
    private static func translucentFeatureCopy(of geometry: SCNGeometry, shadedAs source: SCNMaterial, removal: Bool) -> SCNNode {
        let copy = SCNGeometry(sources: geometry.sources, elements: geometry.elements)
        let material = (source.copy() as? SCNMaterial) ?? SCNMaterial()
        material.fillMode = .fill
        configureFaceMaterial(material, translucent: true)
        if removal { material.shaderModifiers = [.fragment: translucentRemovalFragment] }
        copy.materials = [material]
        let node = SCNNode(geometry: copy)
        node.name = removal ? translucentRemovalName : translucentFillName
        node.categoryBitMask = CADViewportCategory.featureAccumulation
        return node
    }

    /// Switches a solid's face material between opaque shading and additive
    /// translucent accumulation. Convex-only dual-layer sorting changes with
    /// the view on CAD shells. Translucent faces instead add premultiplied
    /// color without testing each other's depth, so every contribution is
    /// independent of object and triangle submission order; depth-only and
    /// transmittance copies supply decoration occlusion and coverage.
    /// Partially opaque faces in shaded and edge displays read the depth of
    /// opaque solids, which their accumulation pass draws first.
    static func configureFaceMaterial(_ material: SCNMaterial, translucent: Bool,
                                      opacity: Float = CADTranslucency.alpha, readsDepth: Bool = false) {
        material.transparency = 1
        material.shaderModifiers = [.fragment: translucent ? translucentFragment : opaqueFragment]
        if translucent { material.setValue(NSNumber(value: opacity), forKey: opacityKey) }
        material.transparencyMode = .aOne
        material.blendMode = translucent ? .add : .alpha
        material.writesToDepthBuffer = !translucent
        material.readsFromDepthBuffer = !translucent || readsDepth
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
                self.applySolidPose(self.validatedPose(self.requestedSolidTransforms), reinstalling: true)
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
                self.openSectionIfRequested()
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
        // Wireframe draws no faces, so highlighted faces keep only their
        // overlay outline instead of a fill that covers the wires around them.
        let featuresHidden = hidden || mode == .wireframe
        if featureNode.isHidden != featuresHidden { featureNode.isHidden = featuresHidden }
    }

    private func resetFeatureResources() {
        featurePreparationID = UUID()
        hoveredFeature = nil
        hoveredSolid = nil
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
                if let overlay = geometry.firstMaterial,
                   let part = solidNodes[feature.solidIndex]?.geometry?.firstMaterial {
                    node.addChildNode(Self.translucentFeatureCopy(of: geometry, shadedAs: overlay, removal: false))
                    node.addChildNode(Self.translucentFeatureCopy(of: geometry, shadedAs: part, removal: true))
                }
                styleFeature(node, solid: feature.solidIndex)
                if let plane = presentedSectionPlane {
                    for surface in [node] + node.childNodes {
                        surface.geometry?.materials.forEach { CADViewportSectionRendering.apply(plane, to: $0) }
                    }
                }
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
                let color = isSelected ? Self.selectionColor : Self.hoveredFeatureColor
                node.geometry?.firstMaterial?.diffuse.contents = color
                node.childNode(withName: Self.translucentFillName, recursively: false)?.geometry?.firstMaterial?.diffuse.contents = color
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
        frame.sectionPlane = presentedSectionPlane?.equation ?? .zero
        if let style = appliedStyle, style.composesPartialOpacity {
            frame.partialOpacity = true
            frame.partialEdges = style.mode == .edges && hasOwnedEdges
        }
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
        let hoveredPart = hoveredSolid.flatMap { selectedSolids.contains($0) ? nil : [$0] } ?? []
        for solid in selectedSolids.sorted() + hoveredPart where !hiddenSolids.contains(solid) {
            guard let mask = partMask(solid) else { continue }
            let transform = model(solid)
            masks.append(.init(buffer: mask, selected: selectedSolids.contains(solid), model: transform))
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
        let style = RenderStyle(mode: mode, selected: selectedSolids, hovered: hoveredSolid, hidden: hiddenSolids, colors: solidColors)
        guard appliedStyle != style else { return false }
        let previous = appliedStyle
        appliedStyle = style
        let translucent = mode == .translucent
        // Partially opaque solids are drawn over the opaque scene, which
        // then supplies their occluding depth.
        let partialSolids = style.partialSolids, layered = style.composesPartialOpacity
        let previousPartial = previous?.partialSolids ?? [], previousLayered = previous?.composesPartialOpacity ?? false
        let coloredLegacyWire = !hasOwnedEdges && mode == .wireframe && !solidColors.isEmpty
        for node in edgeNode.childNodes {
            let solid = solidIndex(of: node, prefix: "edges:")
            let hidden = solid.map { hiddenSolids.contains($0) } ?? (!hiddenSolids.isEmpty || coloredLegacyWire)
            let partial = solid.map(partialSolids.contains) ?? false
            if let previous, previous.mode == mode,
               (solid.map { previous.hidden.contains($0) } ?? (!previous.hidden.isEmpty ||
                    (!hasOwnedEdges && previous.mode == .wireframe && !previous.colors.isEmpty))) == hidden,
               (solid.map(previousPartial.contains) ?? false) == partial,
               mode != .wireframe || solid.map({ previous.colors[$0]?.opaque == solidColors[$0]?.opaque }) != false {
                continue
            }
            // Older projects have one combined edge buffer. Never keep that
            // buffer visible after hiding a part, since its lines include it.
            node.isHidden = hidden
            node.categoryBitMask = partial ? CADViewportCategory.partialDecorations : CADViewportCategory.decorations
            node.geometry?.firstMaterial?.diffuse.contents = mode == .wireframe ? solid.flatMap { assignedColor(for: $0) } ?? NSColor(srgbRed: 0.70, green: 0.75, blue: 0.80, alpha: 1)
                : Self.edgeInk
            node.geometry?.firstMaterial?.readsFromDepthBuffer = mode != .wireframe
            node.geometry?.firstMaterial?.transparency = translucent ? 0.8 : 1
            if let geometry = node.geometry {
                CADStrokeGeometry.setJoinsEnabled(mode == .edges, on: geometry)
            }
        }
        var restyled = Set<Int>()
        for node in modelNode.childNodes {
            guard let solid = solidIndex(of: node) else { continue }
            let selected = selectedSolids.contains(solid)
            let hovered = style.hovered == solid
            let highlight = partHighlight(selected: selected, hovered: hovered)
            let partial = partialSolids.contains(solid)
            if let previous, previous.mode == mode,
               previous.selected.contains(solid) == selected,
               previous.hidden.contains(solid) == hiddenSolids.contains(solid),
               previousPartial.contains(solid) == partial, previousLayered == layered,
               previous.colors[solid] == solidColors[solid] || ((selected || hovered || previous.hovered == solid)
                    && previous.opacity(of: solid) == style.opacity(of: solid)),
               hasOwnedEdges || (previous.hidden.isEmpty == hiddenSolids.isEmpty && previous.colors.isEmpty == solidColors.isEmpty) {
                // A part hover only retints the existing material.
                if partHighlight(selected: selected, hovered: previous.hovered == solid) != highlight
                    || (highlight == nil && previous.colors[solid] != solidColors[solid]) {
                    tint(node.geometry?.firstMaterial, solid: solid, highlight: highlight)
                    restyled.insert(solid)
                }
                continue
            }
            // Native analytic wire edges are preferred. Fall back to each
            // solid's triangle wireframe when edge ownership is unavailable,
            // so hidden legacy solids cannot leave ghost edges behind.
            let needsTriangleWire = hasOwnedEdges ? !ownedEdgeSolids.contains(solid)
                : !hiddenSolids.isEmpty || coloredLegacyWire || edgeNode.childNodes.isEmpty
            node.isHidden = hiddenSolids.contains(solid) || (mode == .wireframe && !needsTriangleWire)
            node.categoryBitMask = partial ? CADViewportCategory.partialFaces : CADViewportCategory.faces
            node.geometry?.firstMaterial?.fillMode = mode == .wireframe ? .lines : .fill
            // Let interior parts show through the filled surfaces. Restore
            // depth writing and opaque materials when leaving this mode.
            let opacity = translucent ? CADTranslucency.alpha : Float(style.opacity(of: solid))
            if let material = node.geometry?.firstMaterial {
                Self.configureFaceMaterial(material, translucent: translucent || partial, opacity: opacity, readsDepth: partial)
                if let plane = presentedSectionPlane { CADViewportSectionRendering.apply(plane, to: material) }
            }
            Self.styleCopies(of: node, translucent: translucent, partial: partial, layered: layered, opacity: opacity,
                             recess: depthRecess)
            tint(node.geometry?.firstMaterial, solid: solid, highlight: highlight)
            restyled.insert(solid)
        }
        // A translucent fill removes exactly its part's current shading.
        for (feature, node) in featureNodes where restyled.contains(feature.solidIndex) {
            styleFeature(node, solid: feature.solidIndex)
            guard let part = solidNodes[feature.solidIndex]?.geometry?.firstMaterial,
                  let removal = node.childNode(withName: Self.translucentRemovalName, recursively: false)?.geometry?.firstMaterial
            else { continue }
            removal.diffuse.contents = part.diffuse.contents
            removal.emission.contents = part.emission.contents
        }
        return true
    }

    /// A selected or hovered part's color in place of its finish. Wireframe
    /// outlines highlighted parts only.
    private func partHighlight(selected: Bool, hovered: Bool) -> NSColor? {
        mode == .wireframe ? nil : selected ? Self.selectionColor : hovered ? Self.hoveredFeatureColor : nil
    }

    private func tint(_ material: SCNMaterial?, solid: Int, highlight: NSColor?) {
        material?.diffuse.contents = highlight
            ?? assignedColor(for: solid) ?? NSColor(srgbRed: 0.70, green: 0.75, blue: 0.80, alpha: 1)
        material?.emission.contents = highlight != nil ? NSColor(srgbRed: 0.12, green: 0.05, blue: 0.005, alpha: 1) : NSColor.black
    }

    /// Translucent mode fills highlighted faces in the accumulation pass;
    /// so do shaded and edge displays on a partially opaque solid, with its
    /// color alpha. Elsewhere the opaque highlight fill draws.
    private func styleFeature(_ node: SCNNode, solid: Int) {
        guard let style = appliedStyle else { return }
        let partial = style.partialSolids.contains(solid)
        let opacity = style.mode == .translucent ? CADTranslucency.alpha : Float(style.opacity(of: solid))
        node.categoryBitMask = partial ? CADViewportCategory.partialFeatureFaces : CADViewportCategory.featureFaces
        for copy in node.childNodes {
            copy.categoryBitMask = partial ? CADViewportCategory.partialFeatureAccumulation : CADViewportCategory.featureAccumulation
            guard let material = copy.geometry?.firstMaterial else { continue }
            material.setValue(NSNumber(value: opacity), forKey: Self.opacityKey)
            material.readsFromDepthBuffer = partial
        }
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

    private func bounds(for pose: SolidPose) -> [Double] {
        if pose.matrices.isEmpty { return originalMeshBounds.isEmpty ? meshBounds : originalMeshBounds }
        let posed = solidBounds.map { solid, bounds in
            ViewportRigidTransform.bounds(bounds, matrix: pose.matrices[solid] ?? matrix_identity_double4x4)
        }
        guard !posed.isEmpty else { return meshBounds }
        return (0..<3).map { axis in posed.map { $0[axis] }.min()! }
            + (0..<3).map { axis in posed.map { $0[axis + 3] }.max()! }
    }

    private var fittingBounds: [Double] {
        guard sectionPlane != nil, requestedSolidTransforms != solidTransforms else { return meshBounds }
        return bounds(for: validatedPose(requestedSolidTransforms))
    }

    private func rebuildGrid(minimumZ: Double? = nil) {
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
        let z = (minimumZ ?? meshBounds[2]) - max(rig.radius * 0.0005, 0.0001)
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
        if action != .fit { rig.roll = 0 }
        switch action {
        case .fit:
            zoomAnchor = nil
            let fitted = fittingBounds
            rig.fit(bounds: fitted, width: bounds.width, height: bounds.height)
            // Guides follow the placed parts, such as a 3D printing plate.
            if hasModel { rebuildGrid(minimumZ: fitted[2]) }
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
        destination.roll = 0
        destination.fit(bounds: fittingBounds, width: bounds.width, height: bounds.height)
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
        clearHover()
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
        updateSectionManipulator()
        requestRedraw()
    }

    private func applyCamera() {
        cancelAssemblyGrab()
        projectedFeatures = nil
        clearHover()
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
        updateSectionManipulator()
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
            clearHover()
            updateStrokeViewportHeight()
        }
        if needsInitialFit, bounds.width >= 10, bounds.height >= 10 {
            cancelCameraTransition()
            needsInitialFit = false
            rig.fit(bounds: meshBounds, width: bounds.width, height: bounds.height)
            applyCamera()
        }
        if sizeChanged {
            updateSectionManipulator()
            requestRedraw()
        }
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
        // Preparation completion requests the held frame.
        hasHeldFrame = holdsFramesForReplacement && isPreparingCaptureResources
        guard !hasHeldFrame else { return }
        holdsFramesForReplacement = false
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
        publishedCameraTransforms.append((publishedGeneration, cameraNode.simdWorldTransform, !modelNode.isHidden))
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
            renderedShowsModel = published.showsModel
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
        if resigned { cancelAssemblyGrab(); clearHover() }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        sectionManipulator?.cancelInteraction()
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
        clearHover()
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
        sectionManipulator?.cancelInteraction()
        clearPointerFeedback()
        cancelAssemblyGrab()
        cancelCameraTransition()
        clearHover()
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
            sectionManipulator?.cancelInteraction()
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
        if let sectionManipulator, hit === sectionManipulator || hit.isDescendant(of: sectionManipulator) { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func trackPointer(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerPoint = ownsPointer(point) ? point : nil
        commandPressed = event.modifierFlags.contains(.command)
        optionPressed = event.modifierFlags.contains(.option)
    }

    private func updateModifiers(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command), option = event.modifierFlags.contains(.option)
        if let window {
            guard window.isKeyWindow, NSApp.isActive, event.window == nil || event.window === window else { return }
            // A key event's location can be stale. Query the pointer and hit
            // target so overlays and the composer retain their own cursors.
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let owned = ownsPointer(point) ? point : nil
            guard command != commandPressed || option != optionPressed || owned != pointerPoint else { return }
            pointerPoint = owned
        } else {
            guard command != commandPressed || option != optionPressed else { return }
        }
        commandPressed = command
        optionPressed = option
        refreshPointerFeedback()
    }

    private func updatePointerCursor() {
        if rightGesture?.isDragging == true || otherDragPoint != nil {
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
        optionPressed = false
        if (commandCursorSet || rightGesture?.isDragging == true || otherDragPoint != nil), NSCursor.current === NSCursor.closedHand {
            NSCursor.arrow.set()
        }
        commandCursorSet = false
        clearHover()
    }

    private func refreshPointerFeedback() {
        updatePointerCursor()
        guard let point = pointerPoint, !(assemblyGrabbingEnabled && commandPressed),
              !commandGrabGesture, !isAnimatingCamera, rightGesture == nil,
              NSEvent.pressedMouseButtons == 0 else {
            clearHover()
            return
        }
        if optionPressed {
            setHover(solid: part(at: point))
        } else {
            setHover(feature: feature(at: point))
        }
    }

    private func updateHover(with event: NSEvent) {
        trackPointer(with: event)
        refreshPointerFeedback()
    }

    private func clearHover() { setHover() }

    /// Hover previews either a native feature or, with Option, a whole part.
    private func setHover(feature: CADFeatureID? = nil, solid: Int? = nil) {
        guard hoveredFeature != feature || hoveredSolid != solid else { return }
        let solidChanged = hoveredSolid != solid
        hoveredFeature = feature
        hoveredSolid = solid
        // A part's hover tint changes its existing material, like selection.
        let styleChanged = solidChanged && applyStyle()
        if updateFeatureHighlights() || styleChanged { requestRedraw() }
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
            clearHover()
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
            let solid = part(at: point)
            setHover(solid: solid)
            if event.clickCount >= 2 {
                if solid == nil { deselectAll() }
                return
            }
            if let solid { select(selectedSolids.symmetricDifference([solid])) }
            return
        }
        let feature = feature(at: point)
        setHover(feature: feature)
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
        clearHover()
        if commandGrabGesture { deliverAssemblyGrab(at: convert(event.locationInWindow, from: nil)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !commandGrabGesture else { return }
        cancelCameraTransition()
        window?.makeFirstResponder(self)
        clearHover()
        let point = convert(event.locationInWindow, from: nil)
        rightGesture = RightMouseGesture(start: point, previous: point)
    }
    override func rightMouseUp(with event: NSEvent) {
        guard let gesture = rightGesture else { return }
        trackPointer(with: event)
        resetNavigationGesture()
        if !gesture.isDragging {
            showContextMenu(event)
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard var gesture = rightGesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        if !gesture.isDragging {
            guard hypot(point.x - gesture.start.x, point.y - gesture.start.y) >= 3 else { return }
            gesture.isDragging = true
            NSCursor.closedHand.set()
        }
        // Some mouse/remote input paths report zero NSEvent deltas even as
        // their locations move. Track actual cursor travel in view points.
        // AppKit view Y points up; CameraRig's existing mouse Y points down.
        let dx = Double(point.x - gesture.previous.x)
        let dy = Double(gesture.previous.y - point.y)
        gesture.previous = point
        rightGesture = gesture
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
        clearHover()
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
        rightGesture = nil
        otherDragPoint = nil
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
        clearHover()
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
        let selectedFace = selectedFeatures.count == 1 ? selectedFeatures.first : nil
        if canSection || !selectedSolids.isEmpty || selectedFace?.kind == .face,
           let hit = visibleHit(at: convert(event.locationInWindow, from: nil)),
           let solid = solidIndex(of: hit.node) {
            let clickedFace = face(for: hit, solid: solid)
            if let face = selectedFace, clickedFace == face {
                let export = menu.addItem(withTitle: "Export DXF…", action: #selector(menuExportFaceDXF(_:)), keyEquivalent: "")
                export.target = self
                export.representedObject = face
                // A drawing is flat; curved faces have no exact 2D outline.
                export.isEnabled = canExport && topology?.face(for: face)?.type == "PLANE"
            }
            if selectedSolids.contains(solid) {
                let export = menu.addItem(withTitle: "Export STEP…", action: #selector(menuExportSelectedPartsSTEP), keyEquivalent: "")
                export.target = self
                export.isEnabled = canExport
            }
            if canSection, let clickedFace, sectionPlane(for: clickedFace) != nil {
                let section = menu.addItem(withTitle: "Section from This Face", action: #selector(menuSectionFromFace(_:)), keyEquivalent: "")
                section.target = self
                section.representedObject = SectionFaceTarget(face: clickedFace, meshPath: loadedPath, nativePath: loadedNativePath)
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
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
    @objc private func menuExportSelectedPartsSTEP() { onExportSelectedPartsSTEP?() }
    @objc private func menuSectionFromFace(_ sender: NSMenuItem) {
        guard canSection, !isPreparingResources, let target = sender.representedObject as? SectionFaceTarget,
              target.meshPath == loadedPath, target.nativePath == loadedNativePath,
              let plane = sectionPlane(for: target.face) else { return }
        sectionManipulator?.cancelInteraction()
        sectionEnabled = true
        setSectionPlane(plane)
        onSectionFromFace?()
    }
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
        if let p = surfaceHit(at: point)?.worldCoordinates { return SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
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
            guard let hit = surfaceHit(at: NSPoint(x: screen.x, y: screen.y)) else { return true }
            let hitWorld = SIMD3(Double(hit.worldCoordinates.x), Double(hit.worldCoordinates.y), Double(hit.worldCoordinates.z))
            let unitsPerPoint = 2 * rig.orthographicScale / max(bounds.height, 1)
            return simd_dot(hitWorld - world, rig.backward) <= max(rig.radius * 1e-5, unitsPerPoint * 1.5)
        })
    }

    /// The visible part an Option-click at `point` toggles.
    private func part(at point: NSPoint) -> Int? {
        guard bounds.contains(point), let hit = visibleHit(at: point) else { return nil }
        return solidIndex(of: hit.node)
    }

    /// The nearest visible native face, ignoring nearby vertices and edges.
    private func face(at point: NSPoint) -> CADFeatureID? {
        guard let hit = visibleHit(at: point), let solid = solidIndex(of: hit.node) else { return nil }
        return face(for: hit, solid: solid)
    }

    private func face(for hit: SCNHitTestResult, solid: Int) -> CADFeatureID? {
        guard let faces = faceIDsBySolid[solid], faces.indices.contains(hit.faceIndex) else { return nil }
        return faces[hit.faceIndex]
    }

    private func projectFeatures(_ topology: CADTopology) -> ProjectedFeatures {
        // Snapshot the camera once. Recomputing its trigonometric basis for
        // every polyline endpoint stalls the first hover after navigation.
        let projection = rig.projection(width: Double(bounds.width), height: max(Double(bounds.height), 1))
        let plane = presentedSectionPlane
        func worldPoint(_ position: [Double], solid: Int) -> SIMD3<Double>? {
            guard validFeaturePoint(position) else { return nil }
            let original = SIMD4(position[0], position[1], position[2], 1)
            let transformed = solidMatrices[solid].map { $0 * original } ?? original
            return SIMD3(transformed.x, transformed.y, transformed.z)
        }
        func projected(_ world: SIMD3<Double>, id: CADFeatureID) -> ViewportFeaturePicking.Vertex? {
            let (screen, depth) = projection.project(world)
            guard depth > 0, screen.x.isFinite, screen.y.isFinite else { return nil }
            return .init(id: id, world: world, screen: screen, depth: depth)
        }
        let vertices = topology.vertices.compactMap { vertex -> ViewportFeaturePicking.Vertex? in
            guard vertex.seam != true, !hiddenSolids.contains(vertex.id.solidIndex),
                  let world = worldPoint(vertex.position, solid: vertex.id.solidIndex),
                  plane?.contains(world) != false else { return nil }
            return projected(world, id: vertex.id)
        }
        var edges = [ViewportFeaturePicking.Edge]()
        edges.reserveCapacity(topology.edges.count * 4)
        for edge in topology.edges where !hiddenSolids.contains(edge.id.solidIndex) {
            var previous: ViewportFeaturePicking.Vertex?
            for point in edge.polyline {
                let current = worldPoint(point, solid: edge.id.solidIndex).flatMap { projected($0, id: edge.id) }
                if let start = previous, let end = current {
                    if let plane {
                        if let segment = plane.clippedSegment(from: start.world, to: end.world),
                           let clippedStart = segment.from == start.world ? start : projected(segment.from, id: edge.id),
                           let clippedEnd = segment.to == end.world ? end : projected(segment.to, id: edge.id) {
                            edges.append(.init(id: edge.id, start: clippedStart, end: clippedEnd))
                        }
                    } else {
                        edges.append(.init(id: edge.id, start: start, end: end))
                    }
                }
                previous = current
            }
        }
        return ProjectedFeatures(vertices: vertices, edges: edges)
    }

    private func visibleHit(at point: NSPoint) -> SCNHitTestResult? {
        guard let hit = surfaceHit(at: point), solidIndex(of: hit.node) != nil else { return nil }
        return hit
    }

    /// Section caps occlude native geometry, but never become CAD features.
    private func surfaceHit(at point: NSPoint) -> SCNHitTestResult? {
        guard !isPreparingResources, var ray = cameraRay(at: point) else { return nil }
        // Wireframe solids can be visually hidden while their analytic edges
        // remain visible. Query those surfaces too, then explicitly discard
        // user-hidden parts before either selecting or anchoring a zoom.
        let plane = presentedSectionPlane
        if let plane {
            guard let kept = plane.clippedSegment(from: ray.from, to: ray.to) else { return nil }
            // Include the intersection itself despite rounding when SceneKit
            // narrows the ray to float. Clipped faces in this margin are still
            // rejected below.
            let margin = max(rig.radius * 1e-6, 1e-6)
            let direction = simd_normalize(ray.to - ray.from)
            if kept.from != ray.from { ray.from = kept.from - direction * margin }
            if kept.to != ray.to { ray.to = kept.to + direction * margin }
        }
        let caps = plane != nil && mode != .wireframe ? CADViewportCategory.sectionCaps : 0
        func includes(_ hit: SCNHitTestResult) -> Bool {
            if hit.node.categoryBitMask & caps != 0 { return true }
            guard let solid = solidIndex(of: hit.node), !hiddenSolids.contains(solid) else { return false }
            let point = hit.worldCoordinates
            return plane?.contains(SIMD3(Double(point.x), Double(point.y), Double(point.z))) != false
        }
        // The deprecated sortResults option overrides nearest-hit ordering,
        // even with searchMode.closest, and can return a farther solid first.
        var options: [SCNHitTestOption: Any] = [.categoryBitMask: CADViewportCategory.pickableFaces | caps, .ignoreHiddenNodes: false]
        if hiddenSolids.isEmpty {
            options[.searchMode] = SCNHitTestSearchMode.closest.rawValue
            guard let hit = nativeHits(along: ray, options: options).first else { return nil }
            if includes(hit) { return hit }
            if plane == nil { return nil }
        }
        options[.searchMode] = SCNHitTestSearchMode.all.rawValue
        return nativeHits(along: ray, options: options).first(where: includes)
    }

    /// Scene hits along the design camera's ray through a point in view
    /// coordinates, ordered from the eye like the rendered frame's depth.
    func hitTest(_ point: NSPoint, options: [SCNHitTestOption: Any] = [:]) -> [SCNHitTestResult] {
        guard let ray = cameraRay(at: point) else { return [] }
        return nativeHits(along: ray, options: options)
    }

    private func nativeHits(along ray: (from: SIMD3<Double>, to: SIMD3<Double>),
                            options: [SCNHitTestOption: Any]) -> [SCNHitTestResult] {
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
