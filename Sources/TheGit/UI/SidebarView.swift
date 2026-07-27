import SwiftUI

/// Left panel: local branches, remote branches, worktrees.
struct SidebarView: View {
    @ObservedObject var repo: RepoState
    @EnvironmentObject var appState: AppState

    var body: some View {
        // ScrollView + LazyVStack instead of List: List is NSTableView
        // underneath, and it was the app's one source of AppKit layout
        // exceptions (reentrant-delegate asserts, fatal under zoom changes).
        // Same reasoning as the graph column.
        ScrollView {
            // spacing 0: every row carries its own height (SidebarMetrics.row),
            // so the vertical rhythm is a property of the rows rather than of
            // the gaps between them — which is what lets one-line and two-line
            // rows sit on the same grid.
            LazyVStack(alignment: .leading, spacing: 0) {
            Group {
                SectionHeader(
                    title: "Local",
                    count: repo.snapshot.localBranches.count,
                    actionHelp: "Create branch at HEAD"
                ) { repo.promptNewBranch() }
                ForEach(BranchTree.build(repo.snapshot.localBranches, path: \.name)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
            }
            Group {
                SectionHeader(
                    title: "Remote",
                    count: repo.snapshot.remoteNames.count,
                    actionHelp: "Add remote"
                ) { repo.promptAddRemote() }
                .padding(.top, 14)
                ForEach(BranchTree.remoteTree(repo.snapshot.remoteBranches)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
                if repo.snapshot.remoteBranches.isEmpty {
                    SidebarRow(icon: "plus.circle", iconColor: Color.accentColor) {
                        Text("Add Remote…")
                            .zoomFont(12)
                            .foregroundStyle(Color.accentColor)
                    }
                    .onTapGesture { repo.promptAddRemote() }
                }
            }
            // Only present when the repo's host has a CLI installed —
            // otherwise the feature leaves no trace at all.
            if let forge = repo.forge {
                Group {
                    SectionHeader(
                        title: forge.sectionTitle,
                        count: repo.pullRequests.count,
                        actionIcon: "arrow.clockwise",
                        actionHelp: "Refresh \(forge.sectionTitle.lowercased())"
                    ) { repo.refreshPullRequests() }
                    .padding(.top, 14)
                    if let error = repo.forgeError {
                        SidebarRow(icon: "exclamationmark.triangle", iconColor: .orange) {
                            Text(error)
                                .zoomFont(10)
                                .foregroundStyle(.orange)
                                .lineLimit(3)
                        }
                        .help(error)
                    } else if repo.pullRequests.isEmpty {
                        SidebarRow(icon: nil) {
                            Text(repo.loadingPullRequests ? "Loading…" : "No open \(forge.itemNoun.lowercased())s")
                                .zoomFont(11)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(repo.pullRequests) { pr in
                        PullRequestRow(pr: pr, forge: forge, repo: repo)
                    }
                }
            }
            Group {
                SectionHeader(title: "Worktrees", count: repo.snapshot.worktrees.count)
                    .padding(.top, 14)
                ForEach(repo.snapshot.worktrees) { wt in
                    SidebarRow(icon: "folder") {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wt.displayName)
                                .zoomFont(12)
                                .lineLimit(1)
                            if let branch = wt.branch {
                                Text(branch)
                                    .zoomFont(10)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .help(wt.path)
                    .contextTarget("wt:" + wt.path, repo)
                    .contextMenu {
                        Button("Open as Tab") { appState.open(path: wt.path) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
                        }
                        Divider()
                        Button("Remove Worktree…", role: .destructive) {
                            repo.worktreeToRemove = wt
                        }
                    }
                    .onTapGesture(count: 2) { appState.open(path: wt.path) }
                }
            }
            if !repo.snapshot.tags.isEmpty {
                Group {
                    SectionHeader(title: "Tags", count: repo.snapshot.tags.count)
                        .padding(.top, 14)
                    ForEach(repo.snapshot.tags) { tag in
                        // Secondary, not orange: orange is this sidebar's
                        // "needs attention" colour (behind, gone, LFS
                        // missing, dirty submodule). A tag is just a tag.
                        SidebarRow(icon: "tag") {
                            Text(tag.name)
                                .zoomFont(12)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .onTapGesture { repo.locate(tag.hash) }
                        .help("\(tag.name) @ \(String(tag.hash.prefix(7))) — click to locate")
                        .contextTarget("tag:" + tag.name, repo)
                        .contextMenu {
                            Button("Checkout \(tag.name) (detached)") { repo.checkoutTag(tag) }
                            Divider()
                            if repo.snapshot.remoteNames.count > 1 {
                                Menu("Push tag to") {
                                    ForEach(repo.snapshot.remoteNames, id: \.self) { remote in
                                        Button(remote) { repo.pushTag(tag, to: remote) }
                                    }
                                }
                            } else {
                                Button("Push tag to \(repo.snapshot.defaultRemote)") { repo.pushTag(tag) }
                            }
                            Button("Copy tag name") { RepoState.copyToPasteboard(tag.name) }
                            Divider()
                            Button("Delete tag…", role: .destructive) { repo.tagToDelete = tag }
                        }
                    }
                }
            }
            if !repo.snapshot.stashes.isEmpty {
                Group {
                    SectionHeader(title: "Stashes", count: repo.snapshot.stashes.count)
                        .padding(.top, 14)
                    ForEach(repo.snapshot.stashes) { stash in
                        SidebarRow(icon: "tray.full") {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stash.message)
                                    .zoomFont(12)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(stash.ref) · \(stash.date.formatted(.relative(presentation: .named)))")
                                    .zoomFont(10)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        // Lights up when the stash's graph node is clicked.
                        .background(
                            repo.selectedStashRef == stash.ref
                                ? Color.accentColor.opacity(0.15)
                                : .clear
                        )
                        .help(stash.message)
                        .contextTarget("stash:" + stash.ref, repo)
                        .contextMenu {
                            Button("Apply (keep stash)") { repo.applyStash(stash) }
                            Button("Pop (apply and remove)") { repo.popStash(stash) }
                            Divider()
                            Button("Create branch from stash…") {
                                repo.promptText = ""
                                repo.branchPrompt = .branchFromStash(stash)
                            }
                            Divider()
                            Button("Drop…", role: .destructive) { repo.stashToDrop = stash }
                        }
                        .onTapGesture(count: 2) { repo.applyStash(stash) }
                        // Single click mirrors the graph node: select, and
                        // jump the graph to the commit the stash sits on.
                        .onTapGesture {
                            repo.selectedStashRef = stash.ref
                            if !stash.baseHash.isEmpty { repo.locate(stash.baseHash) }
                        }
                    }
                }
            }
            // Only in repos that actually use LFS — and only when the
            // binary is installed, which is what makes the status readable
            // in the first place.
            if repo.snapshot.lfs.isEnabled {
                Group {
                    SectionHeader(
                        title: "Git LFS",
                        count: repo.snapshot.lfs.files.count,
                        actionIcon: "arrow.down.circle",
                        actionHelp: "Download LFS objects (git lfs pull)"
                    ) { repo.pullLFSObjects() }
                    .padding(.top, 14)
                    let missing = repo.snapshot.lfsMissing.count
                    if missing > 0 {
                        SidebarRow(icon: "arrow.down.circle.dotted", iconColor: .orange) {
                            Text("\(missing) not downloaded")
                                .zoomFont(11)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        .help("These files are pointers only — click to run git lfs pull")
                        .onTapGesture { repo.pullLFSObjects() }
                    }
                    ForEach(repo.snapshot.lfs.patterns, id: \.self) { pattern in
                        // externaldrive, not a second shippingbox: the box is
                        // the submodule icon, and two unrelated things wearing
                        // the same glyph read as one kind at a glance.
                        SidebarRow(icon: "externaldrive") {
                            Text(pattern)
                                .zoomFont(12, design: .monospaced)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help("\(pattern) — tracked by Git LFS (.gitattributes)")
                        .contextTarget("lfs:" + pattern, repo)
                        .contextMenu {
                            Button("Copy pattern") { RepoState.copyToPasteboard(pattern) }
                            Button("Download LFS objects") { repo.pullLFSObjects() }
                        }
                    }
                }
            }
            // Always shown, empty or not: the + is the only way in to
            // "Add Submodule…", and a repo with none is where you add one.
            Group {
                SectionHeader(
                    title: "Submodules",
                    count: repo.snapshot.submodules.count,
                    actionHelp: "Add submodule"
                ) { repo.promptAddSubmodule() }
                .padding(.top, 14)
                ForEach(repo.snapshot.submodules) { sub in
                    SubmoduleRow(sub: sub, repo: repo)
                }
            }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        // Right-click on empty sidebar space: the actions that belong to
        // the repo rather than to any one row.
        .contextMenu {
            Button("Create Branch at HEAD…") { repo.promptNewBranch() }
            Button("Add Remote…") { repo.promptAddRemote() }
            Button("Add Submodule…") { repo.promptAddSubmodule() }
            // The whole repo caught up at once — the multi-branch version
            // of the gap pull leaves behind.
            let behind = repo.fastForwardableBranches
            if !behind.isEmpty {
                Divider()
                Button("Fast-forward \(behind.count) Behind Branch\(behind.count == 1 ? "" : "es")") {
                    repo.fastForwardAll()
                }
            }
            Divider()
            Button("Open Repository…") { appState.openRepoPanel() }
            Button("Refresh") { Task { await repo.refresh() } }
        }
        .alert(
            repo.branchPrompt?.title ?? "",
            isPresented: Binding(
                get: { repo.branchPrompt != nil },
                set: { if !$0 { repo.branchPrompt = nil; repo.promptText = "" } }
            )
        ) {
            TextField(repo.branchPrompt?.fieldLabel ?? "Name", text: $repo.promptText)
            Button(repo.branchPrompt?.confirmLabel ?? "OK") { repo.confirmPrompt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let note = repo.branchPrompt?.note { Text(note) }
        }
        .sheet(isPresented: $repo.showAddRemote) {
            VStack(alignment: .leading, spacing: 12) {
                Text(repo.editingRemote == nil ? "Add Remote" : "Edit \(repo.editingRemote ?? "")")
                    .font(.headline)
                TextField("Name (e.g. origin)", text: $repo.newRemoteName)
                    // Renaming a remote is a different operation with
                    // different consequences; this sheet only sets URLs.
                    .disabled(repo.editingRemote != nil)
                TextField("URL (https://… or git@…)", text: $repo.newRemoteURL)
                    .frame(minWidth: 320)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        repo.showAddRemote = false
                        repo.editingRemote = nil
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button(repo.editingRemote == nil ? "Add & Fetch" : "Save & Fetch") {
                        repo.confirmAddRemote()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(
                        repo.newRemoteName.trimmingCharacters(in: .whitespaces).isEmpty
                            || repo.newRemoteURL.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $repo.showAddSubmodule) {
            AddSubmoduleSheet(repo: repo)
        }
        .alert(
            "Remove submodule \(repo.submoduleToRemove?.displayName ?? "")?",
            isPresented: Binding(
                get: { repo.submoduleToRemove != nil },
                set: { if !$0 { repo.submoduleToRemove = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                repo.confirmRemoveSubmodule(purgeLocalClone: false)
            }
            Button("Remove and Delete Local Clone", role: .destructive) {
                repo.confirmRemoveSubmodule(purgeLocalClone: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The folder and its .gitmodules entry are removed and staged for you to commit.\n\n"
                    + "Remove keeps the submodule's own clone in .git/modules, so anything "
                    + "committed inside it but never pushed survives — but no submodule can be "
                    + "added at this path again until that clone is gone. "
                    + "Delete Local Clone removes it too."
            )
        }
        .alert(
            "Remove remote \(repo.remoteToRemove ?? "")?",
            isPresented: Binding(
                get: { repo.remoteToRemove != nil },
                set: { if !$0 { repo.remoteToRemove = nil } }
            )
        ) {
            Button("Remove", role: .destructive) { repo.confirmRemoveRemote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the remote and its tracking branches from this repo. Nothing is deleted on the server.")
        }
        .alert(
            "Delete tag \(repo.tagToDelete?.name ?? "")?",
            isPresented: Binding(
                get: { repo.tagToDelete != nil },
                set: { if !$0 { repo.tagToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { repo.confirmDeleteTag() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the local tag only. If it was pushed, it remains on the remote.")
        }
        .alert(
            "Remove worktree \(repo.worktreeToRemove?.displayName ?? "")?",
            isPresented: Binding(
                get: { repo.worktreeToRemove != nil },
                set: { if !$0 { repo.worktreeToRemove = nil } }
            )
        ) {
            Button("Remove", role: .destructive) { repo.confirmRemoveWorktree() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The worktree folder and any uncommitted changes in it will be removed.")
        }
        .alert(
            "Drop \(repo.stashToDrop?.ref ?? "")?",
            isPresented: Binding(
                get: { repo.stashToDrop != nil },
                set: { if !$0 { repo.stashToDrop = nil } }
            )
        ) {
            Button("Drop", role: .destructive) { repo.confirmDropStash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(repo.stashToDrop?.message ?? "")\" will be permanently deleted.")
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { repo.branchToDelete != nil },
                set: { if !$0 { repo.branchToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { repo.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String {
        guard let pending = repo.branchToDelete else { return "" }
        if case .remote = pending.branch.kind { return "Delete \(pending.branch.name) on remote?" }
        if pending.includeRemote { return "Delete \(pending.branch.name) everywhere?" }
        return "Delete \(pending.branch.name)?"
    }

    private var deleteMessage: String {
        guard let pending = repo.branchToDelete else { return "" }
        if case .remote(let remote) = pending.branch.kind {
            return "This deletes the branch on the \"\(remote)\" remote. Others using it will lose it."
        }
        if pending.includeRemote {
            return "Deletes the local branch and \(repo.remote(for: pending.branch))/"
                + "\(pending.branch.name) on the remote. Others using it will lose it."
        }
        return "The branch will be force-deleted, including unmerged commits."
    }
}

/// One submodule: a gitlink in this repo, and a whole repository of its
/// own — double-click opens it in its own tab.
struct SubmoduleRow: View {
    let sub: Submodule
    @ObservedObject var repo: RepoState
    @EnvironmentObject var appState: AppState

    /// "-" means the gitlink is registered but never checked out: the
    /// folder is empty, so there is no repo to open yet.
    private var initialized: Bool { sub.state != "-" }
    private var fullPath: String { repo.path + "/" + sub.path }

    var body: some View {
        SidebarRow(
            icon: "shippingbox",
            iconColor: sub.state == " " ? Color.secondary : .orange
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sub.displayName)
                    .zoomFont(12)
                    .lineLimit(1)
                if sub.state != " " {
                    Text(sub.stateDescription)
                        .zoomFont(10)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
        .help("\(sub.path) @ \(String(sub.sha.prefix(7))) — \(sub.stateDescription)")
        .contextTarget("sub:" + sub.path, repo)
        .contextMenu {
            Button("Open as Tab") { appState.open(path: fullPath) }
                .disabled(!initialized)
            Button("Update (init, recursive)") { repo.updateSubmodules() }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
            }
            Button("Copy path") { RepoState.copyToPasteboard(fullPath) }
            Divider()
            Button("Remove Submodule…", role: .destructive) { repo.submoduleToRemove = sub }
        }
        // Checking it out is the only useful thing to do with an
        // uninitialized submodule, so that's what the double-click does.
        .onTapGesture(count: 2) {
            if initialized {
                appState.open(path: fullPath)
            } else {
                repo.updateSubmodules()
            }
        }
    }
}

/// URL + path, the two arguments of `git submodule add`. The path field
/// keeps up with the URL until the user types in it themselves.
struct AddSubmoduleSheet: View {
    @ObservedObject var repo: RepoState
    @State private var pathEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Submodule")
                .font(.headline)
            TextField("URL (https://… or git@…)", text: $repo.newSubmoduleURL)
                .frame(minWidth: 360)
                .onChange(of: repo.newSubmoduleURL) { _, url in
                    if !pathEdited { repo.newSubmodulePath = RepoState.defaultSubmodulePath(for: url) }
                }
            TextField("Path in repo (e.g. vendor/lib)", text: Binding(
                get: { repo.newSubmodulePath },
                set: { repo.newSubmodulePath = $0; pathEdited = true }
            ))
            Text("Clones the repository into that path and records it in .gitmodules. Both are staged for you to commit.")
                .zoomFont(11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { repo.showAddSubmodule = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add") { repo.confirmAddSubmodule() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(repo.newSubmoduleURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
    }
}

/// GitKraken-style section header: count on the right, and (when the
/// section has an action) a large bordered + button that appears on hover.
struct SectionHeader: View {
    let title: String
    let count: Int
    var actionIcon = "plus"
    var actionHelp: String?
    var action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 6) {
            // Explicit header styling: these used to sit in a List section
            // header, which supplied the font; in a plain LazyVStack the
            // header must style itself.
            Text(title)
                .zoomFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer()
            // Count and + button share one centered slot, so the swap on
            // hover never shifts anything.
            ZStack {
                Text("\(count)")
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .opacity(action != nil && hovering ? 0 : 1)
                if let action {
                    Button(action: action) {
                        Image(systemName: actionIcon)
                            .zoomFont(11, weight: .semibold)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(Color.accentColor)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                    )
                    .help(actionHelp ?? "")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
            .frame(minWidth: 22, minHeight: 22, maxHeight: 22, alignment: .center)
        }
        // Same trailing inset as the rows, so the counts and the branch
        // ahead/behind badges share one right-hand baseline.
        .padding(.trailing, SidebarMetrics.trailing * zoom)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The sidebar's layout grid, at zoom 1. Everything multiplies by
/// `\.uiZoom`, so the columns hold at all five zoom levels.
enum SidebarMetrics {
    /// One row's height. One-line rows are exactly this tall; two-line
    /// rows (worktrees, stashes, PRs) grow past it but keep the same
    /// leading columns.
    static let row: CGFloat = 22
    /// Disclosure-chevron column, at the TRAILING edge. Kept off the
    /// leading edge on purpose: only folders have a chevron, so a leading
    /// gutter would be dead space on every branch, PR, tag and stash row
    /// — visible as a hole in front of whole sections that contain no
    /// folders at all. On the right it costs nothing, because the rows
    /// that carry one (folders) are the only rows with no trailing badge.
    static let chevron: CGFloat = 14
    /// Icon column, and now the row's first column. SF Symbols have wildly
    /// different intrinsic widths at the same point size (`cloud` ≈ 15pt
    /// against `arrow.triangle.branch` ≈ 10pt), and without a fixed column
    /// that difference is handed straight to the text, so no two rows
    /// start in the same place.
    static let icon: CGFloat = 16
    static let gap: CGFloat = 6
    /// One nesting level: icon + gap, so a child's icon sits exactly under
    /// its parent's text. With the chevron gone from the leading edge,
    /// indentation is the only thing carrying depth, so it has to land on
    /// a column the eye already knows.
    static let indent: CGFloat = icon + gap
    static let trailing: CGFloat = 10
}

/// Every row in the sidebar: `[icon][content][chevron]`, fixed columns.
/// Going through one primitive is what makes alignment a structural
/// property instead of something each section has to remember.
struct SidebarRow<Content: View>: View {
    @Environment(\.uiZoom) private var zoom
    var depth = 0
    var chevron = false
    var expanded = false
    /// nil reserves the column without drawing anything, for rows that
    /// are text only ("No open pull requests") but still have to line up.
    var icon: String?
    var iconColor: Color = .secondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        // firstTextBaseline, not center: on a two-line row the icon
        // belongs to the title, and centring it against title+subtitle
        // floats it into the gap between them.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .zoomFont(11)
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: SidebarMetrics.icon * zoom)
            .padding(.trailing, SidebarMetrics.gap * zoom)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .zoomFont(9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: SidebarMetrics.chevron * zoom)
            }
        }
        .padding(.leading, CGFloat(depth) * SidebarMetrics.indent * zoom)
        .padding(.trailing, SidebarMetrics.trailing * zoom)
        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.row * zoom, alignment: .leading)
        // Full width, so the empty space to the right of a short branch
        // name is as clickable as the name itself — it wasn't on half the
        // rows before, which made the list feel arbitrary.
        .contentShape(Rectangle())
    }
}

/// One sidebar tree row: a folder (git-flow prefix or a remote) or a branch.
struct BranchNodeRow: View {
    let node: BranchNode
    var depth = 0
    @ObservedObject var repo: RepoState

    var body: some View {
        if let branch = node.branch {
            BranchRow(branch: branch, label: node.name, depth: depth, repo: repo)
        } else {
            FolderRow(node: node, depth: depth, repo: repo)
        }
    }
}

/// Folder row where clicking ANYWHERE on the row toggles expansion,
/// not just the chevron. Children are emitted as siblings at depth + 1
/// rather than nested in a padded container, so every row is a full-width
/// row on the same grid no matter how deep it sits.
struct FolderRow: View {
    let node: BranchNode
    var depth = 0
    @ObservedObject var repo: RepoState

    private var expanded: Bool { repo.expandedNodes.contains(node.id) }

    var body: some View {
        SidebarRow(
            depth: depth,
            chevron: true,
            expanded: expanded,
            icon: isRemoteRoot ? "cloud" : "folder"
        ) {
            Text(node.name)
                .zoomFont(12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { repo.toggleExpanded(node.id) }
        }
        .contextTarget("node:" + node.id, repo)
        .contextMenu {
            if isRemoteRoot {
                Button("Fetch \(node.name) only") { repo.fetchRemoteOnly(node.name) }
                Button("Edit URL…") { repo.promptEditRemote(node.name) }
                Button("Rename Remote…") { repo.promptRenameRemote(node.name) }
                Button("Copy URL") { repo.copyRemoteURL(node.name) }
                Divider()
                Button("Remove Remote…", role: .destructive) {
                    repo.remoteToRemove = node.name
                }
            }
        }
        if expanded {
            ForEach(node.children ?? []) { child in
                BranchNodeRow(node: child, depth: depth + 1, repo: repo)
            }
        }
    }

    /// Top-level remote node ("remote:origin"), not a folder inside it.
    private var isRemoteRoot: Bool {
        node.id.hasPrefix("remote:") && !node.id.dropFirst(7).contains("/")
    }
}

/// One open PR/MR. Everything it can do is a `gh`/`glab` subcommand —
/// no API client, no token of our own.
struct PullRequestRow: View {
    let pr: PullRequest
    let forge: Forge
    @ObservedObject var repo: RepoState

    var body: some View {
        SidebarRow(
            icon: "arrow.triangle.pull",
            iconColor: pr.isDraft ? Color.secondary : .green
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(forge.label(pr.number))
                            .zoomFont(10, weight: .semibold, design: .monospaced)
                            .foregroundStyle(.tertiary)
                        Text(pr.title)
                            .zoomFont(12)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(pr.author.isEmpty ? pr.branch : "\(pr.branch) · \(pr.author)")
                        .zoomFont(10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if pr.isDraft {
                    Text("draft")
                        .zoomFont(9, weight: .medium)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(pr.isDraft ? 0.75 : 1)
        .help("\(forge.label(pr.number)) \(pr.title)\n\(pr.branch)")
        .contextTarget("pr:\(pr.number)", repo)
        .contextMenu {
            Button("Checkout \(forge.label(pr.number))") { repo.checkoutPullRequest(pr) }
            Button("Open in Browser") { repo.openPullRequestInBrowser(pr) }
            Divider()
            Button("Copy URL") { RepoState.copyToPasteboard(pr.url) }
            Button("Copy branch name") { RepoState.copyToPasteboard(pr.branch) }
            Divider()
            Button("Refresh") { repo.refreshPullRequests() }
        }
        .onTapGesture(count: 2) { repo.checkoutPullRequest(pr) }
        // Single click locates the PR's branch tip, like clicking a branch.
        .onTapGesture {
            if let tip = remoteTip { repo.locate(tip) }
        }
    }

    /// The remote-tracking branch this PR was opened from, when we've fetched it.
    private var remoteTip: String? {
        repo.snapshot.remoteBranches
            .first { $0.shortName == pr.branch }?
            .tipHash
    }
}

/// Accepts branch and commit drags on a local branch row/badge, and turns
/// the drop into a `DropIntent` for the confirmation menu. Shared by the
/// sidebar rows and the graph's ref badges so both behave identically.
struct BranchDropTarget: ViewModifier {
    let branch: Branch
    @ObservedObject var repo: RepoState
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if case .local = branch.kind {
            content
                .dropDestination(for: DraggedBranch.self) { items, _ in
                    guard let source = items.first?.name, source != branch.name else { return false }
                    repo.dropIntent = .branchOnBranch(source: source, target: branch.name)
                    return true
                } isTargeted: { targeted = $0 }
                .dropDestination(for: DraggedCommit.self) { items, _ in
                    guard let commit = items.first else { return false }
                    repo.dropIntent = .commitOnBranch(commit: commit, target: branch.name)
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

struct BranchRow: View {
    let branch: Branch
    var label: String?
    var depth = 0
    @ObservedObject var repo: RepoState
    @State private var targeted = false

    var body: some View {
        // The current branch keeps the branch glyph and says so in colour
        // and weight. Swapping in checkmark.circle.fill made one row
        // optically ~1.5× heavier than every other icon at the same point
        // size, so it broke out of the column instead of sitting in it —
        // a state change should move one channel, not replace identity.
        SidebarRow(
            depth: depth,
            icon: "arrow.triangle.branch",
            iconColor: branch.isCurrent ? Color.accentColor : .secondary
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label ?? branch.name)
                    .zoomFont(12, weight: branch.isCurrent ? .semibold : .regular)
                    .foregroundStyle(branch.isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if repo.soloRev == branch.name {
                    Text("SOLO")
                        .zoomFont(8, weight: .bold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                if branch.upstreamGone {
                    Text("gone")
                        .zoomFont(9, weight: .medium)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                        .help("Upstream \(branch.upstream ?? "") no longer exists")
                } else if branch.ahead > 0 || branch.behind > 0 {
                    HStack(spacing: 3) {
                        if branch.ahead > 0 {
                            Text("↑\(branch.ahead)").foregroundStyle(.teal)
                        }
                        if branch.behind > 0 {
                            Text("↓\(branch.behind)").foregroundStyle(.orange)
                        }
                    }
                    .zoomFont(10, weight: .semibold, design: .monospaced)
                    .help("\(branch.ahead) ahead, \(branch.behind) behind \(branch.upstream ?? "upstream")")
                }
            }
        }
        // No animation on the highlight: during a drag the pointer is
        // moving fast and a fade reads as lag, not polish.
        .background(targeted ? Color.accentColor.opacity(0.15) : .clear)
        .contextTarget("branch:" + branch.name, repo)
        .contextMenu { menuItems }
        .onTapGesture(count: 2) {
            if !branch.isCurrent { repo.checkout(branch) }
        }
        // Single click locates the branch tip in the graph (GitKraken).
        .onTapGesture { repo.locate(branch.tipHash) }
        .help(branch.isCurrent ? "Current branch — click to locate" : "Click to locate, double-click to checkout")
        .opacity(repo.hiddenRefs.contains(branch.refPath) ? 0.45 : 1)
        .draggable(DraggedBranch(name: branch.name))
        // Only local branches take drops: both actions run against HEAD,
        // and you can't check out a remote-tracking ref.
        .modifier(BranchDropTarget(branch: branch, repo: repo, targeted: $targeted))
    }

    /// GitKraken-style menus: three variants — current branch,
    /// other local branch, remote branch.
    @ViewBuilder
    private var menuItems: some View {
        let current = repo.snapshot.currentBranch ?? "HEAD"

        if branch.isCurrent {
            Button("Pull (fast-forward if possible)") { repo.pull() }
            pushMenu
            fastForwardItem
            upstreamMenu
            if let forge = repo.forge {
                Divider()
                Button("Create \(forge.itemNoun)…") { repo.createPullRequest(from: branch) }
            }
            Divider()
            Button("Create branch here…") { promptCreate() }
            Button("Rename…") { promptRename() }
        } else {
            Button("Checkout \(branch.shortName)") { repo.checkout(branch) }
            if case .local = branch.kind {
                fastForwardItem
                pushMenu
            }
            Divider()
            Button("Merge \(branch.name) into \(current)") { repo.merge(branch) }
            Button("Rebase \(current) onto \(branch.name)") { repo.rebaseOnto(branch) }
            Divider()
            Button("Create branch here…") { promptCreate() }
            if case .local = branch.kind {
                Button("Rename…") { promptRename() }
                upstreamMenu
                if let forge = repo.forge {
                    Button("Create \(forge.itemNoun) from \(branch.name)…") {
                        repo.createPullRequest(from: branch)
                    }
                }
            }
            if case .remote = branch.kind {
                Button("Create worktree from \(branch.shortName)…") { repo.addWorktree(for: branch) }
            }
            Divider()
            if case .remote = branch.kind {
                Button("Delete on remote…", role: .destructive) {
                    repo.branchToDelete = PendingBranchDelete(branch: branch)
                }
            } else {
                Button("Delete…", role: .destructive) {
                    repo.branchToDelete = PendingBranchDelete(branch: branch)
                }
                // Only offered when there is in fact a remote branch left
                // to delete — a "gone" upstream has nothing on the far end.
                if branch.upstream != nil, !branch.upstreamGone {
                    Button("Delete local and remote…", role: .destructive) {
                        repo.branchToDelete = PendingBranchDelete(branch: branch, includeRemote: true)
                    }
                }
            }
        }
        Divider()
        Button(repo.soloRev == branch.name ? "Unsolo" : "Solo") { repo.toggleSolo(branch) }
        Button(repo.hiddenRefs.contains(branch.refPath) ? "Show in graph" : "Hide from graph") {
            repo.toggleHidden(branch)
        }
        Divider()
        Button("Copy branch name") { RepoState.copyToPasteboard(branch.name) }
    }

    /// The gap `git pull` leaves: pull only ever advances HEAD, so a branch
    /// you aren't standing on stays behind however often you pull. Offered
    /// only when it's purely behind, and git refuses anything that isn't a
    /// true fast-forward anyway.
    @ViewBuilder
    private var fastForwardItem: some View {
        if branch.behind > 0, branch.ahead == 0, let upstream = branch.upstream,
           !branch.upstreamGone {
            Button("Fast-forward to \(upstream) (↓\(branch.behind))") {
                repo.fastForward(branch)
            }
        }
    }

    /// One remote: a plain Push. Several: pick, because "git push" with no
    /// upstream and two remotes has no correct default.
    @ViewBuilder
    private var pushMenu: some View {
        let remotes = repo.snapshot.remoteNames
        if branch.upstream != nil, remotes.count <= 1 {
            Button("Push") { repo.push() }
        } else if remotes.isEmpty {
            Button("Push") { repo.push() }
        } else {
            Menu("Push to") {
                ForEach(remotes, id: \.self) { remote in
                    Button(branch.upstream == nil
                        ? "\(remote) (set upstream)"
                        : remote) {
                        repo.push(branch, to: remote)
                    }
                }
            }
        }
    }

    /// Every remote-tracking branch is a legal upstream, so list them all
    /// rather than assuming <defaultRemote>/<same name>. Same-named ones
    /// sort first because that's the answer nine times out of ten.
    @ViewBuilder
    private var upstreamMenu: some View {
        Menu("Set Upstream") {
            ForEach(repo.upstreamChoices(for: branch)) { remoteBranch in
                Button {
                    repo.setUpstream(branch, to: remoteBranch.name)
                } label: {
                    if branch.upstream == remoteBranch.name {
                        Label(remoteBranch.name, systemImage: "checkmark")
                    } else {
                        Text(remoteBranch.name)
                    }
                }
            }
            if branch.upstream != nil {
                Divider()
                Button("Unset upstream") { repo.unsetUpstream(branch) }
            }
        }
    }

    private func promptCreate() {
        repo.promptText = ""
        repo.branchPrompt = .createBranch(from: branch)
    }

    private func promptRename() {
        repo.promptText = branch.name
        repo.branchPrompt = .rename(branch)
    }
}
