import AppKit
import Metal
import SceneKit
import simd

/// SceneKit node categories drawn by the viewport's scene passes. Hit testing
/// queries `faces` only.
enum CADViewportCategory {
    static let faces = 1
    static let decorations = 2
    /// Opaque highlight fills of highlighted faces.
    static let featureFaces = 4
    /// Translucent mode's depth-only copies of each solid's faces.
    static let visibility = 8
    /// Translucent mode's transmittance copies of each solid's faces.
    static let revealage = 16
    /// The geometry-free node that records each frame's camera matrices.
    static let probe = 32
    /// Translucent mode's highlight fills, which replace a highlighted face's
    /// share of the accumulated face color.
    static let featureAccumulation = 64

    static let opaqueScene = faces | decorations | featureFaces | probe
    static let translucentDecorations = visibility | decorations | probe
    static let translucentAccumulation = faces | featureAccumulation
    static let translucentRevealage = revealage
}

/// Translucent faces keep this fraction of their complete shaded color.
enum CADTranslucency {
    static let alpha: Float = 0.28
}

/// Linear highlight colors and the scene background used by the compositor.
struct CADHighlightPalette: Sendable {
    var selected: SIMD4<Float>
    var hover: SIMD4<Float>
    var hoverHalo: SIMD4<Float>
    var ink: SIMD4<Float>
    var background: SIMD4<Float>

    init(selected: NSColor, hover: NSColor, hoverHalo: NSColor, ink: NSColor, background: NSColor) {
        self.selected = Self.linear(selected)
        self.hover = Self.linear(hover)
        self.hoverHalo = Self.linear(hoverHalo)
        self.ink = Self.linear(ink)
        self.background = Self.linear(background)
    }

    static func linear(_ color: NSColor) -> SIMD4<Float> {
        let color = color.usingColorSpace(.extendedSRGB) ?? color
        func linear(_ component: CGFloat) -> Float {
            let value = Double(component)
            return Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        return SIMD4(linear(color.redComponent), linear(color.greenComponent), linear(color.blueComponent),
                     Float(color.alphaComponent))
    }
}

/// Immutable Metal geometry for unoccluded highlights. The live viewport and
/// independent captures share these buffers; nothing writes them after creation.
enum CADHighlightBuffers {
    /// Native edge centerlines (line list) or a vertex center (one point).
    final class Seeds: @unchecked Sendable {
        let positions: any MTLBuffer
        let vertexCount: Int
        let primitive: MTLPrimitiveType
        /// Local bounds, for the highlighted screen area.
        let bounds: [Double]

        init?(device: any MTLDevice, points: [SIMD3<Float>], primitive: MTLPrimitiveType) {
            guard !points.isEmpty else { return nil }
            var packed = [Float]()
            packed.reserveCapacity(points.count * 3)
            var box = CADSilhouetteBatching.Bounds()
            for point in points {
                packed += [point.x, point.y, point.z]
                box.include(point)
            }
            guard let buffer = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<Float>.stride,
                                                 options: .storageModeShared) else { return nil }
            positions = buffer
            vertexCount = points.count
            self.primitive = primitive
            bounds = box.values
        }
    }

    /// A part or face projected as filled coverage for its outline. Faces add
    /// explicit triangle edges so an edge-on face keeps its line projection.
    final class Mask: @unchecked Sendable {
        let positions: any MTLBuffer
        let triangles: (any MTLBuffer)?
        let triangleIndexCount: Int
        let lines: (any MTLBuffer)?
        let lineIndexCount: Int

        init?(device: any MTLDevice, positions: any MTLBuffer, triangleIndices: Data, includeLines: Bool) {
            let count = triangleIndices.count / MemoryLayout<Int32>.stride
            guard count >= 3, let triangles = triangleIndices.withUnsafeBytes({ raw in
                raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: count * MemoryLayout<Int32>.stride,
                                                            options: .storageModeShared) }
            }) else { return nil }
            let triangleCount = count - count % 3
            self.positions = positions
            self.triangles = triangles
            triangleIndexCount = triangleCount
            var lineBuffer: (any MTLBuffer)?, lineCount = 0
            if includeLines {
                var lines = [Int32]()
                lines.reserveCapacity(triangleCount * 2)
                triangleIndices.withUnsafeBytes { raw in
                    let indices = raw.bindMemory(to: Int32.self)
                    for index in stride(from: 0, to: triangleCount, by: 3) {
                        let a = indices[index], b = indices[index + 1], c = indices[index + 2]
                        lines += [a, b, b, c, c, a]
                    }
                }
                lineBuffer = device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<Int32>.stride,
                                               options: .storageModeShared)
                lineCount = lineBuffer == nil ? 0 : lines.count
            }
            self.lines = lineBuffer
            lineIndexCount = lineCount
        }
    }
}

/// Everything a frame needs besides SceneKit's committed scene state.
struct CADViewportFrame: @unchecked Sendable {
    enum SeedChannel: Int, Sendable { case selectedEdge, hoveredEdge, selectedVertex, hoveredVertex }
    struct Seeds {
        var buffer: CADHighlightBuffers.Seeds
        var channel: SeedChannel
        var model: simd_float4x4
    }
    struct Mask {
        var buffer: CADHighlightBuffers.Mask
        var selected: Bool
        var model: simd_float4x4
    }
    /// Disjoint masks share one projection and contour pass.
    struct Batch {
        var rect: CADSilhouetteBatching.Rect
        var masks: [Mask]
    }

    /// Output size in pixels.
    var width: Int
    var height: Int
    /// Logical viewport height in points; screen-point widths scale by
    /// output pixels per point.
    var referenceHeight: Double
    var translucent: Bool
    var palette: CADHighlightPalette
    var seeds: [Seeds] = []
    var batches: [Batch] = []
    /// Projected bounds of every seed and mask, before the highlight kernel.
    var highlightBounds: CADSilhouetteBatching.Rect?
    var verticesEnabled = false

    var hasHighlights: Bool { !seeds.isEmpty || !batches.isEmpty }

    /// Screen-point scale of output pixels, matching the compositing shaders.
    var pixelScale: Double { min(8, max(0.125, Double(height) / max(referenceHeight, 1))) }

    /// Kernel reach in pixels for the active edge (and vertex) styles.
    var kernelRadius: Int {
        let radius = Double(verticesEnabled ? CADHighlightStyle.maximumRadius : CADHighlightStyle.maximumEdgeRadius)
        let largest = Int(ceil(Double(CADHighlightStyle.maximumRadius) * 8 + 0.5))
        return min(largest, Int(ceil(radius * pixelScale + 0.5)))
    }
}

/// The SceneKit objects one frame renders. The live viewport and every
/// capture own separate scene graphs; renderers only read committed state.
final class CADViewportSceneSource: @unchecked Sendable {
    static let decorationsCameraName = "ladTranslucentDecorationsCamera"
    static let accumulationCameraName = "ladTranslucentAccumulationCamera"
    static let revealageCameraName = "ladTranslucentRevealageCamera"
    static let probeName = "ladFrameProbe"

    let scene: SCNScene
    /// The design camera, also used for the opaque scene pass.
    let camera: SCNNode
    let decorationsCamera: SCNNode
    let accumulationCamera: SCNNode
    let revealageCamera: SCNNode
    let probe: CADViewportFrameProbe

    init(scene: SCNScene, camera: SCNNode, decorationsCamera: SCNNode, accumulationCamera: SCNNode,
         revealageCamera: SCNNode, probe: CADViewportFrameProbe) {
        self.scene = scene
        self.camera = camera
        self.decorationsCamera = decorationsCamera
        self.accumulationCamera = accumulationCamera
        self.revealageCamera = revealageCamera
        self.probe = probe
    }

    /// Adds the translucent pass cameras under `camera` and the matrix probe
    /// to `scene`. Pass cameras mirror the design camera's projection.
    static func install(in scene: SCNScene, camera: SCNNode) -> CADViewportSceneSource {
        camera.camera?.categoryBitMask = CADViewportCategory.opaqueScene
        func passCamera(_ name: String, mask: Int) -> SCNNode {
            let node = SCNNode()
            node.name = name
            node.camera = SCNCamera()
            node.camera?.categoryBitMask = mask
            camera.addChildNode(node)
            return node
        }
        let source = CADViewportSceneSource(
            scene: scene, camera: camera,
            decorationsCamera: passCamera(decorationsCameraName, mask: CADViewportCategory.translucentDecorations),
            accumulationCamera: passCamera(accumulationCameraName, mask: CADViewportCategory.translucentAccumulation),
            revealageCamera: passCamera(revealageCameraName, mask: CADViewportCategory.translucentRevealage),
            probe: CADViewportFrameProbe())
        // No geometry or bounds: the probe must never change automatic clipping.
        let probeNode = SCNNode()
        probeNode.name = probeName
        probeNode.categoryBitMask = CADViewportCategory.probe
        probeNode.renderingOrder = 1_000_000
        probeNode.rendererDelegate = source.probe
        scene.rootNode.addChildNode(probeNode)
        source.synchronizeCameras()
        return source
    }

    /// Finds the pass cameras and probe in a cloned scene graph, attaching a
    /// fresh probe so the copy never reports into the original.
    static func adopt(scene: SCNScene, camera: SCNNode) -> CADViewportSceneSource? {
        guard let decorations = camera.childNode(withName: decorationsCameraName, recursively: false),
              let accumulation = camera.childNode(withName: accumulationCameraName, recursively: false),
              let revealage = camera.childNode(withName: revealageCameraName, recursively: false),
              let probeNode = scene.rootNode.childNode(withName: probeName, recursively: true) else { return nil }
        let probe = CADViewportFrameProbe()
        probeNode.rendererDelegate = probe
        return CADViewportSceneSource(scene: scene, camera: camera, decorationsCamera: decorations,
                                      accumulationCamera: accumulation, revealageCamera: revealage, probe: probe)
    }

    /// Copies the design camera's projection into each pass camera.
    func synchronizeCameras() {
        guard let source = camera.camera else { return }
        for node in [decorationsCamera, accumulationCamera, revealageCamera] {
            guard let target = node.camera else { continue }
            if target.fieldOfView != source.fieldOfView { target.fieldOfView = source.fieldOfView }
            if target.projectionDirection != source.projectionDirection { target.projectionDirection = source.projectionDirection }
            if target.usesOrthographicProjection != source.usesOrthographicProjection {
                target.usesOrthographicProjection = source.usesOrthographicProjection
            }
            if target.orthographicScale != source.orthographicScale { target.orthographicScale = source.orthographicScale }
            if target.automaticallyAdjustsZRange != source.automaticallyAdjustsZRange {
                target.automaticallyAdjustsZRange = source.automaticallyAdjustsZRange
            }
            if target.zNear != source.zNear { target.zNear = source.zNear }
            if target.zFar != source.zFar { target.zFar = source.zFar }
            if target.wantsHDR != source.wantsHDR { target.wantsHDR = source.wantsHDR }
            if target.exposureOffset != source.exposureOffset { target.exposureOffset = source.exposureOffset }
        }
    }
}

/// Records the exact view and projection SceneKit used for a scene pass, so
/// highlight passes align with the rendered faces to the pixel.
final class CADViewportFrameProbe: NSObject, SCNNodeRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var viewProjection: simd_float4x4?

    func reset() { lock.withLock { viewProjection = nil } }

    func take() -> simd_float4x4? { lock.withLock { viewProjection } }

    func renderNode(_ node: SCNNode, renderer: SCNRenderer, arguments: [String: Any]) {
        guard let view = (arguments[SCNViewTransform] as? NSValue)?.scnMatrix4Value,
              let projection = (arguments[SCNProjectionTransform] as? NSValue)?.scnMatrix4Value else { return }
        let matrix = simd_float4x4(projection) * simd_float4x4(view)
        lock.withLock { viewProjection = matrix }
    }
}

/// Encodes complete viewport frames: SceneKit scene passes into tile-memory
/// multisample targets, then LAD's own highlight passes. Multisample targets
/// never leave tile memory; highlight targets cover only the highlighted area
/// and exist only while something is highlighted.
final class CADViewportPasses: @unchecked Sendable {
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    private static let sampleCount = 4

    let device: any MTLDevice
    private let pipelines: Pipelines
    private var targets: Targets?

    init(device: any MTLDevice) throws {
        self.device = device
        pipelines = try Pipelines.shared(for: device)
    }

    /// Encodes one frame into `target`, a single-sample `colorFormat` texture
    /// of the frame's size. The renderer must not be used concurrently.
    func encode(_ frame: CADViewportFrame, source: CADViewportSceneSource, renderer: SCNRenderer,
                into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        guard frame.width > 0, frame.height > 0, target.width == frame.width, target.height == frame.height,
              let targets = targets(width: frame.width, height: frame.height) else { return }
        if renderer.scene !== source.scene { renderer.scene = source.scene }
        renderer.usesReverseZ = true
        renderer.autoenablesDefaultLighting = false
        let viewport = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        source.probe.reset()
        var translucentTargets: (decorations: any MTLTexture, accumulated: any MTLTexture, revealage: any MTLTexture)?
        if frame.translucent {
            guard let decorations = targets.decorations(), let accumulated = targets.accumulated(),
                  let revealage = targets.revealage(), let half4 = targets.multisampleHalf4(),
                  let half1 = targets.multisampleHalf1() else { return }
            renderScene(renderer, camera: source.decorationsCamera, viewport: viewport, commandBuffer: commandBuffer,
                        color: targets.multisampleColor, resolve: decorations, clear: MTLClearColor(),
                        depth: targets.multisampleDepth)
            renderScene(renderer, camera: source.accumulationCamera, viewport: viewport, commandBuffer: commandBuffer,
                        color: half4, resolve: accumulated, clear: MTLClearColor(), depth: targets.multisampleDepth)
            renderScene(renderer, camera: source.revealageCamera, viewport: viewport, commandBuffer: commandBuffer,
                        color: half1, resolve: revealage, clear: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1),
                        depth: targets.multisampleDepth)
            translucentTargets = (decorations, accumulated, revealage)
        } else {
            let background = frame.palette.background
            renderScene(renderer, camera: source.camera, viewport: viewport, commandBuffer: commandBuffer,
                        color: targets.multisampleColor, resolve: target,
                        clear: MTLClearColor(red: Double(background.x), green: Double(background.y),
                                             blue: Double(background.z), alpha: Double(background.w)),
                        depth: targets.multisampleDepth)
        }
        let viewProjection = source.probe.take()
        var uniforms = HighlightUniforms(frame: frame)
        var horizontal: (any MTLTexture)?
        if frame.hasHighlights, let viewProjection, let area = highlightArea(frame) {
            uniforms.highlightArea = area
            uniforms.hasHighlights = 1
            horizontal = encodeHighlights(frame, viewProjection: viewProjection, area: area, uniforms: uniforms,
                                          targets: targets, commandBuffer: commandBuffer)
            if horizontal == nil { uniforms.hasHighlights = 0 }
        }
        if let translucentTargets {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "LAD translucent composite"
            encoder.setRenderPipelineState(pipelines.translucentComposite)
            var rect = SIMD4<Float>(-1, -1, 1, 1)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(translucentTargets.accumulated, index: 0)
            encoder.setFragmentTexture(translucentTargets.revealage, index: 1)
            encoder.setFragmentTexture(translucentTargets.decorations, index: 2)
            encoder.setFragmentTexture(horizontal ?? pipelines.empty, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HighlightUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        } else if let horizontal {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "LAD highlight overlay"
            encoder.setRenderPipelineState(pipelines.overlay)
            encoder.setScissorRect(scissor(uniforms.highlightArea))
            var rect = SIMD4<Float>(-1, -1, 1, 1)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(horizontal, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HighlightUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
    }

    // MARK: Scene passes

    private func renderScene(_ renderer: SCNRenderer, camera: SCNNode, viewport: CGRect, commandBuffer: any MTLCommandBuffer,
                             color: any MTLTexture, resolve: any MTLTexture, clear: MTLClearColor, depth: any MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = renderer.usesReverseZ ? 0 : 1
        pass.depthAttachment.storeAction = .dontCare
        renderer.pointOfView = camera
        renderer.render(withViewport: viewport, commandBuffer: commandBuffer, passDescriptor: pass)
    }

    // MARK: Highlight passes

    /// Pixel rectangle (x0, y0, x1, y1 inclusive, top-left origin) that can
    /// receive highlight coverage: every seed and mask plus the kernel reach.
    private func highlightArea(_ frame: CADViewportFrame) -> SIMD4<Int32>? {
        guard let bounds = frame.highlightBounds else { return nil }
        let pixels = pixelRect(bounds, width: frame.width, height: frame.height)
        let radius = frame.kernelRadius
        let x0 = max(0, pixels.x - radius), y0 = max(0, pixels.y - radius)
        let x1 = min(frame.width - 1, pixels.x + pixels.width - 1 + radius)
        let y1 = min(frame.height - 1, pixels.y + pixels.height - 1 + radius)
        guard x0 <= x1, y0 <= y1 else { return nil }
        return SIMD4(Int32(x0), Int32(y0), Int32(x1), Int32(y1))
    }

    /// Top-left-origin pixel rectangle covering an NDC rectangle.
    private func pixelRect(_ rect: CADSilhouetteBatching.Rect, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let x0 = Int(floor((rect.low.x + 1) / 2 * Double(width)))
        let x1 = Int(ceil((rect.high.x + 1) / 2 * Double(width)))
        let y0 = Int(floor((1 - rect.high.y) / 2 * Double(height)))
        let y1 = Int(ceil((1 - rect.low.y) / 2 * Double(height)))
        let left = min(max(0, x0), width), top = min(max(0, y0), height)
        let right = min(max(left, x1), width), bottom = min(max(top, y1), height)
        return (left, top, right - left, bottom - top)
    }

    /// The NDC rectangle of a top-left-origin pixel rectangle.
    private func remap(x: Int, y: Int, width: Int, height: Int, frame: CADViewportFrame) -> SIMD4<Float> {
        let fw = Float(frame.width), fh = Float(frame.height)
        return SIMD4(Float(x) / fw * 2 - 1, 1 - Float(y + height) / fh * 2,
                     Float(x + width) / fw * 2 - 1, 1 - Float(y) / fh * 2)
    }

    private func scissor(_ area: SIMD4<Int32>) -> MTLScissorRect {
        MTLScissorRect(x: Int(area.x), y: Int(area.y), width: Int(area.z - area.x + 1), height: Int(area.w - area.y + 1))
    }

    /// A pass restricted to the top-left `width`×`height` pixels of `target`.
    private func restrictedPass(_ target: any MTLTexture, width: Int, height: Int,
                                multisample: (any MTLTexture)? = nil) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        if let multisample {
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
        }
        pass.renderTargetWidth = width
        pass.renderTargetHeight = height
        return pass
    }

    /// Seeds and contours, then the horizontal distance pass. Every texture
    /// here covers only the highlight area, whose origin maps to texel zero.
    /// Returns the horizontal distances read by the final compositor.
    private func encodeHighlights(_ frame: CADViewportFrame, viewProjection: simd_float4x4, area: SIMD4<Int32>,
                                  uniforms: HighlightUniforms, targets: Targets,
                                  commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let areaX = Int(area.x), areaY = Int(area.y)
        let areaWidth = Int(area.z - area.x) + 1, areaHeight = Int(area.w - area.y) + 1
        guard let multisampleMask = targets.multisampleMask(),
              let seedMask = targets.areaTexture("seeds", .rgba8Unorm, width: areaWidth, height: areaHeight),
              let horizontal = targets.areaTexture("horizontal", .rgba16Float, width: areaWidth, height: areaHeight)
        else { return nil }
        let areaViewport = MTLViewport(originX: 0, originY: 0, width: Double(areaWidth), height: Double(areaHeight),
                                       znear: 0, zfar: 1)
        let areaRemap = remap(x: areaX, y: areaY, width: areaWidth, height: areaHeight, frame: frame)
        guard let seedEncoder = commandBuffer.makeRenderCommandEncoder(descriptor:
                restrictedPass(seedMask, width: areaWidth, height: areaHeight, multisample: multisampleMask)) else { return nil }
        seedEncoder.label = "LAD highlight seeds"
        seedEncoder.setViewport(areaViewport)
        for item in frame.seeds {
            let points = item.buffer.primitive == .point
            seedEncoder.setRenderPipelineState(points ? pipelines.seedPoints : pipelines.seedLines)
            var mask = MaskUniforms(modelViewProjection: viewProjection * item.model, remap: areaRemap,
                                    channel: Self.channel(item.channel))
            seedEncoder.setVertexBuffer(item.buffer.positions, offset: 0, index: 0)
            seedEncoder.setVertexBytes(&mask, length: MemoryLayout<MaskUniforms>.stride, index: 1)
            seedEncoder.setFragmentBytes(&mask, length: MemoryLayout<MaskUniforms>.stride, index: 1)
            seedEncoder.drawPrimitives(type: item.buffer.primitive, vertexStart: 0, vertexCount: item.buffer.vertexCount)
        }
        seedEncoder.endEncoding()

        for batch in frame.batches {
            let pixels = pixelRect(batch.rect, width: frame.width, height: frame.height)
            guard pixels.width > 0, pixels.height > 0,
                  let scratch = targets.areaTexture("mask", .rgba8Unorm, width: pixels.width, height: pixels.height),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor:
                    restrictedPass(scratch, width: pixels.width, height: pixels.height, multisample: multisampleMask))
            else { continue }
            encoder.label = "LAD outline coverage"
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(pixels.width),
                                            height: Double(pixels.height), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipelines.mask)
            // Map exactly this batch's pixels onto the restricted target.
            let batchRemap = remap(x: pixels.x, y: pixels.y, width: pixels.width, height: pixels.height, frame: frame)
            for item in batch.masks {
                var mask = MaskUniforms(modelViewProjection: viewProjection * item.model, remap: batchRemap,
                                        channel: item.selected ? SIMD4(1, 0, 0, 0) : SIMD4(0, 1, 0, 0))
                encoder.setVertexBuffer(item.buffer.positions, offset: 0, index: 0)
                encoder.setVertexBytes(&mask, length: MemoryLayout<MaskUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&mask, length: MemoryLayout<MaskUniforms>.stride, index: 1)
                if let triangles = item.buffer.triangles, item.buffer.triangleIndexCount > 0 {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: item.buffer.triangleIndexCount,
                                                  indexType: .uint32, indexBuffer: triangles, indexBufferOffset: 0)
                }
                if let lines = item.buffer.lines, item.buffer.lineIndexCount > 0 {
                    encoder.drawIndexedPrimitives(type: .line, indexCount: item.buffer.lineIndexCount,
                                                  indexType: .uint32, indexBuffer: lines, indexBufferOffset: 0)
                }
            }
            encoder.endEncoding()

            // The batch lies inside the highlight area, whose seeds it joins.
            guard let contourEncoder = commandBuffer.makeRenderCommandEncoder(descriptor:
                    restrictedPass(seedMask, width: areaWidth, height: areaHeight)) else { continue }
            contourEncoder.label = "LAD outline contour"
            contourEncoder.setViewport(areaViewport)
            contourEncoder.setRenderPipelineState(pipelines.contour)
            let x = max(0, pixels.x - areaX), y = max(0, pixels.y - areaY)
            contourEncoder.setScissorRect(MTLScissorRect(x: x, y: y, width: max(0, min(pixels.width, areaWidth - x)),
                                                         height: max(0, min(pixels.height, areaHeight - y))))
            var rect = SIMD4<Float>(-1, -1, 1, 1)
            contourEncoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var region = SIMD4<Int32>(Int32(pixels.x - areaX), Int32(pixels.y - areaY), Int32(pixels.width), Int32(pixels.height))
            contourEncoder.setFragmentTexture(scratch, index: 0)
            contourEncoder.setFragmentBytes(&region, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
            contourEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            contourEncoder.endEncoding()
        }

        let distances = MTLRenderPassDescriptor()
        distances.colorAttachments[0].texture = horizontal
        distances.colorAttachments[0].loadAction = .dontCare
        distances.colorAttachments[0].storeAction = .store
        distances.renderTargetWidth = areaWidth
        distances.renderTargetHeight = areaHeight
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: distances) else { return nil }
        encoder.label = "LAD highlight distances"
        encoder.setViewport(areaViewport)
        encoder.setRenderPipelineState(pipelines.horizontal)
        var rect = SIMD4<Float>(-1, -1, 1, 1)
        var uniforms = uniforms
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(seedMask, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HighlightUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return horizontal
    }

    private static func channel(_ channel: CADViewportFrame.SeedChannel) -> SIMD4<Float> {
        switch channel {
        case .selectedEdge: SIMD4(1, 0, 0, 0)
        case .hoveredEdge: SIMD4(0, 1, 0, 0)
        case .selectedVertex: SIMD4(0, 0, 1, 0)
        case .hoveredVertex: SIMD4(0, 0, 0, 1)
        }
    }

    // MARK: Targets

    private func targets(width: Int, height: Int) -> Targets? {
        if let targets, targets.width == width, targets.height == height { return targets }
        targets = Targets(device: device, width: width, height: height)
        return targets
    }

    /// Per-size render targets. Multisample attachments are memoryless; the
    /// stored single-sample targets are created only once a frame needs them.
    private final class Targets {
        let width: Int
        let height: Int
        let multisampleColor: any MTLTexture
        let multisampleDepth: any MTLTexture
        private let device: any MTLDevice
        private var cache: [String: any MTLTexture] = [:]

        init?(device: any MTLDevice, width: Int, height: Int) {
            guard let color = Self.make(device, CADViewportPasses.colorFormat, width, height, multisample: true),
                  let depth = Self.make(device, .depth32Float, width, height, multisample: true) else { return nil }
            self.device = device
            self.width = width
            self.height = height
            multisampleColor = color
            multisampleDepth = depth
        }

        func multisampleHalf4() -> (any MTLTexture)? { texture("ms.rgba16f", .rgba16Float, multisample: true) }
        func multisampleHalf1() -> (any MTLTexture)? { texture("ms.r16f", .r16Float, multisample: true) }
        func multisampleMask() -> (any MTLTexture)? { texture("ms.mask", .rgba8Unorm, multisample: true) }
        func decorations() -> (any MTLTexture)? { texture("decorations", CADViewportPasses.colorFormat) }
        func accumulated() -> (any MTLTexture)? { texture("accumulated", .rgba16Float) }
        func revealage() -> (any MTLTexture)? { texture("revealage", .r16Float) }

        /// A texture at least `width`×`height`, for passes restricted to that
        /// region. Sizes round up so ordinary hover movement reuses it, and a
        /// much larger texture is released once highlights become small again.
        func areaTexture(_ key: String, _ format: MTLPixelFormat, width: Int, height: Int) -> (any MTLTexture)? {
            let granule = 128
            func rounded(_ value: Int, limit: Int) -> Int { min(limit, (value + granule - 1) / granule * granule) }
            if let texture = cache[key], texture.width >= width, texture.height >= height,
               texture.width * texture.height <= max(4 * width * height, granule * granule * 4) {
                return texture
            }
            cache[key] = nil
            guard let texture = Self.make(device, format, rounded(width, limit: self.width),
                                          rounded(height, limit: self.height), multisample: false) else { return nil }
            cache[key] = texture
            return texture
        }

        private func texture(_ key: String, _ format: MTLPixelFormat, multisample: Bool = false) -> (any MTLTexture)? {
            if let texture = cache[key] { return texture }
            let texture = Self.make(device, format, width, height, multisample: multisample)
            cache[key] = texture
            return texture
        }

        static func make(_ device: any MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
                         multisample: Bool) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                      mipmapped: false)
            if multisample {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = CADViewportPasses.sampleCount
                descriptor.usage = .renderTarget
                descriptor.storageMode = .memoryless
            } else {
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
            }
            return device.makeTexture(descriptor: descriptor)
        }
    }

    // MARK: Pipelines

    private struct MaskUniforms {
        var modelViewProjection: simd_float4x4
        var remap: SIMD4<Float>
        var channel: SIMD4<Float>
    }

    /// Mirrors `CADHighlightUniforms` in the shader source.
    private struct HighlightUniforms {
        var selected: SIMD4<Float>
        var hover: SIMD4<Float>
        var hoverHalo: SIMD4<Float>
        var ink: SIMD4<Float>
        var background: SIMD4<Float>
        var referenceHeight: Float
        var verticesEnabled: Float
        var hasHighlights: Float = 0
        /// Output pixels; screen-point widths scale by this over the reference.
        var frameHeight: Float
        /// Frame pixels (x0, y0, x1, y1 inclusive) covered by the area targets.
        var highlightArea = SIMD4<Int32>(0, 0, -1, -1)

        init(frame: CADViewportFrame) {
            selected = frame.palette.selected
            hover = frame.palette.hover
            hoverHalo = frame.palette.hoverHalo
            ink = frame.palette.ink
            background = frame.palette.background
            referenceHeight = Float(max(1, frame.referenceHeight))
            verticesEnabled = frame.verticesEnabled ? 1 : 0
            frameHeight = Float(frame.height)
        }
    }

    private final class Pipelines: @unchecked Sendable {
        let seedLines: any MTLRenderPipelineState
        let seedPoints: any MTLRenderPipelineState
        let mask: any MTLRenderPipelineState
        let contour: any MTLRenderPipelineState
        let horizontal: any MTLRenderPipelineState
        let overlay: any MTLRenderPipelineState
        let translucentComposite: any MTLRenderPipelineState
        let empty: any MTLTexture

        private static let lock = NSLock()
        private static var cache: [UInt64: Pipelines] = [:]

        static func shared(for device: any MTLDevice) throws -> Pipelines {
            try lock.withLock {
                if let cached = cache[device.registryID] { return cached }
                let created = try Pipelines(device: device)
                cache[device.registryID] = created
                return created
            }
        }

        private init(device: any MTLDevice) throws {
            let library = try device.makeLibrary(source: CADViewportPasses.shaderSource, options: nil)
            func function(_ name: String) throws -> any MTLFunction {
                guard let function = library.makeFunction(name: name) else {
                    throw LADError.message("LAD's viewport shaders are incomplete.")
                }
                return function
            }
            func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, samples: Int = 1,
                          blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { _ in }) throws
                -> any MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = try function(vertex)
                descriptor.fragmentFunction = try function(fragment)
                descriptor.rasterSampleCount = samples
                let attachment: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
                attachment.pixelFormat = format
                blend(attachment)
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            // Coverage channels combine without depending on draw order.
            let maximum: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { attachment in
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .max
                attachment.alphaBlendOperation = .max
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            let samples = CADViewportPasses.sampleCount
            seedLines = try pipeline("cad_mask_vertex", "cad_mask_fragment", format: .rgba8Unorm, samples: samples, blend: maximum)
            seedPoints = try pipeline("cad_point_vertex", "cad_mask_fragment", format: .rgba8Unorm, samples: samples, blend: maximum)
            mask = try pipeline("cad_mask_vertex", "cad_mask_fragment", format: .rgba8Unorm, samples: samples, blend: maximum)
            contour = try pipeline("cad_quad", "cad_contour", format: .rgba8Unorm, blend: maximum)
            horizontal = try pipeline("cad_quad", "cad_highlight_horizontal", format: .rgba16Float)
            // Premultiplied highlight layers over the resolved scene.
            overlay = try pipeline("cad_quad", "cad_highlight_overlay", format: CADViewportPasses.colorFormat) { attachment in
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            translucentComposite = try pipeline("cad_quad", "cad_translucent_composite", format: CADViewportPasses.colorFormat)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .private
            guard let empty = device.makeTexture(descriptor: descriptor) else {
                throw LADError.message("LAD could not allocate viewport resources.")
            }
            self.empty = empty
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CADQuadOut { float4 position [[position]]; };
    struct CADPointOut { float4 position [[position]]; float size [[point_size]]; };
    struct CADMaskUniforms { float4x4 modelViewProjection; float4 remap; float4 channel; };
    struct CADHighlightUniforms {
        float4 selectedColor;
        float4 hoverColor;
        float4 hoverHaloColor;
        float4 inkColor;
        float4 backgroundColor;
        float referenceHeight;
        float verticesEnabled;
        float hasHighlights;
        float frameHeight;
        int4 highlightArea;
    };

    constant float cadEdgeHoverRadius = \(Float(CADHighlightStyle.hoverEdgeWidth / 2))f;
    constant float cadEdgeSelectedRadius = \(Float(CADHighlightStyle.selectedEdgeWidth / 2))f;
    constant float cadEdgeHoverHaloRadius = \(Float(CADHighlightStyle.hoverEdgeHaloWidth / 2))f;
    constant float cadEdgeSelectedHaloRadius = \(Float(CADHighlightStyle.selectedEdgeHaloWidth / 2))f;
    constant float cadVertexHoverRadius = \(Float(CADHighlightStyle.hoverVertexDiameter / 2))f;
    constant float cadVertexSelectedRadius = \(Float(CADHighlightStyle.selectedVertexDiameter / 2))f;
    constant float cadVertexHoverHaloRadius = \(Float(CADHighlightStyle.hoverVertexHaloDiameter / 2))f;
    constant float cadVertexSelectedHaloRadius = \(Float(CADHighlightStyle.selectedVertexHaloDiameter / 2))f;
    constant float cadMaximumEdgeRadius = \(Float(CADHighlightStyle.maximumEdgeRadius))f;
    constant float cadMaximumRadius = \(Float(CADHighlightStyle.maximumRadius))f;
    // Bound the kernel while retaining complete circles at the largest
    // supported independent-capture scale (8×), including antialias coverage.
    constant int cadMaximumKernelRadius = \(Int(ceil(Double(CADHighlightStyle.maximumRadius) * 8 + 0.5)));

    vertex CADQuadOut cad_quad(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        CADQuadOut out;
        out.position = float4(mix(rect.xy, rect.zw, corner), 0.0f, 1.0f);
        return out;
    }

    // Remaps a frame's NDC sub-rectangle onto the pass viewport. Depth and
    // w are untouched, so SceneKit's near and far clipping still applies.
    static float4 cad_mask_clip(float3 position, constant CADMaskUniforms &u) {
        float4 clip = u.modelViewProjection * float4(position, 1.0f);
        float2 center = (u.remap.xy + u.remap.zw) * 0.5f;
        float2 extent = (u.remap.zw - u.remap.xy) * 0.5f;
        clip.xy = (clip.xy - center * clip.w) / extent;
        return clip;
    }

    vertex CADQuadOut cad_mask_vertex(const device packed_float3 *positions [[buffer(0)]],
                                      constant CADMaskUniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
        CADQuadOut out;
        out.position = cad_mask_clip(float3(positions[vid]), u);
        return out;
    }

    vertex CADPointOut cad_point_vertex(const device packed_float3 *positions [[buffer(0)]],
                                        constant CADMaskUniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
        CADPointOut out;
        out.position = cad_mask_clip(float3(positions[vid]), u);
        out.size = 1.0f;
        return out;
    }

    fragment float4 cad_mask_fragment(constant CADMaskUniforms &u [[buffer(1)]]) { return u.channel; }

    // Coverage minus its four-neighbor interior is the projected outline.
    // Reads clamp to this batch's region, which is padded inside the frame
    // and coincides with the frame edge where a large surface is clipped.
    fragment float4 cad_contour(CADQuadOut in [[stage_in]], texture2d<float, access::read> mask [[texture(0)]],
                                constant int4 &region [[buffer(0)]]) {
        int2 last = region.zw - 1;
        int2 p = clamp(int2(in.position.xy) - region.xy, int2(0), last);
        float2 covered = step(0.5f, mask.read(uint2(p)).rg);
        float2 interior = covered;
        interior = min(interior, step(0.5f, mask.read(uint2(max(p - int2(1, 0), int2(0)))).rg));
        interior = min(interior, step(0.5f, mask.read(uint2(min(p + int2(1, 0), last))).rg));
        interior = min(interior, step(0.5f, mask.read(uint2(max(p - int2(0, 1), int2(0)))).rg));
        interior = min(interior, step(0.5f, mask.read(uint2(min(p + int2(0, 1), last))).rg));
        return float4(covered - interior, 0.0f, 0.0f);
    }

    static float cad_scale(constant CADHighlightUniforms &u) {
        return clamp(u.frameHeight / max(u.referenceHeight, 1.0f), 0.125f, 8.0f);
    }

    static int cad_radius(float scale, constant CADHighlightUniforms &u) {
        float maximumRadius = u.verticesEnabled > 0.5f ? cadMaximumRadius : cadMaximumEdgeRadius;
        return min(cadMaximumKernelRadius, int(ceil(maximumRadius * scale + 0.5f)));
    }

    // Highlight-area textures map the area's first pixel to texel zero; no
    // seed lies outside the area, so reads stop at its edges.
    fragment float4 cad_highlight_horizontal(CADQuadOut in [[stage_in]], texture2d<float, access::read> seeds [[texture(0)]],
                                             constant CADHighlightUniforms &u [[buffer(0)]]) {
        int2 center = int2(in.position.xy);
        int lastColumn = u.highlightArea.z - u.highlightArea.x;
        float scale = cad_scale(u);
        bool verticesEnabled = u.verticesEnabled > 0.5f;
        int radius = cad_radius(scale, u);
        float4 best = float4(65504.0f);
        int first = max(-radius, -center.x);
        int last = min(radius, lastColumn - center.x);
        for (int dx = first; dx <= last; ++dx) {
            // RG are selected/hover edges; BA are selected/hover vertices.
            float4 seed = seeds.read(uint2(center + int2(dx, 0)));
            float distance = float(dx) * float(dx);
            if (seed.r > 0.01f) { best.r = min(best.r, distance); }
            if (seed.g > 0.01f) { best.g = min(best.g, distance); }
            if (verticesEnabled) {
                if (seed.b > 0.01f) { best.b = min(best.b, distance); }
                if (seed.a > 0.01f) { best.a = min(best.a, distance); }
            }
        }
        return best;
    }

    // `local` is a pixel's position within the highlight area.
    static float4 cad_distances(int2 local, texture2d<float, access::read> horizontal, float scale,
                                constant CADHighlightUniforms &u) {
        int radius = cad_radius(scale, u);
        int lastRow = u.highlightArea.w - u.highlightArea.y;
        int first = max(-radius, -local.y);
        int last = min(radius, lastRow - local.y);
        float4 best = float4(65504.0f);
        for (int dy = first; dy <= last; ++dy) {
            best = min(best, horizontal.read(uint2(local + int2(0, dy))) + float(dy) * float(dy));
        }
        return sqrt(best);
    }

    // Applies each style layer in order. `color` is premultiplied by the
    // combined layer coverage, `transmittance` is what remains of the base.
    static void cad_layer(thread float3 &color, thread float &transmittance, float4 layer, float coverage) {
        float alpha = coverage * layer.a;
        color = mix(color, layer.rgb, alpha);
        transmittance *= 1.0f - alpha;
    }

    static float4 cad_highlight(float4 distance, float scale, constant CADHighlightUniforms &u) {
        float3 color = float3(0.0f);
        float transmittance = 1.0f;
        // A one-pixel transition preserves the same logical widths on Retina
        // and independent agent captures, without changing the seed geometry.
        cad_layer(color, transmittance, u.hoverHaloColor, saturate(cadEdgeHoverHaloRadius * scale + 0.5f - distance.g));
        cad_layer(color, transmittance, u.hoverColor, saturate(cadEdgeHoverRadius * scale + 0.5f - distance.g));
        bool verticesEnabled = u.verticesEnabled > 0.5f;
        if (verticesEnabled) {
            cad_layer(color, transmittance, u.hoverHaloColor, saturate(cadVertexHoverHaloRadius * scale + 0.5f - distance.a));
            cad_layer(color, transmittance, u.hoverColor, saturate(cadVertexHoverRadius * scale + 0.5f - distance.a));
        }
        // Every selected feature wins over every hovered feature; vertices
        // stay legible where they coincide with a selected edge endpoint.
        cad_layer(color, transmittance, u.inkColor, saturate(cadEdgeSelectedHaloRadius * scale + 0.5f - distance.r));
        cad_layer(color, transmittance, u.selectedColor, saturate(cadEdgeSelectedRadius * scale + 0.5f - distance.r));
        if (verticesEnabled) {
            cad_layer(color, transmittance, u.inkColor, saturate(cadVertexSelectedHaloRadius * scale + 0.5f - distance.b));
            cad_layer(color, transmittance, u.selectedColor, saturate(cadVertexSelectedRadius * scale + 0.5f - distance.b));
        }
        return float4(color, 1.0f - transmittance);
    }

    fragment float4 cad_highlight_overlay(CADQuadOut in [[stage_in]], texture2d<float, access::read> horizontal [[texture(0)]],
                                          constant CADHighlightUniforms &u [[buffer(0)]]) {
        int2 local = int2(in.position.xy) - u.highlightArea.xy;
        float scale = cad_scale(u);
        return cad_highlight(cad_distances(local, horizontal, scale, u), scale, u);
    }

    fragment float4 cad_translucent_composite(CADQuadOut in [[stage_in]],
                                              texture2d<float, access::read> accumulated [[texture(0)]],
                                              texture2d<float, access::read> revealage [[texture(1)]],
                                              texture2d<float, access::read> decorations [[texture(2)]],
                                              texture2d<float, access::read> horizontal [[texture(3)]],
                                              constant CADHighlightUniforms &u [[buffer(0)]]) {
        int2 center = int2(in.position.xy);
        float4 sum = accumulated.read(uint2(center));
        float reveal = saturate(revealage.read(uint2(center)).r);
        float coverage = 1.0f - reveal;
        float3 averageColor = sum.rgb / max(sum.a, 1.0e-5f);
        float4 result = float4(averageColor * coverage + u.backgroundColor.rgb * reveal,
                               coverage + u.backgroundColor.a * reveal);
        float4 decoration = decorations.read(uint2(center));
        result = decoration + result * (1.0f - saturate(decoration.a));
        if (u.hasHighlights > 0.5f && all(center >= u.highlightArea.xy) && all(center <= u.highlightArea.zw)) {
            float scale = cad_scale(u);
            float4 highlight = cad_highlight(cad_distances(center - u.highlightArea.xy, horizontal, scale, u), scale, u);
            result = float4(highlight.rgb + result.rgb * (1.0f - highlight.a), result.a);
        }
        return result;
    }
    """
}
