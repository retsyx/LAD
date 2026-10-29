import AppKit
import Combine
import Foundation

enum AgentPermissionPolicy: String, CaseIterable, Sendable {
    case ask
    case alwaysAllow
    case alwaysDeny
}

enum AgentPermissionDecisionSource: String, Sendable {
    case policy
    case user
}

struct AgentPermissionDecision: Equatable, Sendable {
    let allowed: Bool
    let source: AgentPermissionDecisionSource
    let rememberedPolicy: AgentPermissionPolicy?
}

enum AgentPermissionPromptResponse: Equatable, Sendable {
    case decision(allowed: Bool, remember: Bool)
    case cancelled
}

@MainActor
final class AgentPermissionPrompt {
    let operation: String
    let reason: String
    weak var window: NSWindow?

    init(operation: String, reason: String, window: NSWindow?) {
        self.operation = operation
        self.reason = reason
        self.window = window
    }
}

/// Dismissal must not produce an approval. A late presenter callback is ignored
/// after cancellation, window close, or a global policy change.
@MainActor
final class AgentPermissionPresentation {
    private var onDismiss: (@MainActor () -> Void)?

    init(dismiss: @escaping @MainActor () -> Void) { onDismiss = dismiss }

    func dismiss() {
        let action = onDismiss
        onDismiss = nil
        action?()
    }
}

@MainActor
protocol AgentPermissionPresenting {
    func present(_ prompt: AgentPermissionPrompt,
                 completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> AgentPermissionPresentation
}

/// This gate returns permission metadata only. It never installs software or
/// executes the requested operation. Its Mac-local policy is outside projects.
@MainActor
final class AgentPermissionController: ObservableObject {
    static let shared = AgentPermissionController()
    static let preferenceKey = "agentPermissionPolicy"

    @Published var policy: AgentPermissionPolicy {
        didSet {
            guard oldValue != policy else { return }
            defaults.set(policy.rawValue, forKey: Self.preferenceKey)
            applyPolicy()
        }
    }

    private let defaults: UserDefaults
    private let presenter: any AgentPermissionPresenting
    private var pending: [UUID: Request] = [:]
    private var queue: [UUID] = []
    private var activeID: UUID?
    private var presentation: AgentPermissionPresentation?

    init(defaults: UserDefaults = .standard, presenter: (any AgentPermissionPresenting)? = nil) {
        self.defaults = defaults
        self.presenter = presenter ?? NativeAgentPermissionPresenter()
        policy = defaults.string(forKey: Self.preferenceKey).flatMap(AgentPermissionPolicy.init(rawValue:)) ?? .ask
    }

    func request(operation: String, reason: String, window: NSWindow?) async throws -> AgentPermissionDecision {
        try Task.checkCancellation()
        guard !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              operation.utf8.count <= 8_192, reason.utf8.count <= 8_192,
              !operation.contains("\0"), !reason.contains("\0") else {
            throw LADError.message("The agent permission request is empty or too long.")
        }
        let id = UUID()
        let cancellation = AgentPermissionCancellation()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AgentPermissionDecision, Error>) in
                let request = Request(id: id, operation: operation, reason: reason, window: window,
                                      continuation: continuation, cancellation: cancellation)
                pending[id] = request
                queue.append(id)
                if let window {
                    let ownerID = ObjectIdentifier(window)
                    request.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                        object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.ownerClosing(ownerID) }
                        }
                }
                advance()
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func applyPolicy() {
        guard policy != .ask else { advance(); return }
        let decision = AgentPermissionDecision(allowed: policy == .alwaysAllow, source: .policy, rememberedPolicy: policy)
        // Drain a snapshot without presenting another sheet between results.
        for id in queue {
            guard let request = pending[id] else { continue }
            finish(id, result: request.isCancelledOrOrphaned ? .failure(CancellationError()) : .success(decision), advanceQueue: false)
        }
        advance()
    }

    private func advance() {
        guard activeID == nil else { return }
        while let id = queue.first {
            guard let request = pending[id] else { queue.removeFirst(); continue }
            if request.isCancelledOrOrphaned {
                finish(id, result: .failure(CancellationError()), advanceQueue: false)
                continue
            }
            if policy != .ask {
                finish(id, result: .success(AgentPermissionDecision(allowed: policy == .alwaysAllow,
                        source: .policy, rememberedPolicy: policy)), advanceQueue: false)
                continue
            }
            activeID = id
            let shown = presenter.present(request.prompt) { [weak self] response in
                self?.receive(response, for: id)
            }
            // Injectable/native presenters can complete synchronously. Never
            // retain their obsolete token or replace a newer queued dialog.
            if activeID == id { presentation = shown }
            else { shown.dismiss() }
            return
        }
    }

    private func receive(_ response: AgentPermissionPromptResponse, for id: UUID) {
        guard activeID == id, let request = pending[id] else { return }
        guard !request.isCancelledOrOrphaned else { cancel(id); return }
        switch response {
        case .cancelled:
            cancel(id)
        case .decision(let allowed, let remember):
            let remembered: AgentPermissionPolicy? = remember ? (allowed ? .alwaysAllow : .alwaysDeny) : nil
            let decision = AgentPermissionDecision(allowed: allowed, source: .user, rememberedPolicy: remembered)
            finish(id, result: .success(decision), advanceQueue: !remember)
            if let remembered { policy = remembered }
        }
    }

    private func cancel(_ id: UUID) {
        finish(id, result: .failure(CancellationError()))
    }

    private func ownerClosing(_ ownerID: ObjectIdentifier) {
        // Cancel the owner's whole queue before advancing, so a second request
        // cannot briefly present another sheet on the window while it closes.
        for id in queue where pending[id]?.ownerID == ownerID {
            finish(id, result: .failure(CancellationError()), advanceQueue: false)
        }
        advance()
    }

    private func finish(_ id: UUID, result: Result<AgentPermissionDecision, Error>, advanceQueue: Bool = true) {
        guard let request = pending.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        if let observer = request.closeObserver { NotificationCenter.default.removeObserver(observer) }
        let shown: AgentPermissionPresentation?
        if activeID == id {
            activeID = nil
            shown = presentation
            presentation = nil
        } else { shown = nil }
        // Remove state before dismissal: AppKit can synchronously report the
        // aborted sheet, and a test presenter may call back during dismissal.
        shown?.dismiss()
        request.continuation.resume(with: result)
        if advanceQueue { advance() }
    }

    @MainActor
    private final class Request {
        let id: UUID
        let prompt: AgentPermissionPrompt
        let hadOwner: Bool
        let ownerID: ObjectIdentifier?
        let continuation: CheckedContinuation<AgentPermissionDecision, Error>
        let cancellation: AgentPermissionCancellation
        var closeObserver: NSObjectProtocol?

        init(id: UUID, operation: String, reason: String, window: NSWindow?,
             continuation: CheckedContinuation<AgentPermissionDecision, Error>, cancellation: AgentPermissionCancellation) {
            self.id = id
            prompt = AgentPermissionPrompt(operation: operation, reason: reason, window: window)
            hadOwner = window != nil
            ownerID = window.map(ObjectIdentifier.init)
            self.continuation = continuation
            self.cancellation = cancellation
        }

        var isCancelledOrOrphaned: Bool { cancellation.isCancelled || (hadOwner && prompt.window == nil) }
    }
}

/// Cancellation handlers can run off the main actor. Record cancellation before
/// enqueueing its UI cleanup, so a simultaneous button click cannot grant it.
private final class AgentPermissionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

@MainActor
private final class NativeAgentPermissionPresenter: AgentPermissionPresenting {
    func present(_ prompt: AgentPermissionPrompt,
                 completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) -> AgentPermissionPresentation {
        let session = AgentPermissionAlertSession(prompt: prompt, completion: completion)
        session.show()
        return AgentPermissionPresentation { session.dismiss() }
    }
}

@MainActor
private final class AgentPermissionAlertSession: NSObject {
    private let alert = NSAlert()
    private let prompt: AgentPermissionPrompt
    private var completion: (@MainActor (AgentPermissionPromptResponse) -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var finished = false

    init(prompt: AgentPermissionPrompt, completion: @escaping @MainActor (AgentPermissionPromptResponse) -> Void) {
        self.prompt = prompt
        self.completion = completion
        super.init()
    }

    func show() {
        alert.messageText = "Allow this agent request?"
        alert.informativeText = "Applies only to the agent’s temporary task workspace."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for all future requests across all designs on this Mac"
        alert.suppressionButton?.state = .off
        alert.accessoryView = requestView()
        alert.window.title = "Agent Permission"
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: alert.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.complete(.cancelled) }
            }
        if let owner = prompt.window {
            guard owner.isVisible || owner.isMiniaturized else { complete(.cancelled); return }
            if owner.attachedSheet == nil {
                alert.beginSheetModal(for: owner) { [weak self] response in
                    MainActor.assumeIsolated { self?.respond(response) }
                }
            } else {
                // Do not leave an undismissable alert queued behind an unrelated
                // save/open sheet. The controller retains this logical owner.
                showPanel()
            }
        } else {
            // A headless caller may explicitly use an application-level panel.
            // Never borrow NSApp.keyWindow from an unrelated design.
            showPanel()
        }
    }

    private func showPanel() {
        for button in alert.buttons {
            button.target = self
            button.action = #selector(clicked(_:))
        }
        alert.window.styleMask.insert(.closable)
        alert.window.standardWindowButton(.closeButton)?.isEnabled = true
        alert.window.level = .modalPanel
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
    }

    private func requestView() -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.string = "Operation\n\(prompt.operation)\n\nReason\n\(prompt.reason)"
        text.setAccessibilityLabel("Agent permission request")
        scroll.documentView = text
        return scroll
    }

    @objc private func clicked(_ sender: NSButton) {
        respond(sender === alert.buttons[1] ? .alertSecondButtonReturn : .alertFirstButtonReturn)
    }

    private func respond(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            complete(.decision(allowed: false, remember: alert.suppressionButton?.state == .on))
        case .alertSecondButtonReturn:
            complete(.decision(allowed: true, remember: alert.suppressionButton?.state == .on))
        default:
            complete(.cancelled)
        }
    }

    func dismiss() { complete(nil) }

    private func complete(_ response: AgentPermissionPromptResponse?) {
        guard !finished else { return }
        finished = true
        if let observer = closeObserver { NotificationCenter.default.removeObserver(observer) }
        closeObserver = nil
        let callback = completion
        completion = nil
        if let owner = alert.window.sheetParent { owner.endSheet(alert.window, returnCode: .abort) }
        alert.window.orderOut(nil)
        if let response { callback?(response) }
    }
}
