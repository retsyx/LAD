import AppKit
import SwiftUI

@MainActor
struct ExternalAgentSettingsView: View {
    @ObservedObject private var server = ExternalAgentServer.shared
    @ObservedObject private var access = ExternalAgentServer.shared.access
    @State private var name = ""
    @State private var port = ""
    @State private var capabilities: Set<ExternalAgentCapability> = [.read, .build, .commit, .export, .manageProjects]
    @State private var allProjects = true
    @State private var projectIDs = Set<UUID>()
    @State private var availableProjects: [(id: UUID, name: String)] = []
    @State private var feedback: String?

    var body: some View {
        Section("External agents") {
            Toggle("Enable MCP server", isOn: $server.enabled)
            if server.enabled {
                HStack {
                    TextField("Port", text: $port).frame(maxWidth: 180)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort).disabled(Int(port) == server.preferredPort)
                }
                if let endpoint = server.endpoint {
                    Text(endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let error = server.error { Text(error).font(.caption).foregroundStyle(.red).help(error) }
                ForEach(access.clients) { client in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(client.name)
                            Text(client.capabilities.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(client.projectIDs == nil ? "All designs" : "\(client.projectIDs?.count ?? 0) authorized designs")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { access.revoke(client.id) }
                    }
                }
                DisclosureGroup("Add client") {
                    TextField("Client name", text: $name)
                    ForEach(ExternalAgentCapability.allCases.filter { $0 != .read }) { capability in
                        Toggle(capability.title, isOn: Binding(get: { capabilities.contains(capability) }, set: { value in
                            if value { capabilities.insert(capability) } else { capabilities.remove(capability) }
                        }))
                        .disabled(capability == .manageProjects && !allProjects)
                    }
                    Toggle("All designs", isOn: $allProjects)
                        .onChange(of: allProjects) { _, value in if !value { capabilities.remove(.manageProjects) } }
                    if !allProjects {
                        ForEach(availableProjects, id: \.id) { project in
                            Toggle(project.name, isOn: Binding(get: { projectIDs.contains(project.id) }, set: { selected in
                                if selected { projectIDs.insert(project.id) } else { projectIDs.remove(project.id) }
                            }))
                        }
                        Button("Refresh designs", action: refreshProjects)
                    }
                    Button("Create Client and Copy Configuration", action: createClient)
                        .disabled(!server.isRunning || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!allProjects && projectIDs.isEmpty))
                }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).help(feedback) }
            }
        }
        .onAppear { port = String(server.preferredPort); refreshProjects() }
    }

    private func applyPort() {
        guard let value = Int(port), (1024...65535).contains(value) else { feedback = "Choose a port between 1024 and 65535."; return }
        feedback = nil
        server.preferredPort = value
    }

    private func refreshProjects() {
        availableProjects = server.projects.map { ($0.projectDocumentID, $0.projectDisplayName) }
    }

    private func createClient() {
        do {
            let result = try access.create(name: name, capabilities: capabilities, projectIDs: allProjects ? nil : projectIDs)
            do {
                let config = try server.configuration(token: result.token)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(config, forType: .string)
                feedback = "Connection configuration copied. Store it in your agent's configuration; this credential cannot be displayed again."
                name = ""
            } catch { access.revoke(result.client.id); throw error }
        } catch { feedback = error.localizedDescription }
    }
}
