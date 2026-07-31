import SwiftUI

/// Three-pane layout for one repository:
/// sidebar (branches) | graph | commit panel.
///
/// The right two panes double as the window's reading surface — a diff, a
/// file history, an issue, a pull request — see `workArea`.
struct RepoView: View {
    @ObservedObject var repo: RepoState

    /// User-dragged pane widths, persisted across relaunches and Launchpad
    /// round-trips. Read once per view identity into @State: idealWidth
    /// only matters on the split's first layout, and a live value would
    /// have every UserDefaults echo re-entering layout mid-drag.
    @State private var sidebarIdealWidth = RepoView.storedWidth(
        key: RepoView.sidebarWidthKey, fallback: 240)
    @State private var commitIdealWidth = RepoView.storedWidth(
        key: RepoView.commitWidthKey, fallback: 300)

    private static let sidebarWidthKey = "sidebarPaneWidth"
    private static let commitWidthKey = "commitPanelWidth"

    private static func storedWidth(key: String, fallback: CGFloat) -> CGFloat {
        let width = UserDefaults.standard.double(forKey: key)
        return width > 0 ? CGFloat(width) : fallback
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
        HSplitView {
            // The .id lives on the sidebar INSIDE a stable wrapper, never
            // on the split child itself: an id there hands HSplitView a
            // brand-new pane on every tab switch, and it re-balances all
            // three panes back to ideal widths — user-dragged widths died
            // on every switch. The ZStack keeps the pane's identity; only
            // the sidebar (and its per-tab filter box) resets.
            ZStack {
                SidebarView(repo: repo)
                    .id(repo.id)
            }
            .frame(minWidth: 200, idealWidth: sidebarIdealWidth, maxWidth: 360)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                Self.store($0, key: Self.sidebarWidthKey)
            }
            workArea
                // The two panes' minimums, so the outer split can't squeeze
                // the pair below what either of them accepts.
                .frame(minWidth: 660)
                .layoutPriority(1)
        }
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

struct RepoToolbar: ToolbarContent {
    @ObservedObject var repo: RepoState
    @FocusState private var searchFocused: Bool
    /// Default action for the Pull button, GitKraken-style. A Binding into
    /// RootView's @AppStorage — see the note there.
    @Binding var pullModeRaw: String
    @State private var showingPullOptions = false

    private var pullMode: RepoState.PullMode {
        RepoState.PullMode(rawValue: pullModeRaw) ?? .ff
    }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                repo.runPull(pullMode)
            } label: {
                Label(pullMode == .fetchAll ? "Fetch" : "Pull",
                      systemImage: "arrow.down.to.line")
            }
            .help(pullMode.title)

            // A popover rather than the Menu this used to be, because the two
            // acts in each row need two hit targets and an NSMenu item is one
            // button — there is nowhere to put a separately-clickable dot. It
            // also fixes what the old code needed `.id(pullModeRaw)` to work
            // around: the NSMenu a toolbar Menu builds is a snapshot that
            // never re-renders, so the tick stayed put after a change. A
            // popover is live SwiftUI and just updates.
            Button {
                showingPullOptions.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .zoomFont(9, weight: .semibold)
            }
            .help("Other pull and fetch operations")
            .popover(isPresented: $showingPullOptions, arrowEdge: .bottom) {
                PullOptionsPopover(current: pullMode) { mode, isDefault in
                    if isDefault {
                        // Stays open: the dot moving is the whole confirmation
                        // that the setting took, and closing the sheet you
                        // just changed a setting in hides the evidence.
                        pullModeRaw = mode.rawValue
                    } else {
                        showingPullOptions = false
                        repo.runPull(mode)
                    }
                }
            }

            Button {
                repo.push()
            } label: {
                Label("Push", systemImage: "arrow.up.to.line")
            }
            .help("Push")

            Button {
                repo.promptNewBranch()
            } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
            .help("Create branch at HEAD")

            Button {
                repo.stash()
            } label: {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            .help("Stash all changes (incl. untracked)")

            Button {
                repo.stashPop()
            } label: {
                Label("Pop", systemImage: "tray.and.arrow.up")
            }
            .help("Pop latest stash")

            Button {
                repo.openCleanup()
            } label: {
                Label("Clean", systemImage: "xmark.bin")
            }
            .help("Review merged and abandoned branches and worktrees")

            Button {
                Task { await repo.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh everything, including pull requests and issues (⌘R)")
        }

        ToolbarItem {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                TextField("Search commits", text: $repo.searchText)
                    .textFieldStyle(.plain)
                    .zoomFont(12)
                    .frame(width: 150)
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
                }
                // Hidden ⌘F target that focuses the field.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f")
                    .frame(width: 0)
                    .opacity(0)
            }
            .padding(.horizontal, 6)
            .help("Search commits by message, author, or sha (⌘F, esc to clear)")
        }

        // Busy indicator AFTER the left-anchored button cluster: it grows
        // to the right of the buttons, so they never move. Inserted only
        // while busy — an idle item still draws an empty capsule shell.
        if repo.isBusy {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem {
                    ProgressView().controlSize(.small)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem {
                    ProgressView().controlSize(.small)
                }
            }
#else
            ToolbarItem {
                ProgressView().controlSize(.small)
            }
#endif
        }
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
