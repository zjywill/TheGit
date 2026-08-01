import SwiftUI

/// Three-pane layout for one repository:
/// sidebar (branches) | graph | commit panel.
///
/// The right two panes double as the window's reading surface — a diff, a
/// file history, an issue, a pull request — see `workArea`.
struct RepoView: View {
    @ObservedObject var repo: RepoState
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarDragStartWidth: CGFloat?

    /// User-dragged pane widths, persisted across relaunches and Launchpad
    /// round-trips. The sidebar writes only when its drag ends; publishing
    /// UserDefaults on every pointer move would re-enter layout at 60fps.
    @State private var sidebarIdealWidth = RepoView.storedSidebarWidth()
    @State private var commitIdealWidth = RepoView.storedWidth(
        key: RepoView.commitWidthKey, fallback: 300)

    private static let sidebarWidthKey = "sidebarPaneWidth"
    private static let commitWidthKey = "commitPanelWidth"
    private static let sidebarWidthRange: ClosedRange<CGFloat> = 252...332

    private static func storedWidth(key: String, fallback: CGFloat) -> CGFloat {
        let width = UserDefaults.standard.double(forKey: key)
        return width > 0 ? CGFloat(width) : fallback
    }

    private static func storedSidebarWidth() -> CGFloat {
        let width = storedWidth(key: sidebarWidthKey, fallback: 292)
        return sidebarWidthRange ~= width ? width : 292
    }

    /// Direct UserDefaults, not @AppStorage: the divider reports a width
    /// per frame while dragged, and @AppStorage would republish and
    /// rebuild all three panes at 60fps (same trap as the commit message
    /// box, see CommitPanelView).
    private static func store(_ width: CGFloat, key: String) {
        UserDefaults.standard.set(Double(width), forKey: key)
    }

    var body: some View {
        // Only the sidebar is keyed on the repo, and nothing above it is.
        // An id here is a demolition order: it makes SwiftUI throw the
        // subtree away and build a new one on every switch, and the graph
        // and commit panes were paying it for state they can just as well
        // hold on the repo (the lane offset) or already do (the selection).
        // Alternating five runs of each shape, summing main-thread time in
        // the 700ms after each switch: 277ms median keyed, 191ms not.
        // The sidebar keeps its id — its filter box is genuinely view-local
        // and has to reset per tab.
        HStack(spacing: 0) {
            // The .id lives on the sidebar INSIDE a stable wrapper, never
            // on the split child itself: an id there hands the pane a
            // brand-new pane on every tab switch, and it re-balances all
            // three panes back to ideal widths — user-dragged widths died
            // on every switch. The ZStack keeps the pane's identity; only
            // the sidebar (and its per-tab filter box) resets.
            RepoSidebarShell(repo: repo)
                .frame(width: sidebarIdealWidth)
                .ignoresSafeArea(.container, edges: .top)

            VStack(spacing: 0) {
                // Tabs fill the title-bar row beside the sidebar's traffic
                // lights. They stay present on every repository detail view.
                RepoTabsBar(fillsTitleBar: true)
                Divider()
                if let update = updates.update {
                    UpdateBanner(
                        update: update,
                        openReleasePage: { updates.openReleasePage() },
                        dismiss: { updates.skipCurrentUpdate() }
                    )
                    Divider()
                }
                // Repository commands stay directly below their active tab.
                RepoCommandBar(repo: repo)
                Divider()
                workArea
            }
            .animation(
                .easeOut(duration: reduceMotion ? 0 : 0.2),
                value: updates.update
            )
            // The graph and commit panel minima together. The window floor
            // keeps the complete split above this constraint.
            .frame(minWidth: 660)
            .ignoresSafeArea(.container, edges: .top)
        }
        // A transparent resize target replaces HSplitView's visible divider.
        // It keeps the panel directly draggable without drawing a straight
        // line through the capsule's rounded top and bottom.
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                SidebarResizeHandle(
                    dragChanged: resizeSidebar,
                    dragEnded: finishResizingSidebar
                )
                .frame(width: 8, height: geometry.size.height)
                .offset(x: sidebarIdealWidth - 4)
            }
        }
        // Match the floating Settings sidebar from Issue #34: content owns
        // the whole window height and the native traffic lights live inside
        // the sidebar's own title row.
        .ignoresSafeArea(.container, edges: .top)
        .background(RepoWindowChrome())
        // Bottom centre of the panes, which lands over the oldest loaded
        // commits — the one part of this window nobody is reading when a
        // command fails. The other two candidates are both worse: the
        // bottom right is the Commit button, and the top is the row that
        // just changed, or failed to.
        .overlay(alignment: .bottom) { ErrorToastLayer(repo: repo) }
        // On its own layer, not in the chain below: a .sheet stacked with
        // the alerts and confirmationDialog on this same view never
        // presents — they compete for one presentation slot, and the
        // sheet loses. Color.clear gives it a view of its own.
        .background(
            Color.clear
                .sheet(isPresented: $repo.showCleanup) { CleanupView(repo: repo) }
        )
        // Same one-slot rule as above: each sheet gets its own layer.
        .background(
            Color.clear
                .sheet(isPresented: $repo.showCreatePR) { CreatePullRequestView(repo: repo) }
        )
        // Keyed on the repo, not on view identity: this view is no longer
        // rebuilt per tab (see the note on the panes above), so a plain
        // `.task` would only ever fire for the first repo shown.
        .task(id: repo.id) { await repo.appeared() }
        // Refresh quietly whenever the app regains focus — changes made
        // in a terminal or editor show up without pressing ⌘R.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await repo.refresh(quiet: true) }
        }
        // The mark lives exactly as long as the menu does.
        .onReceive(NotificationCenter.default.publisher(
            for: NSMenu.didEndTrackingNotification)) { _ in
            repo.contextTarget = nil
        }
        // A drop is never the decision — this menu is. Dragging stays free
        // of consequences right up until a button here is clicked.
        .confirmationDialog(
            repo.dropIntent?.title ?? "",
            isPresented: Binding(
                get: { repo.dropIntent != nil },
                set: { if !$0 { repo.dropIntent = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let intent = repo.dropIntent {
                switch intent {
                case .branchOnBranch(let source, let target):
                    Button("Merge \(source) into \(target)") {
                        repo.mergeDropped(source: source, into: target)
                    }
                    Button("Rebase \(target) onto \(source)") {
                        repo.rebaseDropped(target: target, onto: source)
                    }
                case .commitOnBranch(let commit, let target):
                    Button("Cherry-pick \(commit.shortHash) onto \(target)") {
                        repo.cherryPickDropped(commit, onto: target)
                    }
                }
                Button("Cancel", role: .cancel) { repo.dropIntent = nil }
            }
        } message: {
            if let intent = repo.dropIntent, repo.needsCheckout(intent) {
                Text("\(intent.target) is not checked out — it will be checked out first.")
            }
        }
        .alert(
            "Discard ALL changes?",
            isPresented: $repo.confirmDiscardAll
        ) {
            Button("Discard Everything", role: .destructive) { repo.discardAllChanges() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All staged and unstaged changes are restored to HEAD and untracked files are deleted. This cannot be undone.")
        }
        .alert(
            "Hard reset to \(repo.commitToHardReset?.shortHash ?? "")?",
            isPresented: Binding(
                get: { repo.commitToHardReset != nil },
                set: { if !$0 { repo.commitToHardReset = nil } }
            )
        ) {
            Button("Hard Reset", role: .destructive) { repo.confirmHardReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All uncommitted changes and commits after this point will be permanently discarded.")
        }
    }

    private func resizeSidebar(_ translation: CGFloat) {
        let start = sidebarDragStartWidth ?? sidebarIdealWidth
        if sidebarDragStartWidth == nil {
            sidebarDragStartWidth = start
        }
        sidebarIdealWidth = min(
            Self.sidebarWidthRange.upperBound,
            max(Self.sidebarWidthRange.lowerBound, start + translation)
        )
    }

    private func finishResizingSidebar() {
        sidebarDragStartWidth = nil
        Self.store(sidebarIdealWidth, key: Self.sidebarWidthKey)
    }

    /// Everything but the sidebar: the graph and the commit panel, and the
    /// two sizes of reading pane that cover them.
    ///
    /// Two sizes, because the two kinds of reading want different amounts of
    /// the window:
    ///
    /// - A **diff or file history** covers the GRAPH only. The commit panel
    ///   is where you clicked the file from and where the next one is —
    ///   covering it would end the review at file one.
    /// - An **issue or pull request** covers the graph AND the commit panel.
    ///   Neither has anything to do with staging, and a commit box you can't
    ///   use while reading is 300pt of a reading column given to nothing.
    ///
    /// Both are drawn OVER the panes rather than swapped in place of them,
    /// and that is not laziness — a swap takes the panes out of the view
    /// tree, and three things come off with them:
    ///
    /// 1. The graph's scroll position, which is ScrollView state and resets
    ///    to the top on rebuild. Closing a pull request would dump you back
    ///    at HEAD. (`graphScrollX` was moved onto RepoState for this same
    ///    reason; the vertical offset hasn't been.)
    /// 2. ~190ms of rebuild, measured for this subtree — paid on every
    ///    close, where an overlay pays nothing.
    /// 3. The commit panel's dragged width: `commitIdealWidth` is read from
    ///    UserDefaults once per view identity on purpose (a live value
    ///    re-enters layout mid-drag), so a rebuilt split would come back at
    ///    whatever width the app launched with.
    ///
    /// Behind an opaque pane the panes below don't redraw — nothing changes
    /// their state — so keeping them alive costs approximately nothing.
    ///
    /// Its own property rather than more of `body`: inline, the nested split
    /// plus four conditional panes is one expression big enough to time the
    /// type checker out.
    private var workArea: some View {
        ZStack {
            HSplitView {
                ZStack {
                    GraphView(repo: repo)
                    if let history = repo.fileHistory {
                        FileHistoryView(
                            repo: repo, path: history.path, commits: history.commits
                        )
                    }
                    if repo.selectedFile != nil {
                        FileDiffView(repo: repo)
                            // Fast fade-in masks the abrupt full-panel
                            // swap; removal stays instant — close is
                            // usually Esc, and keyboard actions never
                            // animate.
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.12)),
                                removal: .identity
                            ))
                    }
                }
                .frame(minWidth: 400)
                .layoutPriority(1)
                Group {
                    // Selecting a commit swaps the right panel to its
                    // details, GitKraken-style; ZStack keeps the split
                    // widths stable.
                    ZStack {
                        CommitPanelView(repo: repo)
                        if let commit = repo.selectedCommitObject {
                            CommitDetailView(repo: repo, commit: commit)
                        }
                    }
                }
                .frame(minWidth: 260, idealWidth: commitIdealWidth, maxWidth: 420)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    Self.store($0, key: Self.commitWidthKey)
                }
            }
            // An issue and a pull request share ONE wrapper, and the
            // transition lives on it while the per-item .id lives on the
            // view inside: the id change (another issue, or a request
            // where an issue was) swaps content instantly, and only the
            // panel's arrival over the graph fades. Two wrappers meant an
            // issue-to-request swap was a removal plus an insertion — the
            // new panel faded up from nothing and the graph showed
            // through, which is exactly what a repo switch looks like
            // when the two tabs have different kinds open.
            if repo.issueToView != nil || repo.prToView != nil {
                ZStack {
                    if let issue = repo.issueToView {
                        IssueDetailView(repo: repo, issue: issue)
                            // Identity per issue: switching issues in the
                            // sidebar must reset the scroll position, not
                            // keep the old one's offset. The repo is part
                            // of it because the id here is only a number —
                            // two tabs both reading #3 are two different
                            // #3s, and without the prefix the second one
                            // inherits the first one's scroll position.
                            .id("\(repo.id)#issue\(issue.id)")
                    }
                    if let pr = repo.prToView {
                        PullRequestDetailView(repo: repo, pr: pr)
                            .id("\(repo.id)#pr\(pr.id)")
                    }
                }
                // No animation on the transition itself — one attached
                // there plays whenever the panel is inserted, including
                // when a repo switch simply reveals the panel that tab
                // already had open, and nobody asked for a fade there.
                // The animation comes from the transaction at the call
                // site instead (see viewIssue/viewPullRequest in
                // SidebarView), so it runs when the user opens a panel
                // and only then. Removal stays instant — close is usually
                // Esc, and keyboard actions never animate.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
    }
}

/// Lets the repository's custom tabs and floating sidebar own the title-bar
/// row while AppKit keeps ownership of the real traffic-light controls.
private struct RepoWindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var titlebarAppearedTransparent = false
        private var titleWasVisible = true
        private var hadFullSizeContentView = false
        private var toolbarWasVisible: Bool?
        private var separatorStyle: NSTitlebarSeparatorStyle?

        func attach(to window: NSWindow) {
            if self.window !== window {
                restore()
                self.window = window
                titlebarAppearedTransparent = window.titlebarAppearsTransparent
                titleWasVisible = window.titleVisibility == .visible
                hadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
                toolbarWasVisible = window.toolbar?.isVisible
                separatorStyle = window.titlebarSeparatorStyle
            }
            apply(to: window)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    self?.apply(to: window)
                }
            }
        }

        private func apply(to window: NSWindow) {
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            // The repository draws its own tab row in this space. Keeping an
            // empty toolbar visible would cover that row even though the
            // content extends under the title bar.
            window.toolbar?.isVisible = false
        }

        func restore() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            if let window {
                window.titlebarAppearsTransparent = titlebarAppearedTransparent
                window.titleVisibility = titleWasVisible ? .visible : .hidden
                if !hadFullSizeContentView {
                    window.styleMask.remove(.fullSizeContentView)
                }
                if let separatorStyle {
                    window.titlebarSeparatorStyle = separatorStyle
                }
                if let toolbarWasVisible {
                    window.toolbar?.isVisible = toolbarWasVisible
                }
            }
            window = nil
            toolbarWasVisible = nil
            separatorStyle = nil
        }

        deinit {
            restore()
        }
    }
}

/// The same floating sidebar shell used by the Settings window in Issue #34.
/// The repository's high-volume navigator remains ScrollView-backed; only
/// its structural chrome is shared with the verified Settings design.
private struct RepoSidebarShell: View {
    @ObservedObject var repo: RepoState

    private static let titleBarHeight: CGFloat = 52
    private static let capsuleInset: CGFloat = 8
    private static let capsuleRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RepoWindowControls()
                    .frame(width: 54, height: 20)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(height: Self.titleBarHeight - Self.capsuleInset)
            SidebarView(repo: repo)
                .id(repo.id)
        }
        .background(RepoSidebarMaterial())
        .clipShape(
            RoundedRectangle(
                cornerRadius: Self.capsuleRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: Self.capsuleRadius,
                style: .continuous
            )
            .stroke(Color.primary.opacity(0.10))
        )
        .padding(.leading, Self.capsuleInset)
        .padding(.vertical, Self.capsuleInset)
    }
}

/// `NSVisualEffectView` in sidebar material, matching SettingsRootView.
/// SwiftUI material blends only inside the opaque window and reads flat.
private struct RepoSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Stable traffic-light geometry inside the floating sidebar. AppKit keeps
/// the actual window and its actions; these controls only replace the title
/// bar's visible buttons, whose bare-titlebar position is too close to the
/// capsule edge and is reasserted during every resize.
private struct RepoWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> RepoWindowControlHostView {
        RepoWindowControlHostView()
    }

    func updateNSView(_ view: RepoWindowControlHostView, context: Context) {
        view.attachIfNeeded()
    }

    static func dismantleNSView(
        _ view: RepoWindowControlHostView,
        coordinator: ()
    ) {
        view.restore()
    }
}

fileprivate enum RepoWindowControlKind: CaseIterable {
    case close
    case miniaturize
    case zoom

    var windowButton: NSWindow.ButtonType {
        switch self {
        case .close: return .closeButton
        case .miniaturize: return .miniaturizeButton
        case .zoom: return .zoomButton
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close: return "Close window"
        case .miniaturize: return "Minimize window"
        case .zoom: return "Zoom window"
        }
    }
}

private final class RepoWindowControlHostView: NSView {
    private struct OriginalControl {
        let button: NSButton
        let wasHidden: Bool
        let alpha: CGFloat
    }

    private weak var managedWindow: NSWindow?
    private var originalControls: [OriginalControl] = []
    private var observers: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?
    private var groupIsHovered = false {
        didSet { updateButtonAppearance() }
    }

    private lazy var buttons: [RepoWindowControlButton] = {
        RepoWindowControlKind.allCases.map { kind in
            let button = RepoWindowControlButton(kind: kind)
            button.target = self
            button.action = #selector(performWindowAction(_:))
            button.setAccessibilityLabel(kind.accessibilityLabel)
            addSubview(button)
            return button
        }
    }()

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(index) * 20,
                y: 0,
                width: 14,
                height: bounds.height
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        groupIsHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        groupIsHovered = false
    }

    func attachIfNeeded() {
        guard let window else { return }
        if managedWindow !== window {
            restore()
            managedWindow = window
            originalControls = RepoWindowControlKind.allCases.compactMap { kind in
                guard let button = window.standardWindowButton(kind.windowButton)
                else { return nil }
                return OriginalControl(
                    button: button,
                    wasHidden: button.isHidden,
                    alpha: button.alphaValue
                )
            }
            observe(window)
        }
        hideOriginalControls()
        updateButtonAppearance()
        needsLayout = true
    }

    @objc private func performWindowAction(_ sender: RepoWindowControlButton) {
        guard let window = managedWindow else { return }
        switch sender.kind {
        case .close:
            window.performClose(sender)
        case .miniaturize:
            window.performMiniaturize(sender)
        case .zoom:
            window.performZoom(sender)
        }
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ].map { name in
            center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                self?.hideOriginalControls()
                self?.updateButtonAppearance()
            }
        }
    }

    private func hideOriginalControls() {
        for control in originalControls {
            control.button.isHidden = true
            control.button.alphaValue = 0
        }
        for (button, kind) in zip(buttons, RepoWindowControlKind.allCases) {
            button.isEnabled =
                managedWindow?.standardWindowButton(kind.windowButton)?.isEnabled
                ?? true
        }
    }

    private func updateButtonAppearance() {
        let isActive =
            managedWindow?.isKeyWindow == true
            || managedWindow?.isMainWindow == true
        for button in buttons {
            button.windowIsActive = isActive
            button.groupIsHovered = groupIsHovered
        }
    }

    func restore() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = []
        for control in originalControls {
            control.button.isHidden = control.wasHidden
            control.button.alphaValue = control.alpha
        }
        originalControls = []
        managedWindow = nil
    }
}

private final class RepoWindowControlButton: NSButton {
    fileprivate let kind: RepoWindowControlKind

    var windowIsActive = false {
        didSet { needsDisplay = true }
    }
    var groupIsHovered = false {
        didSet { needsDisplay = true }
    }

    init(kind: RepoWindowControlKind) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 14
        let circle = NSRect(
            x: 0,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: circle)
        fillColor.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(windowIsActive ? 0.16 : 0.10).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        guard windowIsActive, groupIsHovered else { return }
        drawHoverSymbol(in: circle)
    }

    private var fillColor: NSColor {
        guard windowIsActive else {
            let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua
                ? NSColor(srgbRed: 0.34, green: 0.34, blue: 0.35, alpha: 1)
                : NSColor(srgbRed: 0.76, green: 0.76, blue: 0.77, alpha: 1)
        }

        let color: NSColor
        switch kind {
        case .close:
            color = NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .miniaturize:
            color = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1)
        case .zoom:
            color = NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
        }
        return isHighlighted
            ? color.blended(withFraction: 0.18, of: .black) ?? color
            : color
    }

    private func drawHoverSymbol(in circle: NSRect) {
        let symbol = NSBezierPath()
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let radius: CGFloat = 2.3

        switch kind {
        case .close:
            symbol.move(to: NSPoint(x: center.x - radius, y: center.y - radius))
            symbol.line(to: NSPoint(x: center.x + radius, y: center.y + radius))
            symbol.move(to: NSPoint(x: center.x + radius, y: center.y - radius))
            symbol.line(to: NSPoint(x: center.x - radius, y: center.y + radius))
        case .miniaturize:
            symbol.move(to: NSPoint(x: center.x - radius, y: center.y))
            symbol.line(to: NSPoint(x: center.x + radius, y: center.y))
        case .zoom:
            symbol.move(to: NSPoint(x: center.x - radius, y: center.y))
            symbol.line(to: NSPoint(x: center.x + radius, y: center.y))
            symbol.move(to: NSPoint(x: center.x, y: center.y - radius))
            symbol.line(to: NSPoint(x: center.x, y: center.y + radius))
        }

        NSColor.black.withAlphaComponent(0.58).setStroke()
        symbol.lineWidth = 1
        symbol.lineCapStyle = .round
        symbol.stroke()
    }
}

private struct SidebarResizeHandle: View {
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void
    @State private var cursorIsPushed = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragChanged($0.translation.width) }
                    .onEnded { _ in dragEnded() }
            )
            .onHover { hovering in
                if hovering, !cursorIsPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorIsPushed = true
                } else if !hovering, cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                }
            }
            .onDisappear {
                if cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                }
            }
            .accessibilityHidden(true)
    }
}

/// Commands scoped to the repository selected by the tab directly above.
/// Keeping this out of the window toolbar makes the hierarchy explicit:
/// app navigation first, then actions for that navigation target.
struct RepoCommandBar: View {
    @ObservedObject var repo: RepoState
    @FocusState private var searchFocused: Bool
    @Environment(\.uiZoom) private var zoom
    @AppStorage("pullMode") private var pullModeRaw = RepoState.PullMode.ff.rawValue
    @State private var showingPullOptions = false

    private var pullMode: RepoState.PullMode {
        RepoState.PullMode(rawValue: pullModeRaw) ?? .ff
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            commandRow(.regular)
            commandRow(.compact)
        }
        .padding(.horizontal, 10 * zoom)
        .frame(height: 46 * zoom)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: repo.isBusy)
    }

    private func commandRow(_ metrics: RepoCommandMetrics) -> some View {
        HStack(spacing: 0) {
            // Match the search field's width on the leading side so the
            // command capsule is centred in the detail column, not merely in
            // whatever space the trailing search happens to leave behind.
            ZStack(alignment: .leading) {
                if repo.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18 * zoom, height: 28 * zoom)
                        .transition(.opacity)
                }
            }
            .frame(width: metrics.searchWidth * zoom, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: metrics.commandSpacing * zoom) {
                HStack(spacing: metrics.pullSpacing * zoom) {
                    RepoCommandButton(
                        title: pullMode == .fetchAll ? "Fetch" : "Pull",
                        systemImage: "arrow.down.to.line",
                        help: pullMode.title,
                        width: metrics.buttonWidth,
                        iconSize: metrics.iconSize
                    ) {
                        repo.runPull(pullMode)
                    }

                    RepoCommandButton(
                        title: "Pull options",
                        systemImage: "chevron.down",
                        help: "Other pull and fetch operations",
                        width: metrics.pullOptionsWidth,
                        iconSize: 8
                    ) {
                        showingPullOptions.toggle()
                    }
                    .popover(isPresented: $showingPullOptions, arrowEdge: .bottom) {
                        PullOptionsPopover(current: pullMode) { mode, isDefault in
                            if isDefault {
                                // Stays open: the dot moving is the whole
                                // confirmation that the setting took.
                                pullModeRaw = mode.rawValue
                            } else {
                                showingPullOptions = false
                                repo.runPull(mode)
                            }
                        }
                    }
                }

                RepoCommandDivider(horizontalPadding: metrics.dividerPadding)

                RepoCommandButton(
                    title: "Push",
                    systemImage: "arrow.up.to.line",
                    help: "Push",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    repo.push()
                }

                RepoCommandButton(
                    title: "Branch",
                    systemImage: "arrow.triangle.branch",
                    help: "Create branch at HEAD",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    repo.promptNewBranch()
                }

                RepoCommandButton(
                    title: "Stash",
                    systemImage: "tray.and.arrow.down",
                    help: "Stash all changes (incl. untracked)",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    repo.stash()
                }

                RepoCommandButton(
                    title: "Pop",
                    systemImage: "tray.and.arrow.up",
                    help: "Pop latest stash",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    repo.stashPop()
                }

                RepoCommandDivider(horizontalPadding: metrics.dividerPadding)

                RepoCommandButton(
                    title: "Clean",
                    systemImage: "xmark.bin",
                    help: "Review merged and abandoned branches and worktrees",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    repo.openCleanup()
                }

                RepoCommandButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise",
                    help: "Refresh everything, including pull requests and issues (⌘R)",
                    width: metrics.buttonWidth,
                    iconSize: metrics.iconSize
                ) {
                    Task { await repo.refreshAll() }
                }
                .keyboardShortcut("r")
            }
            .padding(.horizontal, metrics.surfacePadding * zoom)
            .frame(height: 34 * zoom)
            .repoCommandSurface()

            Spacer(minLength: 0)

            HStack(spacing: 5 * zoom) {
                Image(systemName: "magnifyingglass")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)

                TextField(metrics.searchPlaceholder, text: $repo.searchText)
                    .textFieldStyle(.plain)
                    .zoomFont(12)
                    .focused($searchFocused)
                    .onExitCommand {
                        repo.searchText = ""
                        searchFocused = false
                    }

                if !repo.searchText.isEmpty {
                    Button {
                        repo.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .zoomFont(11)
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear commit search")
                }

                // Hidden ⌘F target that focuses the field.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f")
                    .frame(width: 0)
                    .opacity(0)
            }
            .padding(.horizontal, 8 * zoom)
            .frame(width: metrics.searchWidth * zoom, height: 34 * zoom)
            .repoCommandSurface()
            .help("Search commits by message, author, or sha (⌘F, esc to clear)")
        }
    }
}

private struct RepoCommandMetrics {
    let searchWidth: CGFloat
    let searchPlaceholder: String
    let buttonWidth: CGFloat
    let pullOptionsWidth: CGFloat
    let iconSize: CGFloat
    let commandSpacing: CGFloat
    let pullSpacing: CGFloat
    let surfacePadding: CGFloat
    let dividerPadding: CGFloat

    static let regular = RepoCommandMetrics(
        searchWidth: 180,
        searchPlaceholder: "Search commits",
        buttonWidth: 28,
        pullOptionsWidth: 20,
        iconSize: 13,
        commandSpacing: 6,
        pullSpacing: 2,
        surfacePadding: 6,
        dividerPadding: 2
    )

    // Fits the 660 pt detail floor even at the largest UI zoom. It preserves
    // every command and the search field; only horizontal breathing room
    // tightens, so resizing never changes what the user can do.
    static let compact = RepoCommandMetrics(
        searchWidth: 120,
        searchPlaceholder: "Search",
        buttonWidth: 24,
        pullOptionsWidth: 18,
        iconSize: 12,
        commandSpacing: 4,
        pullSpacing: 0,
        surfacePadding: 4,
        dividerPadding: 0
    )
}

private struct RepoCommandButton: View {
    let title: String
    let systemImage: String
    let help: String
    var width: CGFloat = 28
    var iconSize: CGFloat = 13
    let action: () -> Void

    @Environment(\.uiZoom) private var zoom

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomFont(iconSize, weight: .medium)
                .frame(width: width * zoom, height: 28 * zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
        .accessibilityLabel(title)
        .help(help)
    }
}

private struct RepoCommandDivider: View {
    var horizontalPadding: CGFloat = 2

    @Environment(\.uiZoom) private var zoom

    var body: some View {
        Divider()
            .frame(height: 20 * zoom)
            .padding(.horizontal, horizontalPadding * zoom)
    }
}

private struct RepoCommandSurface: ViewModifier {
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }
}

private extension View {
    func repoCommandSurface() -> some View {
        modifier(RepoCommandSurface())
    }
}

/// The Pull button's other operations, GitKraken-style — and the reason this
/// isn't a menu is that each row carries two different acts:
///
/// - **The row** runs that operation once, right now, and leaves the button's
///   default alone. A `--rebase` pull you want this afternoon isn't a
///   statement about how you pull in general.
/// - **The dot** makes it the default and runs nothing.
///
/// Before this, the menu's rows only set the default, so a one-off rebase pull
/// cost three acts — open the menu, pick the row, then go back out and press
/// the button — and silently changed how the button would behave forever
/// afterwards. The two things were welded together; now they're two targets.
private struct PullOptionsPopover: View {
    let current: RepoState.PullMode
    /// `isDefault` false = run it now, true = adopt it as the default.
    let choose: (RepoState.PullMode, Bool) -> Void

    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * zoom) {
            Text("Click an operation to run it now")
                .zoomFont(11)
                .foregroundStyle(.secondary)
            Text("The dot sets the button's default")
                .zoomFont(10)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4 * zoom)
            ForEach(RepoState.PullMode.allCases, id: \.rawValue) { mode in
                PullOptionRow(
                    mode: mode,
                    isDefault: mode == current,
                    run: { choose(mode, false) },
                    setDefault: { choose(mode, true) }
                )
            }
        }
        .padding(12 * zoom)
        .frame(minWidth: 240 * zoom, alignment: .leading)
    }
}

private struct PullOptionRow: View {
    let mode: RepoState.PullMode
    let isDefault: Bool
    let run: () -> Void
    let setDefault: () -> Void

    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8 * zoom) {
            // Its own button, and the only part of the row that isn't the
            // operation. Filled when it's the default, hollow otherwise —
            // radio grammar, because exactly one of these is true.
            Button(action: setDefault) {
                Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                    .zoomFont(13)
                    .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressEffect)
            .help(isDefault ? "Already the default" : "Set as default")

            Button(action: run) {
                Text(mode.title)
                    .zoomFont(12)
                    // The row's whole width is the target, not just the
                    // words — a 4pt-tall click zone on "Pull (rebase)" is
                    // what made the old menu feel fussy.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run \(mode.title.lowercased()) now")
        }
        .padding(.horizontal, 6 * zoom)
        .padding(.vertical, 5 * zoom)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
