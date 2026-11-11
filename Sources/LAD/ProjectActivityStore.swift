import Combine
import Foundation

/// Per-design execution history. Only Tool Activity observes this stream;
/// document saving receives explicit dirty/save callbacks instead of forwarding
/// every tool update through the workspace's observable state.
@MainActor
final class ProjectActivityStore: ObservableObject {
    @Published private(set) var tasks: [ProjectTaskAudit] = []
    private(set) var activeTaskID: UUID?
    let images = ProjectActivityImages()

    var onChange: (() -> Void)?
    var onSaveRequested: (() -> Void)?
    private var saveTask: Task<Void, Never>?

    deinit { saveTask?.cancel() }

    func beginCodex(userMessageID: UUID, model: String, effort: String) {
        let task = ProjectTaskAudit(userMessageID: userMessageID, model: model, reasoningEffort: effort)
        tasks.append(task)
        activeTaskID = task.id
    }

    func beginExternal(id: UUID, client: ProjectExternalAgentIdentity, request: String,
                       model: String?, effort: String?) throws {
        guard tasks.count < 10_000 else {
            throw LADError.message("The design is unavailable for another agent task.")
        }
        let task = ProjectTaskAudit(id: id, model: model, reasoningEffort: effort, externalClient: client, request: request)
        try ProjectStore.validateTaskAudits([task], messages: [])
        tasks.append(task)
    }

    func task(id: UUID) -> ProjectTaskAudit? { tasks.first { $0.id == id } }

    func record(_ incoming: ProjectActivityEvent, taskID: UUID? = nil) {
        guard let id = taskID ?? activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if incoming.category == "tool", incoming.status == "completed",
           ["lad_render", "lad_screenshot", "imageView"].contains(incoming.title), let image = incoming.imageData {
            images.store(image, for: ProjectActivityImageKey(taskID: id, eventID: incoming.id))
        }
        var event = incoming
        event.imageData = nil
        if let item = tasks[index].events.firstIndex(where: { $0.id == event.id }) {
            let previous = tasks[index].events[item]
            event.date = previous.date
            if event.input == nil { event.input = previous.input }
            if event.output == nil { event.output = previous.output }
            if event.files == nil { event.files = previous.files }
            guard previous != event else { return }
            tasks[index].events[item] = event
        } else { tasks[index].events.append(event) }
        onChange?()
        scheduleSave()
    }

    /// Steering may be acknowledged just after the initiating task completes.
    /// Its captured audit ID still owns the accepted supplemental message.
    func acknowledgeSteering(taskID: UUID, requestID: UUID, messageID: UUID, content: String, turn: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].additionalUserMessageIDs = (tasks[index].additionalUserMessageIDs ?? []) + [messageID]
        tasks[index].events.append(ProjectActivityEvent(id: "steer:\(requestID.uuidString)", category: "steering",
            title: "Additional design information sent", status: "completed", input: content,
            output: "Accepted by task turn \(turn)."))
    }

    func finishActive(status: String) {
        guard let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        finish(index: index, status: status)
        activeTaskID = nil
    }

    @discardableResult
    func finishExternal(id: UUID, status: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].externalClient != nil, tasks[index].status == "running" else { return false }
        finish(index: index, status: status)
        return true
    }

    func isRunningExternal(id: UUID) -> Bool {
        tasks.contains { $0.id == id && $0.externalClient != nil && $0.status == "running" }
    }

    func externalReceipt(clientID: String, key: String) -> ProjectTaskAudit? {
        tasks.first { $0.externalClient?.clientID == clientID && $0.commitKey == key }
    }

    /// Called synchronously after the design accepts the validated candidate.
    func recordExternalCommit(taskID: UUID, revisionID: UUID, key: String, artifactID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].committedRevisionID = revisionID
        tasks[index].commitKey = key
        tasks[index].commitArtifactID = artifactID
        tasks[index].status = "completed"
        tasks[index].finishedAt = Date()
    }

    func restore(_ saved: [ProjectTaskAudit] = []) {
        cancelPendingSave()
        images.reset()
        activeTaskID = nil
        var restored = saved
        for index in restored.indices where restored[index].status == "running" {
            restored[index].status = "interrupted"
            restored[index].finishedAt = Date()
            for item in restored[index].events.indices where restored[index].events[item].status == "running" {
                restored[index].events[item].status = "interrupted"
            }
        }
        tasks = restored
    }

    /// Any immediate document snapshot includes all audit edits, so its save
    /// consumes the pending activity timer as well.
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    private func finish(index: Int, status: String) {
        for item in tasks[index].events.indices where tasks[index].events[item].status == "running" {
            tasks[index].events[item].status = status == "completed" ? "interrupted" : status
        }
        tasks[index].status = status
        tasks[index].finishedAt = Date()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.onSaveRequested?()
        }
    }
}
