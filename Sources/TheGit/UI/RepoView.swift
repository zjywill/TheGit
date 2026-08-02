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
    /// The commit panel's LIVE width, unlike commitIdealWidth (whose
    /// deliberate read-once semantics are documented on workArea). Only the
    /// command bar reads it: its capsule centres over the graph pane, so it
    /// has to track the divider through a drag and the window through a
    /// resize.
    @State private var commitPaneWidth = RepoView.storedWidth(
        key: RepoView.commitWidthKey, fallback: 300)

    private static let sidebarWidthKey = "sidebarPaneWidth"
    private static let commitWidthKey = "commitPanelWidth"
    private static let sidebarWidthRange: ClosedRange<CGFloat> = 252...332
    /// The stable space the sidebar resize gesture measures in.
    static let splitSpace = "RepoViewSplit"

    private static func storedWidth(key: String, fallback: CGFloat) -> CGFloat {
        let width = UserDefaults.standard.double(forKey: key)
        return width > 0 ? CGFloat(width) : fallback
    }

    /// Internal: AppTopBar sizes the home screens' leading rail with this,
    /// so the tab strip starts at the same x on every screen.
    static func storedSidebarWidth() -> CGFloat {
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

            VStack(spacing: 0) {
                // The tab strip, in the title-bar band beside the capsule.
                // Its x matches the home screens exactly: their top bar
                // reserves a rail of the same stored sidebar width, so a
                // switch never moves a tab (see AppTopBar).
                RepoTabsBar()
                    .frame(height: AppTopBar.height)
                    .background(.bar)
                if let update = updates.update {
                    UpdateBanner(
                        update: update,
                        openReleasePage: { updates.openReleasePage() },
                        dismiss: { updates.skipCurrentUpdate() }
                    )
                    Divider()
                }
                // Repository commands stay directly below their active tab.
                // No hard rules between the chrome rows or into the content
                // — like Xcode's, the bands separate by material alone. The
                // content pane instead gets small top corners, so it reads
                // as its own surface tucked under the chrome; the notches
                // show the column's bar material behind it.
                RepoCommandBar(repo: repo, trailingWidth: commitPaneWidth)
                workArea
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 8,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 8,
                        style: .continuous
                    ))
            }
            .background(.bar)
            .animation(
                .easeOut(duration: reduceMotion ? 0 : 0.2),
                value: updates.update
            )
            // The graph and commit panel minima together. The window floor
            // keeps the complete split above this constraint.
            .frame(minWidth: 660)
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
        // The handle's drag gesture measures in this space — the split
        // itself, which never moves. Its own local space moves WITH the
        // width it is changing: each frame's width change shifts the next
        // translation sample, and the feedback shook the whole layout
        // during a drag. (Same trap as the tab strip's coordinateSpace.)
        .coordinateSpace(name: Self.splitSpace)
        // Bottom centre of the panes, which lands over the oldest loaded
        // commits — the one part of this window nobody is reading when a
        // command fails. The other two candidates are both worse: the
        // bottom right is the Commit button, and the top is the row that
        // just changed, or failed to.
        .overlay(alignment: .bottom) { ErrorToastLayer(repo: repo) }
        // A fresh repository needs a decision and several commands, not the
        // transient one-line error strip. Its own presentation layer keeps
        // it independent from the destructive-action alerts below.
        .background(
            Color.clear
                .alert(
                    "Create the first commit in Terminal",
                    isPresented: Binding(
                        get: { repo.initialCommitGuide != nil },
                        set: { if !$0 { repo.initialCommitGuide = nil } }
                    )
                ) {
                    Button("Copy Commands") {
                        if let guide = repo.initialCommitGuide {
                            RepoState.copyToPasteboard(guide.commands)
                        }
                    }
                    Button("Close", role: .cancel) {}
                } message: {
                    if let guide = repo.initialCommitGuide {
                        Text("""
                        "\(guide.repositoryName)" has no commits yet, so TheGit has no HEAD to display.

                        Run these commands in Terminal. They stage the repository's files, show what will be committed, and create the first commit:

                        \(guide.commands)

                        TheGit will refresh automatically after the commit.
                        """)
                    }
                }
        )
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
                    commitPaneWidth = $0
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

/// The macOS 27 sidebar: one flat surface flush with the window's leading,
/// top, and bottom edges — no floating capsule, no inset, no border, the
/// way Mail's sidebar sits. The traffic lights live in its title row. The
/// repository's high-volume navigator remains ScrollView-backed.
private struct RepoSidebarShell: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WindowControls()
                    .frame(width: 54, height: 20)
                Spacer(minLength: 0)
            }
            // 16 from the window edge, centred in the title-bar band — the
            // home top bar gives its lights the same spot, so a screen
            // switch never moves them.
            .padding(.leading, 16)
            .frame(height: AppTopBar.height)
            SidebarView(repo: repo)
                .id(repo.id)
        }
        .background(SidebarGlass())
    }
}

/// The capsule's one glass recipe, shared with the pinned section headers
/// inside it so header and capsule stay a single seamless surface in both
/// appearances. The lightening wash over the raw material is what keeps the
/// panel from reading grey in light mode: bare `.sidebar` material over a
/// dark desktop lands mid-grey, where Xcode's and App Store's light
/// sidebars are nearly white. `windowBackgroundColor` is white in light and
/// near-black in dark, so the wash brightens light mode and leaves dark
/// mode's depth alone.
struct SidebarGlass: View {
    var body: some View {
        ZStack {
            RepoSidebarMaterial()
            // Matched against Xcode 26's light navigator, which measures
            // RGB 247 and is nearly solid — so light mode pins that value
            // directly and lets only a trace of the glass through. Dark mode
            // keeps a deeper wash of the window color; the material carries
            // the tone there and a fixed value would flatten it.
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.windowBackgroundColor.withAlphaComponent(0.45)
                    : NSColor(srgbRed: 247 / 255, green: 247 / 255,
                              blue: 247 / 255, alpha: 1)
            })
        }
    }
}

/// `NSVisualEffectView` in sidebar material, matching SettingsRootView.
/// SwiftUI material blends only inside the opaque window and reads flat.
struct RepoSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Stable traffic-light geometry inside the app's top bar. AppKit keeps
/// the actual window and its actions; these controls only replace the title
/// bar's visible buttons, whose bare-titlebar position is reasserted during
/// every resize.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> RepoWindowControlHostView {
        RepoWindowControlHostView()
    }

    func updateNSView(_ view: RepoWindowControlHostView, context: Context) {
        view.attachIfNeeded()
    }

    // No dismantle restore: every screen shows these controls, and a screen
    // switch replaces one host with another. SwiftUI attaches the new host
    // before tearing the old one down, so a restore here would re-show the
    // native buttons over the new host's row for a frame — or longer, since
    // the new host only re-hides them on the next window notification.
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

final class RepoWindowControlHostView: NSView {
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
        // The direct calls, not performClose/performMiniaturize/performZoom:
        // the perform variants simulate a click on the standard buttons,
        // and the standard buttons here are hidden and disabled — every
        // perform was a silent no-op.
        switch sender.kind {
        case .close:
            // Keeps the delegate's windowShouldClose consultation.
            if window.delegate?.windowShouldClose?(window) ?? true {
                window.close()
            }
        case .miniaturize:
            window.miniaturize(sender)
        case .zoom:
            window.zoom(sender)
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
        // Enabled comes from the style mask, NOT from the native buttons:
        // AppKit reports the buttons this view just hid as disabled, so
        // mirroring them disabled all three replacements permanently —
        // hover drew, clicks did nothing.
        let mask = managedWindow?.styleMask ?? []
        for (button, kind) in zip(buttons, RepoWindowControlKind.allCases) {
            switch kind {
            case .close: button.isEnabled = mask.contains(.closable)
            case .miniaturize: button.isEnabled = mask.contains(.miniaturizable)
            case .zoom: button.isEnabled = mask.contains(.resizable)
            }
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
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(RepoView.splitSpace)
                )
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
    /// Live width of the commit panel in the split below. The command
    /// capsule centres over the graph pane — everything left of that panel —
    /// and the search capsule centres over the panel itself, so both track
    /// the divider drag and the window resize.
    var trailingWidth: CGFloat = 300
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
            // This flexible region spans exactly the graph pane below (the
            // trailing region is pinned to the commit panel's width), so
            // centring in it is centring over the graph — wherever the
            // divider is dragged. The busy spinner hangs at its leading
            // edge, out of the capsule's way.
            ZStack {
                HStack(spacing: 0) {
                    if repo.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18 * zoom, height: 28 * zoom)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }

                commandCluster(metrics)
            }
            .frame(maxWidth: .infinity)

            searchCapsule(metrics)
                // Centred within the commit panel's width; the max() keeps
                // the capsule whole if the panel is dragged narrower than it.
                .frame(width: max(trailingWidth, metrics.searchWidth * zoom + 16))
        }
    }

    private func commandCluster(_ metrics: RepoCommandMetrics) -> some View {
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
    }

    private func searchCapsule(_ metrics: RepoCommandMetrics) -> some View {
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
