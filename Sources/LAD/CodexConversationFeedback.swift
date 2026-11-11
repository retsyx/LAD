import Foundation

/// The CLI calls back from its stream reader. Queue complete message snapshots
/// there, then apply them on the main actor. An explicit final drain preserves
/// ordering even when queued UI notifications run after the process finishes.
final class CodexConversationFeedback: @unchecked Sendable {
    struct Update {
        var messagesChanged: Bool
        var changed: Bool { messagesChanged || !events.isEmpty }
        var activity: String?
        var events: [ProjectActivityEvent]
    }

    private let lock = NSLock()
    private var pending: [String: String] = [:]
    private var order: [String] = []
    private var knownItems: Set<String> = []
    private var messageIDs: [String: UUID] = [:]
    private var latestActivity: String?
    private var closed = false
    private var pendingEvents = [String: ProjectActivityEvent]()
    private var eventOrder = [String]()

    func enqueue(_ event: ProjectActivityEvent, scope: String) {
        var scoped = event
        scoped.id = scope + ":" + event.id
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if pendingEvents[scoped.id] == nil { eventOrder.append(scoped.id) }
        pendingEvents[scoped.id] = scoped
    }

    func enqueue(_ message: CodexProgressMessage, scope: String) {
        let text = String(message.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !text.isEmpty, message.id.utf8.count <= 1_024, scope.utf8.count <= 128 else { return }
        let key = scope + "\u{1f}" + message.id
        lock.lock(); defer { lock.unlock() }
        guard !closed, knownItems.contains(key) || knownItems.count < 128 else { return }
        knownItems.insert(key)
        if pending[key] == nil { order.append(key) }
        pending[key] = text
    }

    func enqueueActivity(_ activity: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        latestActivity = String(activity.prefix(256))
    }

    @MainActor
    func apply(to messages: inout [ChatMessage]) -> Update {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for key in order {
            guard let text = pending[key] else { continue }
            if let id = messageIDs[key], let index = messages.firstIndex(where: { $0.id == id }) {
                if messages[index].content != text {
                    messages[index].content = text
                    changed = true
                }
            } else {
                // Repeated commentary from a new stream item adds no useful
                // transcript entry. A later different update still gets one.
                guard messages.last?.phase != "commentary" || messages.last?.content != text else { continue }
                let message = ChatMessage(role: "assistant", content: text, phase: "commentary")
                messages.append(message)
                messageIDs[key] = message.id
                changed = true
            }
        }
        let activity = latestActivity
        let events = eventOrder.compactMap { pendingEvents[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        latestActivity = nil
        pendingEvents.removeAll(keepingCapacity: true); eventOrder.removeAll(keepingCapacity: true)
        return Update(messagesChanged: changed, activity: activity, events: events)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        pending.removeAll(); order.removeAll(); latestActivity = nil
        pendingEvents.removeAll(); eventOrder.removeAll()
    }
}
