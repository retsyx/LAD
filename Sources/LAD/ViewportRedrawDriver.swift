import Foundation
import SceneKit

/// A requested frame is complete only after a frame that started with that
/// request has rendered. Time passing alone cannot acknowledge a drawable.
struct ViewportRedrawState: Sendable {
    private(set) var requestedGeneration: UInt64 = 0
    private(set) var renderedGeneration: UInt64 = 0
    private(set) var isActive = false
    private var lastRequest: TimeInterval = 0

    @discardableResult
    mutating func request(at time: TimeInterval) -> UInt64 {
        requestedGeneration &+= 1
        lastRequest = time
        isActive = true
        return requestedGeneration
    }

    func frameStarted() -> UInt64? { isActive ? requestedGeneration : nil }

    @discardableResult
    mutating func frameDidRender(generation: UInt64) -> Bool {
        guard isActive, generation == requestedGeneration, renderedGeneration != generation else { return false }
        renderedGeneration = generation
        return true
    }

    func pauseDelay(at time: TimeInterval, quietPeriod: TimeInterval) -> TimeInterval? {
        guard isActive, renderedGeneration == requestedGeneration else { return nil }
        return max(0, lastRequest + quietPeriod - time)
    }

    mutating func stop() {
        isActive = false
        requestedGeneration &+= 1
    }
}

/// SceneKit can suspend its display link while its public playback flags still
/// report active. Bound recovery attempts without restarting healthy rendering
/// on every input event, or confusing an old frame with the latest request.
struct ViewportRedrawRecoveryState: Sendable {
    private var observedFrameCount: UInt64?
    private var lastProgressTime: TimeInterval = 0
    private(set) var restartAttempts = 0

    mutating func shouldRestart(at time: TimeInterval, finalFrameCount: UInt64,
                                timeout: TimeInterval = 0.35, maximumAttempts: Int = 3) -> Bool {
        guard observedFrameCount == finalFrameCount else {
            observedFrameCount = finalFrameCount
            lastProgressTime = time
            restartAttempts = 0
            return false
        }
        guard restartAttempts < maximumAttempts, time - lastProgressTime >= timeout else { return false }
        restartAttempts += 1
        lastProgressTime = time
        return true
    }

    mutating func stop() {
        observedFrameCount = nil
        lastProgressTime = 0
        restartAttempts = 0
    }
}

/// SceneKit calls its delegate on the renderer thread. Keep generation facts
/// locked there, while the view controls playback only from the main actor.
final class ViewportRedrawDriver: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var state = ViewportRedrawState()
    private var frameGeneration: UInt64?
    private var frameTime: TimeInterval = 0
    private var completedFrameCount: UInt64 = 0
    private var usesTechniqueCompletion = false
    private weak var externalDelegate: (any SCNSceneRendererDelegate)?
    private var frameHandler: (@Sendable () -> Void)?

    var forwardedDelegate: (any SCNSceneRendererDelegate)? {
        get { lock.lock(); defer { lock.unlock() }; return externalDelegate }
        set { lock.lock(); externalDelegate = newValue; lock.unlock() }
    }

    func setFrameHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); frameHandler = handler; lock.unlock()
    }

    func setTechniqueCompletionEnabled(_ enabled: Bool) {
        lock.lock(); usesTechniqueCompletion = enabled; lock.unlock()
    }

    func request(at time: TimeInterval) {
        lock.lock(); state.request(at: time); lock.unlock()
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.isActive
    }

    var finalFrameCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return completedFrameCount
    }

    func pauseDelay(at time: TimeInterval, quietPeriod: TimeInterval) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return state.pauseDelay(at: time, quietPeriod: quietPeriod)
    }

    func stop() {
        lock.lock(); state.stop(); frameGeneration = nil; lock.unlock()
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        frameGeneration = state.frameStarted()
        frameTime = time
        let delegate = externalDelegate
        lock.unlock()
        delegate?.renderer?(renderer, updateAtTime: time)
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let delegate = forwardedDelegate
        delegate?.renderer?(renderer, willRenderScene: scene, atTime: time)
    }

    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        guard !usesTechniqueCompletion else { lock.unlock(); return }
        completedFrameCount &+= 1
        let acknowledged = frameGeneration.map { state.frameDidRender(generation: $0) } ?? false
        frameGeneration = nil
        let handler = acknowledged ? frameHandler : nil
        let delegate = externalDelegate
        lock.unlock()
        delegate?.renderer?(renderer, didRenderScene: scene, atTime: time)
        handler?()
    }

    func techniqueDidRender(_ renderer: any SCNSceneRenderer) {
        lock.lock()
        guard usesTechniqueCompletion else { lock.unlock(); return }
        completedFrameCount &+= 1
        // AppKit also draws natural layout/exposure frames while playback is
        // paused. Report those actual frames to external delegates without
        // acknowledging a redraw generation that did not start with them.
        let acknowledged = frameGeneration.map { state.frameDidRender(generation: $0) } ?? false
        frameGeneration = nil
        let handler = acknowledged ? frameHandler : nil
        let delegate = externalDelegate
        let time = frameTime
        lock.unlock()
        if let scene = renderer.scene { delegate?.renderer?(renderer, didRenderScene: scene, atTime: time) }
        handler?()
    }

    // Forward other optional callbacks without advertising unused callbacks.
    // Playback itself is stopped once a requested frame has been confirmed.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(SCNSceneRendererDelegate.renderer(_:updateAtTime:)) {
            return isActive || forwardedDelegate?.responds(to: selector) == true
        }
        return super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let delegate = forwardedDelegate, delegate.responds(to: selector) { return delegate }
        return super.forwardingTarget(for: selector)
    }
}

/// No geometry or bounding box: the completion marker must never alter the
/// camera's fitted clipping range or contribute a visible pixel.
final class ViewportTechniqueFrameObserver: NSObject, SCNNodeRendererDelegate {
    private weak var driver: ViewportRedrawDriver?
    private weak var sourceRenderer: (any SCNSceneRenderer)?
    init(driver: ViewportRedrawDriver, renderer: any SCNSceneRenderer) {
        self.driver = driver
        sourceRenderer = renderer
    }
    func renderNode(_ node: SCNNode, renderer: SCNRenderer, arguments: [String: Any]) {
        // The technique's internal SCNRenderer may not expose the owning
        // scene/camera. Forward completion with the original live renderer.
        guard renderer.currentRenderCommandEncoder != nil, let sourceRenderer else { return }
        driver?.techniqueDidRender(sourceRenderer)
    }
}
