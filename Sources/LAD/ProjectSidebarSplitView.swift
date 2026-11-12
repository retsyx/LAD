import AppKit
import SwiftUI

/// AppKit owns the divider and pane frames. SwiftUI content never participates
/// in native window sizing or chooses a different split when its content changes.
struct ProjectSidebarSplitView: NSViewRepresentable {
    let state: AppState
    @Binding var isProgramExpanded: Bool

    func makeNSView(context: Context) -> ProjectSidebarNativeSplitView {
        ProjectSidebarNativeSplitView(state: state, isProgramExpanded: $isProgramExpanded)
    }

    func updateNSView(_ view: ProjectSidebarNativeSplitView, context: Context) {
        view.update(state: state, isProgramExpanded: $isProgramExpanded)
    }
}

final class ProjectSidebarNativeSplitView: NSSplitView, NSSplitViewDelegate {
    private let partsPane = NSView()
    private let detailsPane = NSView()
    private let partsHost: NSHostingView<PartsSidebar>
    private let detailsHost: NSHostingView<ProjectDetailsPane>
    private var state: AppState
    private var projectID: UUID
    private var project: ModelSpec?
    private var programExpanded: Bool
    private var preferredFraction: Double
    private var applyingLayout = false
    private var laidOutSize = NSSize.zero
    private var observedPaneFrames: [NSRect] = []

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    init(state: AppState, isProgramExpanded: Binding<Bool>) {
        self.state = state
        projectID = state.projectEditingID
        project = state.current
        programExpanded = isProgramExpanded.wrappedValue
        preferredFraction = state.partsPaneFraction
        partsHost = NSHostingView(rootView: PartsSidebar(state: state))
        detailsHost = NSHostingView(rootView: ProjectDetailsPane(state: state, project: state.current,
                                                               isProgramExpanded: isProgramExpanded))
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        setAccessibilityIdentifier("projectSidebarSplitView")
        for (pane, host) in [(partsPane, partsHost as NSView), (detailsPane, detailsHost as NSView)] {
            pane.autoresizesSubviews = false
            host.autoresizingMask = []
            host.translatesAutoresizingMaskIntoConstraints = true
            pane.addSubview(host)
            addArrangedSubview(pane)
        }
        partsHost.sizingOptions = []
        detailsHost.sizingOptions = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: AppState, isProgramExpanded: Binding<Bool>) {
        let replaced = self.state !== state || projectID != state.projectEditingID
        if replaced {
            self.state = state
            projectID = state.projectEditingID
            partsHost.rootView = PartsSidebar(state: state)
        }
        if replaced || project != state.current || programExpanded != isProgramExpanded.wrappedValue {
            project = state.current
            programExpanded = isProgramExpanded.wrappedValue
            detailsHost.rootView = ProjectDetailsPane(state: state, project: state.current,
                                                      isProgramExpanded: isProgramExpanded)
        }
        // A shared design's other window can move its divider too. Content
        // changes alone do not reassign host roots or touch the preferred split.
        if replaced || preferredFraction != state.partsPaneFraction {
            preferredFraction = state.partsPaneFraction
            layoutPanes()
        }
    }

    override func layout() {
        super.layout()
        if laidOutSize != bounds.size { layoutPanes() }
    }

    private var availableHeight: CGFloat { max(0, bounds.height - dividerThickness) }
    private var minimumPaneHeight: CGFloat { min(72, availableHeight / 2) }

    private func layoutPanes() {
        guard arrangedSubviews.count == 2, !applyingLayout else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        let available = availableHeight
        let height = min(max(available * CGFloat(preferredFraction), minimumPaneHeight), available - minimumPaneHeight)
        partsPane.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        detailsPane.frame = NSRect(x: bounds.minX, y: bounds.minY + height + dividerThickness,
                                   width: bounds.width, height: available - height)
        partsHost.frame = partsPane.bounds
        detailsHost.frame = detailsPane.bounds
        laidOutSize = bounds.size
        observedPaneFrames = arrangedSubviews.map(\.frame)
        needsDisplay = true
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingLayout, availableHeight > 0, arrangedSubviews.count == 2,
              laidOutSize == bounds.size,
              arrangedSubviews.map(\.frame) != observedPaneFrames else { return }
        observedPaneFrames = arrangedSubviews.map(\.frame)
        let fraction = Double(partsPane.frame.height / availableHeight)
        guard fraction.isFinite, (0...1).contains(fraction) else { return }
        preferredFraction = fraction
        state.setPartsPaneFraction(fraction)
        partsHost.frame = partsPane.bounds
        detailsHost.frame = detailsPane.bounds
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, bounds.minY + minimumPaneHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, bounds.minY + availableHeight - minimumPaneHeight)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        super.mouseDown(with: event)
    }
}
