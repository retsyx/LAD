import simd
import XCTest
@testable import LAD

/// Frames a live viewport's render thread has completed on the GPU, with the
/// design camera pose each one drew.
@MainActor
final class ViewportRenderCounter {
    private weak var view: CADSceneView?
    private var renderedPoses = [(frame: Int, pose: simd_float4x4)]()

    init(_ view: CADSceneView) {
        self.view = view
        view.onFrameRendered = { [weak self, weak view] in
            guard let self, let view, let pose = view.renderedCameraTransform else { return }
            renderedPoses.append((view.renderedFrameCount, pose))
            if renderedPoses.count > 512 { renderedPoses.removeFirst(renderedPoses.count - 512) }
        }
    }

    var count: Int { view?.renderedFrameCount ?? 0 }

    func poses(after frame: Int) -> [simd_float4x4] {
        renderedPoses.filter { $0.frame > frame }.map(\.pose)
    }
}
