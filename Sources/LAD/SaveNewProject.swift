import Foundation

/// A separate design starts from the latest validated model and its own turn,
/// without carrying unrelated conversation or modeling history into the copy.
enum SaveNewProject {
    static func snapshot(from original: LADProject) throws -> LADProject {
        guard var revision = original.revisions.last else {
            throw LADError.message("There is no design to save.")
        }
        let messages = conversation(for: revision, in: original.messages)
        revision.userMessageID = messages.first?.id
        revision.responseMessageID = messages.last?.id
        if revision.parts == nil, let preview = revision.preview {
            guard (1...4_096).contains(preview.solids) else {
                throw LADError.message("The saved design contains an invalid solid count.")
            }
            revision.parts = preview.parts ?? (0..<preview.solids).map {
                PartNode(id: "solid/\($0)", name: "Part \($0 + 1)", solidIndices: [$0])
            }
        }
        if revision.partLayout == nil { revision.partLayout = revision.parts.map { PartLayout(nodes: $0) } }
        revision.runtime = revision.runtime ?? revision.preview?.runtime
        revision.preview = nil
        revision.stepData = nil
        let retainedMessageIDs = Set(messages.map(\.id))
        let taskAudits = original.taskAudits?.filter { $0.userMessageID == revision.userMessageID }.map { audit in
            var audit = audit
            let additional = audit.additionalUserMessageIDs?.filter(retainedMessageIDs.contains) ?? []
            audit.additionalUserMessageIDs = additional.isEmpty ? nil : additional
            return audit
        }
        return LADProject(messages: messages, revisions: [revision], selectedRevisionID: revision.id,
                          projectID: UUID(), codexSettings: original.codexSettings,
                          projectName: original.projectName, showGrid: original.showGrid,
                          projectionMode: original.projectionMode, displayMode: original.displayMode,
                          recentPartColors: original.recentPartColors,
                          taskAudits: taskAudits?.isEmpty == true ? nil : taskAudits)
    }

    private static func conversation(for revision: ProjectRevision, in messages: [ChatMessage]) -> [ChatMessage] {
        if let userID = revision.userMessageID, let responseID = revision.responseMessageID,
           let user = messages.firstIndex(where: { $0.id == userID }),
           let response = messages.firstIndex(where: { $0.id == responseID }),
           user < response, messages[user].role == "user", messages[response].role == "assistant",
           messages[response].phase != "commentary" {
            return [messages[user], messages[response]]
        }

        // Older designs did not associate turns with revisions. A validated
        // closeout follows its revision's commit; its user request precedes it.
        // The date bounds prevent a later failed request from being attached to
        // the last successful model. Commentary is never a validated closeout.
        let summary = revision.model.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var precedingUser: Int?
        var candidates: [(user: Int, response: Int)] = []
        for index in messages.indices {
            let message = messages[index]
            if message.role == "user" { precedingUser = index; continue }
            guard message.role == "assistant", message.phase != "commentary",
                  let user = precedingUser,
                  messages[user].date <= revision.date, revision.date <= message.date else { continue }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.phase == "final_answer" || content == summary ||
                  content == summary + "\n\nDesign ready." || content == summary + "\n\nModel ready." else { continue }
            candidates.append((user, index))
        }
        guard let pair = candidates.min(by: { messages[$0.response].date < messages[$1.response].date }) else { return [] }
        return [messages[pair.user], messages[pair.response]]
    }
}
