import Foundation
import SceneKit
import XCTest
@testable import LAD

final class ViewportRedrawDriverTests: XCTestCase {
    func testTechniqueCompletionWaitsForTheFinalPassAndRejectsOlderOrDuplicateFrames() {
        let driver = ViewportRedrawDriver()
        let callbacks = ViewportRedrawCallbackCapture()
        let renderer = SCNRenderer(device: nil, options: nil)
        let scene = SCNScene()
        renderer.scene = scene
        driver.forwardedDelegate = callbacks
        driver.setFrameHandler { callbacks.append("acknowledged") }
        driver.setTechniqueCompletionEnabled(true)
        driver.request(at: 10)
        driver.renderer(renderer, updateAtTime: 10)
        driver.renderer(renderer, didRenderScene: scene, atTime: 10)
        XCTAssertEqual(callbacks.events, ["update"], "An intermediate scene pass is not the composited frame")
        XCTAssertNil(driver.pauseDelay(at: 11, quietPeriod: 0.12))
        driver.request(at: 10.01)
        driver.techniqueDidRender(renderer)
        XCTAssertNil(driver.pauseDelay(at: 11, quietPeriod: 0.12), "A late final pass cannot acknowledge newer input")
        driver.renderer(renderer, updateAtTime: 11)
        driver.techniqueDidRender(renderer)
        XCTAssertEqual(driver.pauseDelay(at: 11, quietPeriod: 0.12), 0)
        XCTAssertEqual(callbacks.events.filter { $0 == "acknowledged" }.count, 1)
        XCTAssertEqual(callbacks.events.filter { $0 == "didRender" }.count, 2)
        driver.techniqueDidRender(renderer)
        driver.renderer(renderer, didRenderScene: scene, atTime: 11)
        XCTAssertEqual(callbacks.events.filter { $0 == "didRender" }.count, 3,
            "Report natural exposure frames, while ignoring intermediate native callbacks")
        XCTAssertEqual(callbacks.events.filter { $0 == "acknowledged" }.count, 1,
            "Natural frames cannot acknowledge the same generation twice")
        driver.request(at: 12)
        driver.renderer(renderer, updateAtTime: 12)
        driver.stop()
        driver.techniqueDidRender(renderer)
        XCTAssertEqual(callbacks.events.filter { $0 == "acknowledged" }.count, 1, "Detached views reject late final-pass callbacks")
    }

    func testDelegateBridgeAcknowledgesTheGenerationAtFrameStartAndForwardsExternalCallbacks() {
        let driver = ViewportRedrawDriver()
        let callbacks = ViewportRedrawCallbackCapture()
        driver.forwardedDelegate = callbacks
        driver.setFrameHandler { callbacks.append("acknowledged") }
        // No window or rendered image is needed: exercise SceneKit's delegate
        // lifecycle directly, including a request arriving mid-frame.
        let renderer = SCNRenderer(device: nil, options: nil)
        let scene = SCNScene()
        driver.request(at: 10)
        driver.renderer(renderer, updateAtTime: 10)
        driver.request(at: 10.01)
        driver.renderer(renderer, willRenderScene: scene, atTime: 10)
        driver.renderer(renderer, didRenderScene: scene, atTime: 10)
        XCTAssertEqual(callbacks.events, ["update", "willRender", "didRender"])
        XCTAssertNil(driver.pauseDelay(at: 11, quietPeriod: 0.12),
                     "A request made after frame evaluation begins must wait for another frame.")

        driver.renderer(renderer, updateAtTime: 11)
        driver.renderer(renderer, willRenderScene: scene, atTime: 11)
        driver.renderer(renderer, didRenderScene: scene, atTime: 11)
        XCTAssertEqual(callbacks.events, ["update", "willRender", "didRender", "update", "willRender", "didRender", "acknowledged"])
        XCTAssertEqual(driver.pauseDelay(at: 11, quietPeriod: 0.12), 0)
        driver.renderer(renderer, didRenderScene: scene, atTime: 11)
        XCTAssertEqual(callbacks.events.filter { $0 == "acknowledged" }.count, 1,
                       "An extra completion callback cannot acknowledge the same frame twice.")
    }

    func testDelegateBridgeIgnoresAFrameCompletedAfterStopOrAfterAFreshWakeRequest() {
        let driver = ViewportRedrawDriver()
        let callbacks = ViewportRedrawCallbackCapture()
        driver.setFrameHandler { callbacks.append("acknowledged") }
        let renderer = SCNRenderer(device: nil, options: nil)
        let scene = SCNScene()
        let updateSelector = #selector(SCNSceneRendererDelegate.renderer(_:updateAtTime:))
        XCTAssertFalse(driver.responds(to: updateSelector), "An idle proxy must not create an unnecessary update loop.")
        driver.request(at: 10)
        XCTAssertTrue(driver.responds(to: updateSelector))
        driver.renderer(renderer, updateAtTime: 10)
        driver.stop()
        XCTAssertFalse(driver.responds(to: updateSelector))
        driver.request(at: 20)
        driver.renderer(renderer, didRenderScene: scene, atTime: 10)
        XCTAssertTrue(callbacks.events.isEmpty)
        XCTAssertNil(driver.pauseDelay(at: 30, quietPeriod: 0.12))
        driver.renderer(renderer, updateAtTime: 30)
        driver.renderer(renderer, didRenderScene: scene, atTime: 30)
        XCTAssertEqual(callbacks.events, ["acknowledged"])
        driver.stop()
        XCTAssertFalse(driver.responds(to: updateSelector))
    }

    func testInactiveViewportHasNoPendingFrameOrPauseTimer() {
        let state = ViewportRedrawState()
        XCTAssertNil(state.frameStarted())
        XCTAssertNil(state.pauseDelay(at: 100, quietPeriod: 0.12))
    }

    func testColdDisplayLinkCannotPauseUntilAnActualFrameAcknowledgesTheRequest() {
        var state = ViewportRedrawState()
        let requested = state.request(at: 10)
        XCTAssertEqual(state.frameStarted(), requested)
        // A cold or temporarily stalled drawable may take much longer than
        // the old fixed 120 ms burst to produce its first real frame.
        XCTAssertNil(state.pauseDelay(at: 10.12, quietPeriod: 0.12))
        XCTAssertNil(state.pauseDelay(at: 1_000, quietPeriod: 0.12))
        XCTAssertTrue(state.frameDidRender(generation: requested))
        XCTAssertEqual(state.pauseDelay(at: 1_000, quietPeriod: 0.12), 0)
    }

    func testFrameAlreadyInFlightCannotAcknowledgeANewerCameraOrDisplayChange() throws {
        var state = ViewportRedrawState()
        let first = state.request(at: 10)
        let inFlightFrame = state.frameStarted()
        let second = state.request(at: 10.05)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.frameDidRender(generation: try XCTUnwrap(inFlightFrame)))
        XCTAssertNotEqual(state.renderedGeneration, second)
        XCTAssertNil(state.pauseDelay(at: 11, quietPeriod: 0.12))
        XCTAssertEqual(state.frameStarted(), second)
        XCTAssertTrue(state.frameDidRender(generation: second))
        XCTAssertEqual(state.pauseDelay(at: 11, quietPeriod: 0.12), 0)
    }

    func testNewNavigationResetsTheQuietPeriodAndRequiresItsOwnFrame() throws {
        var state = ViewportRedrawState()
        let first = state.request(at: 10)
        XCTAssertTrue(state.frameDidRender(generation: first))
        XCTAssertEqual(try XCTUnwrap(state.pauseDelay(at: 10.02, quietPeriod: 0.12)), 0.10, accuracy: 0.000_001)

        let second = state.request(at: 10.10)
        XCTAssertNil(state.pauseDelay(at: 10.12, quietPeriod: 0.12))
        XCTAssertTrue(state.frameDidRender(generation: second))
        XCTAssertEqual(try XCTUnwrap(state.pauseDelay(at: 10.12, quietPeriod: 0.12)), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(state.pauseDelay(at: 10.25, quietPeriod: 0.12), 0)
    }

    func testRepeatedFrameCallbacksAcknowledgeEachRequestOnlyOnce() {
        var state = ViewportRedrawState()
        let first = state.request(at: 10)
        XCTAssertTrue(state.frameDidRender(generation: first))
        XCTAssertFalse(state.frameDidRender(generation: first))
        let second = state.request(at: 10.02)
        let third = state.request(at: 10.03)
        XCTAssertFalse(state.frameDidRender(generation: first))
        XCTAssertFalse(state.frameDidRender(generation: second))
        XCTAssertTrue(state.frameDidRender(generation: third))
        XCTAssertFalse(state.frameDidRender(generation: third))
        XCTAssertEqual(state.renderedGeneration, third)
    }

    func testStoppingForDetachOrOcclusionInvalidatesLateFramesAndWakeStartsAFreshRequest() {
        var state = ViewportRedrawState()
        let oldFrame = state.request(at: 10)
        state.stop()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.frameStarted())
        XCTAssertNil(state.pauseDelay(at: 20, quietPeriod: 0.12))
        XCTAssertFalse(state.frameDidRender(generation: oldFrame))

        let awakened = state.request(at: 20)
        XCTAssertNotEqual(awakened, oldFrame)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.frameDidRender(generation: oldFrame))
        XCTAssertNil(state.pauseDelay(at: 30, quietPeriod: 0.12))
        XCTAssertTrue(state.frameDidRender(generation: awakened))
        XCTAssertEqual(state.pauseDelay(at: 30, quietPeriod: 0.12), 0)
        state.stop()
        state.stop()
        XCTAssertFalse(state.frameDidRender(generation: awakened))
        XCTAssertNil(state.pauseDelay(at: 40, quietPeriod: 0.12))
    }

}

private final class ViewportRedrawCallbackCapture: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func append(_ event: String) {
        lock.lock(); values.append(event); lock.unlock()
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) { append("update") }
    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) { append("willRender") }
    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) { append("didRender") }
}
