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
                if repo.selectedFile != nil {
                    FileDiffView(repo: repo)
                }
            }
            .frame(minWidth: 400)
            .layoutPriority(1)
            CommitPanelView(repo: repo)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
        .toolbar { RepoToolbar(repo: repo) }
        .task { await repo.appeared() }
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
                Task { await repo.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
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
