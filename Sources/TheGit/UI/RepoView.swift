import SwiftUI

/// Three-pane layout for one repository:
/// sidebar (branches) | graph | commit panel.
struct RepoView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        HSplitView {
            SidebarView(repo: repo)
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
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
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            .onChange(of: repo.selectedCommit) { _, _ in
                repo.commitSelectionChanged()
            }
        }
        .toolbar { RepoToolbar(repo: repo) }
        // On its own layer, not in the chain below: a .sheet stacked with
        // the alerts and confirmationDialog on this same view never
        // presents — they compete for one presentation slot, and the
        // sheet loses. Color.clear gives it a view of its own.
        .background(
            Color.clear
                .sheet(isPresented: $repo.showCleanup) { CleanupView(repo: repo) }
        )
        .task { await repo.appeared() }
        // Refresh quietly whenever the app regains focus — changes made
        // in a terminal or editor show up without pressing ⌘R.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await repo.refresh(quiet: true) }
        }
        .alert(
            "Git Error",
            isPresented: Binding(
                get: { repo.errorMessage != nil },
                set: { if !$0 { repo.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repo.errorMessage ?? "")
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
    /// only picks the default, the button itself executes it.
    @AppStorage("pullMode") private var pullModeRaw = RepoState.PullMode.ff.rawValue

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
                Label("Clean", systemImage: "sparkles")
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search commits", text: $repo.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
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
                            .font(.system(size: 11))
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
        }
    }
}
