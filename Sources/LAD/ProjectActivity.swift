import Foundation

/// A source recipe or producer/dependency text captured for execution review.
/// Generated geometry and rendered images do not belong in this collection.
struct ProjectActivityFile: Codable, Sendable, Equatable {
    var name: String
    var path: String
    var data: Data

    static let maximumBytes = 2_000_000
    static let supportedExtensions: Set<String> = ["py", "json", "txt", "toml", "md", "yaml", "yml", "scad", "fs", "sh", "lock", "csv"]
}

/// Public tool/command execution facts. Private reasoning and final CAD JSON
/// are not activity events. Inputs and outputs retain their complete text.
struct ProjectActivityEvent: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var date = Date()
    var category: String
    var title: String
    var status: String
    var input: String? = nil
    var output: String? = nil
    var durationSeconds: Double? = nil
    /// Exact candidate and producer instructions, stored once by content hash.
    var files: [ProjectActivityFile]? = nil
    /// Transient exact PNG for this completed image tool call. The app moves it
    /// into a bounded session cache before retaining the text audit record.
    /// Generated render bytes must never enter a project archive or a prompt.
    var imageData: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case id, date, category, title, status, input, output, durationSeconds, files
    }
}

/// The credential identity and public client metadata of an external agent.
/// Credentials themselves never enter a design or its activity transcript.
struct ProjectExternalAgentIdentity: Codable, Sendable, Equatable {
    var clientID: String
    var name: String
    var version: String? = nil
}

struct ProjectTaskAudit: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var userMessageID: UUID? = nil
    var startedAt = Date()
    var finishedAt: Date? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil
    var status = "running"
    var events: [ProjectActivityEvent] = []
    /// Accepted same-turn supplemental messages, separate from the initiating prompt.
    var additionalUserMessageIDs: [UUID]? = nil
    var externalClient: ProjectExternalAgentIdentity? = nil
    /// The external task's initiating request, independent of the chat composer.
    var request: String? = nil
    /// A persisted receipt lets retried external commits resolve to one revision.
    var committedRevisionID: UUID? = nil
    var commitKey: String? = nil
    var commitArtifactID: String? = nil

    var actorDescription: String {
        if let client = externalClient {
            return ([client.name] + [model, reasoningEffort].compactMap { value in
                value.flatMap { $0.isEmpty ? nil : $0 }
            }).joined(separator: " · ")
        }
        return "\(model.flatMap { $0.isEmpty ? nil : $0 } ?? "Default model") · \(reasoningEffort.flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "Default")"
    }
}
