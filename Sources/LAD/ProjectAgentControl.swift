import AppKit
import CryptoKit
import Foundation

struct ProjectAgentSnapshot {
    let projectID: UUID
    let editingID: UUID
    let stateToken: String
    let current: ModelSpec?
    let preview: PreviewMesh?
    let versions: ProjectVersionContext
    let partLayout: PartLayout
    let partColors: [String: PartColor]
    let hiddenSolids: Set<Int>
    let solidColors: [Int: PartColor]
}

enum ProjectAgentError: LocalizedError {
    case conflict(String)
    case unavailable
    case denied
    var errorDescription: String? {
        switch self {
        case .conflict(let message): return message
        case .unavailable: return "The agent task or its design is no longer available."
        case .denied: return "This client is not authorized for that operation or design."
        }
    }
}

enum ExternalAgentCapability: String, Codable, CaseIterable, Identifiable {
    case read, build, commit, export, capture, manageProjects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: return "Read designs"
        case .build: return "Build candidates"
        case .commit: return "Commit versions"
        case .export: return "Export STEP"
        case .capture: return "Capture viewport"
        case .manageProjects: return "Create and open designs"
        }
    }
}

/// Only one-way credential digests are persisted. A token is shown to the user
/// once when creating the client; it never enters logs, tasks or design files.
struct ExternalAgentClient: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let credentialHash: String
    var capabilities: Set<ExternalAgentCapability>
    /// nil grants all open designs; a set grants only its stable identities.
    var projectIDs: Set<UUID>?
}

@MainActor
final class ExternalAgentAccess: ObservableObject {
    static let clientsKey = "externalAgentClients"
    @Published private(set) var clients: [ExternalAgentClient]
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clients = defaults.data(forKey: Self.clientsKey).flatMap {
            try? JSONDecoder().decode([ExternalAgentClient].self, from: $0)
        } ?? []
    }

    @discardableResult
    func create(name: String, capabilities: Set<ExternalAgentCapability>, projectIDs: Set<UUID>? = nil) throws -> (client: ExternalAgentClient, token: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), clients.count < 64 else {
            throw LADError.message("Enter a client name of at most 256 bytes; up to 64 clients are supported.")
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let client = ExternalAgentClient(id: UUID(), name: name, credentialHash: SHA256.hexDigest(Data(token.utf8)),
            capabilities: capabilities.union([.read]), projectIDs: projectIDs)
        clients.append(client)
        save()
        return (client, token)
    }

    func revoke(_ id: UUID) { clients.removeAll { $0.id == id }; save() }

    func authenticate(_ header: String?) -> ExternalAgentClient? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst(7))
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let hash = SHA256.hexDigest(Data(token.utf8))
        return clients.first { Self.equalDigest($0.credentialHash, hash) }
    }

    func current(_ id: UUID) -> ExternalAgentClient? { clients.first { $0.id == id } }

    private func save() {
        if let bytes = try? JSONEncoder().encode(clients) { defaults.set(bytes, forKey: Self.clientsKey) }
        onChange?()
    }

    private static func equalDigest(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
