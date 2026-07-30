import SwiftUI

/// Three-pane layout for one repository:
/// sidebar (branches) | graph | commit panel.
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
            // The diff OVERLAYS the graph instead of replacing it: swapping
            // the split child makes HSplitView re-balance all three panes
            // (the right panel visibly changed width on every file click).
            ZStack {
                GraphView(repo: repo)
                if let history = repo.fileHistory {
                    FileHistoryView(repo: repo, path: history.path, commits: history.commits)
                }
                if repo.selectedFile != nil {
                    FileDiffView(repo: repo)
                        // Fast fade-in masks the abrupt full-panel swap;
                        // removal stays instant — close is usually Esc,
                        // and keyboard actions never animate.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.12)),
                            removal: .identity
                        ))
                }
            }
            .frame(minWidth: 400)
            .layoutPriority(1)
            Group {
                // Selecting a commit swaps the right panel to its details,
                // GitKraken-style; ZStack keeps the split widths stable.
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
        .background(
            Color.clear
                .sheet(item: $repo.issueToView) { issue in
                    IssueDetailView(repo: repo, issue: issue)
                }
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
}

struct RepoToolbar: ToolbarContent {
    @ObservedObject var repo: RepoState
    @FocusState private var searchFocused: Bool
    /// Default action for the Pull button, GitKraken-style; the dropdown
    /// only picks the default, the button itself executes it. A Binding
    /// into RootView's @AppStorage — see the note there.
    @Binding var pullModeRaw: String

    private var pullMode: RepoState.PullMode {
        RepoState.PullMode(rawValue: pullModeRaw) ?? .ff
    }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Section("Default pull/fetch operation") {
                    ForEach(RepoState.PullMode.allCases, id: \.rawValue) { mode in
                        Button {
                            pullModeRaw = mode.rawValue
                        } label: {
                            HStack {
                                Text(mode.title)
                                if mode == pullMode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                Label(pullMode == .fetchAll ? "Fetch" : "Pull",
                      systemImage: "arrow.down.to.line")
            } primaryAction: {
                repo.runPull(pullMode)
            }
            // The NSMenu a toolbar Menu builds is a snapshot — it never
            // re-renders on state change, so the check stayed put (and
            // primaryAction kept running the old mode). A new id tears the
            // whole item down and rebuilds it whenever the mode changes.
            .id(pullModeRaw)
            .help(pullMode.title)

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
                Task { await repo.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
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
