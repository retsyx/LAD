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

struct ProjectTaskAudit: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var userMessageID: UUID
    var startedAt = Date()
    var finishedAt: Date? = nil
    var model: String
    var reasoningEffort: String
    var status = "running"
    var events: [ProjectActivityEvent] = []
    /// Accepted same-turn supplemental messages, separate from the initiating prompt.
    var additionalUserMessageIDs: [UUID]? = nil
}
