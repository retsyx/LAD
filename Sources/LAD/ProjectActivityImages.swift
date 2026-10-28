import Foundation
import Combine

/// A tool UUID is scoped to one attempt and task. Including the task identity
/// prevents images from one design request appearing in another result row.
struct ProjectActivityImageKey: Hashable, Sendable {
    var taskID: UUID
    var eventID: String
}

struct ProjectActivityImageReference: Identifiable, Sendable {
    var id = UUID()
    var png: Data
}

/// Derived images remain available after the agent's private task directory is
/// removed, without saving screenshots in the design or later agent context.
/// Only encoded PNGs are retained here; views decode their expanded rows lazily.
@MainActor
final class ProjectActivityImages: ObservableObject {
    @Published private(set) var images: [ProjectActivityImageKey: ProjectActivityImageReference] = [:]
    private var order: [ProjectActivityImageKey] = []
    private let maximumImages: Int
    private let maximumBytes: Int

    init(maximumImages: Int = 128, maximumBytes: Int = 128 * 1024 * 1024) {
        self.maximumImages = max(1, maximumImages)
        self.maximumBytes = max(1, maximumBytes)
    }

    func store(_ png: Data, for key: ProjectActivityImageKey) {
        guard png.count <= 32 * 1024 * 1024,
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return }
        guard images[key]?.png != png else { return }
        var retained = images
        order.removeAll { $0 == key }
        order.append(key)
        retained[key] = ProjectActivityImageReference(png: png)
        var bytes = retained.values.reduce(0) { $0 + $1.png.count }
        while order.count > maximumImages || (order.count > 1 && bytes > maximumBytes) {
            if let removed = retained.removeValue(forKey: order.removeFirst()) { bytes -= removed.png.count }
        }
        images = retained
    }

    func reset() { order = []; images = [:] }
}
