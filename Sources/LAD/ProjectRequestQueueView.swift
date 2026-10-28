import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pending follow-ups remain next to the composer, separate from sent history.
/// No space is reserved for this view when the queue is empty.
struct ProjectRequestQueueView: View {
    @ObservedObject var state: AppState
    @State private var contentHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(state.queuePaused ? "Queue paused" : "Queued")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                Text(state.queuedRequests.count.formatted()).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if state.queuePaused && !state.isWorking {
                    Button { state.resumeQueue() } label: {
                        Label("Resume", systemImage: "play.fill").font(.system(size: 10))
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .help("Run queued requests").accessibilityLabel("Resume queued requests")
                        .disabled(state.editingQueuedRequestID != nil)
                }
            }
            if state.queuePaused, let reason = state.queuePauseReason {
                Text(reason).font(.system(size: 9)).foregroundStyle(Palette.accent)
                    .lineLimit(2).textSelection(.enabled).help(reason)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(state.queuedRequests.enumerated()), id: \.element.id) { index, request in
                        ProjectQueuedRequestCard(state: state, request: request,
                                                 nextID: state.queuedRequests.dropFirst(index + 1).first?.id)
                    }
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ProjectQueueHeightKey.self, value: geometry.size.height)
                })
            }
            .frame(height: min(210, max(40, contentHeight)))
            .onPreferenceChange(ProjectQueueHeightKey.self) { height in
                if height.isFinite, height > 0, abs(contentHeight - height) >= 0.5 { contentHeight = height }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Queued requests")
    }
}

private struct ProjectQueueHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ProjectQueuedRequestCard: View {
    @ObservedObject var state: AppState
    let request: ProjectQueuedRequest
    let nextID: UUID?
    @State private var rowHeight: CGFloat = 44
    @State private var dropEdge: ProjectQueueDropEdge?

    private var isEditing: Bool { state.editingQueuedRequestID == request.id }
    private var isSending: Bool { state.isSendingQueuedRequestID == request.id }
    private var isPreparing: Bool { state.preparingQueuedRequestIDs.contains(request.id) }
    private var editable: Bool {
        !isSending && state.canBeginEditingQueuedRequests && (state.editingQueuedRequestID == nil || isEditing)
    }
    private var canReorder: Bool { editable && !isEditing && state.queuedRequests.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                dragHandle
                if isEditing {
                    Text("Editing in request box").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
                } else {
                    Button { beginEditing() } label: {
                        Text(request.content.isEmpty ? attachmentSummary : request.content)
                            .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain).disabled(!editable)
                    .help("Edit queued request").accessibilityLabel("Edit queued request: \(request.content.isEmpty ? attachmentSummary : request.content)")
                }
                CopyButton(text: isEditing ? state.prompt : request.content, label: "Copy queued request")
                    .disabled((isEditing ? state.prompt : request.content).isEmpty)
                if isSending {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                        .accessibilityLabel("Adding request to current task")
                } else {
                    Button { state.sendQueuedRequestNow(id: request.id) } label: {
                        Image(systemName: "arrow.turn.up.right").font(.system(size: 11, weight: .medium))
                            .scaleEffect(x: 1, y: -1).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .disabled(!state.canSteerQueuedRequests || isPreparing || state.editingQueuedRequestID != nil)
                    .help("Add to current request").accessibilityLabel("Add queued request to current request")
                }
                if !isEditing {
                    Button { beginEditing() } label: { Image(systemName: "pencil").font(.system(size: 10)).frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(!editable)
                        .help("Edit queued request").accessibilityLabel("Edit queued request")
                }
                Button { state.removeQueuedRequest(id: request.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(isSending)
                .help("Remove queued request").accessibilityLabel("Remove queued request")
            }

            if isPreparing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Reading file references…").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }.padding(.leading, 22)
            } else if !(request.attachments ?? []).isEmpty {
                Label(attachmentSummary, systemImage: "paperclip").font(.system(size: 9)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 22)
                    .help((request.attachments ?? []).map(\.name).joined(separator: "\n"))
            }
            if let error = state.queuedRequestErrors[request.id] {
                Text(error).font(.system(size: 9)).foregroundStyle(Palette.accent)
                    .lineLimit(3).textSelection(.enabled).help(error).padding(.leading, 22)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: dropEdge == .after ? .bottom : .top) {
            if dropEdge != nil { RoundedRectangle(cornerRadius: 1).fill(Palette.accent).frame(height: 2) }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { rowHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in rowHeight = height }
        })
        .onDrop(of: [ProjectRequestQueueDrag.type], delegate: ProjectQueueDropDelegate(
            state: state, beforeID: request.id, afterID: nextID, height: rowHeight, dropEdge: $dropEdge))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var dragHandle: some View {
        let handle = Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.muted.opacity(canReorder ? 0.9 : 0.35))
            .frame(width: 16, height: 20).contentShape(Rectangle())
            .help("Drag to reorder queued requests").accessibilityLabel("Reorder queued request")
        if canReorder {
            handle.onDrag {
                ProjectRequestQueueDrag.provider(projectSessionID: state.projectEditingID, requestID: request.id)
            }
            .onHover { hovering in if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
            .accessibilityAction(named: Text("Move earlier")) { moveEarlier() }
            .accessibilityAction(named: Text("Move later")) { moveLater() }
        } else { handle }
    }

    private var attachmentSummary: String {
        let attachments = request.attachments ?? []
        if attachments.count == 1 { return attachments[0].name }
        return "\(attachments.count) attached files"
    }

    private func beginEditing() {
        guard editable else { return }
        state.beginEditingQueuedRequest(id: request.id)
    }

    private func moveEarlier() {
        guard let index = state.queuedRequests.firstIndex(where: { $0.id == request.id }), index > 0 else { return }
        state.moveQueuedRequest(id: request.id, beforeID: state.queuedRequests[index - 1].id)
    }

    private func moveLater() {
        guard let index = state.queuedRequests.firstIndex(where: { $0.id == request.id }), index + 1 < state.queuedRequests.count else { return }
        let before = state.queuedRequests.dropFirst(index + 2).first?.id
        state.moveQueuedRequest(id: request.id, beforeID: before)
    }
}

enum ProjectRequestQueueDrag {
    static let type = UTType(exportedAs: "studio.lad.queued-request")

    struct Payload: Codable, Sendable, Equatable {
        var projectSessionID: UUID
        var requestID: UUID
    }

    static func provider(projectSessionID: UUID, requestID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(Payload(projectSessionID: projectSessionID, requestID: requestID))
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func requestID(from data: Data, projectSessionID: UUID) -> UUID? {
        guard data.count <= 1_024, let value = try? JSONDecoder().decode(Payload.self, from: data),
              value.projectSessionID == projectSessionID else { return nil }
        return value.requestID
    }
}

private enum ProjectQueueDropEdge { case before, after }

private struct ProjectQueueDropDelegate: DropDelegate {
    let state: AppState
    let beforeID: UUID
    let afterID: UUID?
    let height: CGFloat
    @Binding var dropEdge: ProjectQueueDropEdge?

    func validateDrop(info: DropInfo) -> Bool {
        state.editingQueuedRequestID == nil && info.hasItemsConforming(to: [ProjectRequestQueueDrag.type]) &&
            !info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) { updateEdge(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        updateEdge(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { dropEdge = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let provider = info.itemProviders(for: [ProjectRequestQueueDrag.type]).first else { return false }
        let target = info.location.y >= height / 2 ? afterID : beforeID
        let session = state.projectEditingID
        dropEdge = nil
        provider.loadDataRepresentation(forTypeIdentifier: ProjectRequestQueueDrag.type.identifier) { [weak state] data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let state, state.projectEditingID == session,
                      let id = ProjectRequestQueueDrag.requestID(from: data, projectSessionID: session),
                      state.isSendingQueuedRequestID != id, state.editingQueuedRequestID == nil else { return }
                state.moveQueuedRequest(id: id, beforeID: target)
            }
        }
        return true
    }

    private func updateEdge(_ info: DropInfo) {
        guard validateDrop(info: info) else { dropEdge = nil; return }
        dropEdge = info.location.y >= height / 2 ? .after : .before
    }
}
