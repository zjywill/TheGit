import SwiftUI

/// Left panel: local branches, remote branches, worktrees.
struct SidebarView: View {
    @ObservedObject var repo: RepoState
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    /// Local, not on RepoState: a filter is a way of looking at the repo,
    /// not a fact about it — it should die with the view, and each repo tab
    /// keeps its own.
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var hoveringHead = false

    var body: some View {
        VStack(spacing: 0) {
            headChip
            filterField
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
                    localSection
                    remoteSection
                    forgeSection
                    worktreeSection
                    tagSection
                    stashSection
                    lfsSection
                    submoduleSection
                    if filtering, !hasAnyMatch {
                        SidebarRow(icon: "magnifyingglass") {
                            Text("No matches for “\(query)”")
                                .zoomFont(11)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
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

    // MARK: - HEAD

    /// The branch you are standing on, pinned above everything else.
    /// The tree below can always hide this one fact — the branch sits in a
    /// collapsed folder, the filter excludes it, the list is scrolled past
    /// it — so it gets a line nothing can fold away. Clicking takes the
    /// graph back to HEAD, exactly what clicking the branch in the tree
    /// does: one place, one meaning.
    @ViewBuilder
    private var headChip: some View {
        let branch = repo.snapshot.headBranch
        let head = repo.snapshot.headHash
        if branch != nil || head != nil {
            let detached = branch == nil
            let tint = detached ? Color.orange : Color.accentColor
            Button {
                repo.locateHead()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6 * zoom) {
                    // Same glyph whether or not HEAD is detached: colour and
                    // wording carry the difference, the identity doesn't.
                    Image(systemName: "arrow.triangle.branch")
                        .zoomFont(11)
                        .foregroundStyle(tint)
                    if let branch {
                        Text(branch.name)
                            .zoomFont(12, weight: .semibold)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            // Branch names share their prefixes (feat/…,
                            // fix/…); the end is what tells them apart.
                            .truncationMode(.middle)
                    } else {
                        Text("detached at \(String((head ?? "").prefix(7)))")
                            .zoomFont(12, weight: .semibold, design: .monospaced)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let branch, branch.ahead > 0 || branch.behind > 0 {
                        HStack(spacing: 3) {
                            if branch.ahead > 0 {
                                Text("↑\(branch.ahead)").foregroundStyle(.teal)
                            }
                            if branch.behind > 0 {
                                Text("↓\(branch.behind)").foregroundStyle(.orange)
                            }
                        }
                        .zoomFont(10, weight: .semibold, design: .monospaced)
                    }
                    // Fixed slot, so revealing the hint on hover moves
                    // nothing: the counts to its left must not twitch.
                    Image(systemName: "scope")
                        .zoomFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 11 * zoom)
                        .opacity(hoveringHead ? 1 : 0)
                }
                .padding(.horizontal, 8 * zoom)
                .frame(height: 24 * zoom)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(hoveringHead ? 0.18 : 0.10))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.rowPressEffect)
            .onHover { hoveringHead = $0 }
            // Hover is the only thing that fades here, and only in colour:
            // the row itself never moves, so the pointer can cross the
            // sidebar without anything shifting under it.
            .animation(.easeOut(duration: 0.12), value: hoveringHead)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .help(detached
                ? "HEAD is detached — click to show it in the graph"
                : "On \(branch?.name ?? "") — click to show it in the graph")
        }
    }

    // MARK: - Filter

    /// Pinned above the scroller, not inside it: a filter that scrolls away
    /// stops explaining why the list is short.
    private var filterField: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "magnifyingglass")
                .zoomFont(11)
                .foregroundStyle(filterFocused ? Color.accentColor : .secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .zoomFont(12)
                .focused($filterFocused)
                // Esc clears first and only gives up focus once it's empty,
                // so one key both undoes the filter and leaves the field.
                .onExitCommand {
                    if filter.isEmpty {
                        filterFocused = false
                    } else {
                        filter = ""
                    }
                }
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .zoomFont(11)
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
            // Hidden ⇧⌘F target. ⌘F belongs to the toolbar's commit search;
            // this is the sidebar's own field, so it takes the shifted one.
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .frame(width: 0)
                .opacity(0)
        }
        .padding(.horizontal, 8 * zoom)
        .frame(height: 24 * zoom)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    filterFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: filterFocused)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .help("Filter branches, tags, stashes, worktrees and submodules (⇧⌘F)")
    }

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }
    private var filtering: Bool { !query.isEmpty }

    /// Substring match on whatever the row actually shows. Deliberately not
    /// fuzzy: a branch list is something you already know the name of, and
    /// fuzzy matching turns "fix" into half the repo.
    private func matching<T>(_ items: [T], _ text: (T) -> String) -> [T] {
        guard filtering else { return items }
        return items.filter { text($0).localizedCaseInsensitiveContains(query) }
    }

    // Matching happens on the flat lists, before the folder tree is built,
    // so folders with no surviving children disappear on their own.
    private var matchedLocal: [Branch] { matching(repo.snapshot.localBranches) { $0.name } }
    /// Full name, prefix included: typing "origin" is how you ask for one
    /// remote's branches.
    private var matchedRemote: [Branch] { matching(repo.snapshot.remoteBranches) { $0.name } }
    private var matchedPRs: [PullRequest] {
        matching(repo.pullRequests) { "#\($0.number) \($0.title) \($0.branch) \($0.author)" }
    }
    private var matchedWorktrees: [Worktree] {
        matching(repo.snapshot.worktrees) { "\($0.displayName) \($0.branch ?? "") \($0.path)" }
    }
    private var matchedTags: [Tag] { matching(repo.snapshot.tags) { $0.name } }
    private var matchedStashes: [Stash] { matching(repo.snapshot.stashes) { "\($0.ref) \($0.message)" } }
    private var matchedLFS: [String] { matching(repo.snapshot.lfs.patterns) { $0 } }
    private var matchedSubmodules: [Submodule] {
        matching(repo.snapshot.submodules) { "\($0.displayName) \($0.path)" }
    }

    private var hasAnyMatch: Bool {
        !matchedLocal.isEmpty || !matchedRemote.isEmpty || !matchedPRs.isEmpty
            || !matchedWorktrees.isEmpty || !matchedTags.isEmpty || !matchedStashes.isEmpty
            || !matchedLFS.isEmpty || !matchedSubmodules.isEmpty
    }

    // MARK: - Sections

    // Each section is its own property: the body used to be one expression
    // large enough to be slow to type-check, and filtering adds a condition
    // to every branch of it.

    @ViewBuilder
    private var localSection: some View {
        let branches = matchedLocal
        // While filtering, a section with nothing in it is noise — the
        // header would claim a "Local" group that isn't there.
        if !filtering || !branches.isEmpty {
            SectionHeader(
                title: "Local",
                count: branches.count,
                topSpace: 0,
                actionHelp: "Create branch at HEAD"
            ) { repo.promptNewBranch() }
            ForEach(BranchTree.build(branches, path: \.name)) { node in
                BranchNodeRow(node: node, repo: repo, forceExpanded: filtering)
            }
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        let branches = matchedRemote
        if !filtering || !branches.isEmpty {
            SectionHeader(
                title: "Remote",
                // Unfiltered, this section's unit is the remote — that's
                // what the rows collapse to. Filtering counts branches,
                // because that's what the user is looking at.
                count: filtering ? branches.count : repo.snapshot.remoteNames.count,
                actionHelp: "Add remote"
            ) { repo.promptAddRemote() }
            ForEach(BranchTree.remoteTree(branches)) { node in
                BranchNodeRow(node: node, repo: repo, forceExpanded: filtering)
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
    }

    /// Only present when the repo's host has a CLI installed — otherwise
    /// the feature leaves no trace at all.
    @ViewBuilder
    private var forgeSection: some View {
        if let forge = repo.forge {
            let prs = matchedPRs
            if !filtering || !prs.isEmpty {
                SectionHeader(
                    title: forge.sectionTitle,
                    count: prs.count,
                    // A "0" next to a failed list reads as "none open",
                    // which is exactly the wrong thing to believe.
                    countLabel: repo.forgeError == nil ? nil : "—",
                    actionIcon: "arrow.clockwise",
                    actionHelp: "Refresh \(forge.sectionTitle.lowercased())"
                ) { repo.refreshPullRequests() }
                // Both of these explain an empty section, so they'd be a
                // second, contradictory answer while a filter is on.
                if !filtering {
                    if let error = repo.forgeError {
                        SidebarRow(icon: "exclamationmark.triangle", iconColor: .secondary) {
                            Text(error.summary)
                                .zoomFont(10)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        // The CLI's own words stay one hover away — the row
                        // itself is for the sentence you can act on.
                        .help(error.detail + "\n\nClick to try again.")
                        .onTapGesture { repo.refreshPullRequests() }
                    } else if repo.pullRequests.isEmpty {
                        SidebarRow(icon: nil) {
                            Text(repo.loadingPullRequests ? "Loading…" : "No open \(forge.itemNoun.lowercased())s")
                                .zoomFont(11)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                ForEach(prs) { pr in
                    PullRequestRow(pr: pr, forge: forge, repo: repo)
                }
            }
        }
    }

    @ViewBuilder
    private var worktreeSection: some View {
        let worktrees = matchedWorktrees
        if !filtering || !worktrees.isEmpty {
            SectionHeader(title: "Worktrees", count: worktrees.count)
            ForEach(worktrees) { wt in
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
    }

    @ViewBuilder
    private var tagSection: some View {
        let tags = matchedTags
        if !tags.isEmpty {
            SectionHeader(title: "Tags", count: tags.count)
            ForEach(tags) { tag in
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

    @ViewBuilder
    private var stashSection: some View {
        let stashes = matchedStashes
        if !stashes.isEmpty {
            SectionHeader(title: "Stashes", count: stashes.count)
            ForEach(stashes) { stash in
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

    /// Only in repos that actually use LFS — and only when the binary is
    /// installed, which is what makes the status readable in the first place.
    @ViewBuilder
    private var lfsSection: some View {
        if repo.snapshot.lfs.isEnabled {
            let patterns = matchedLFS
            if !filtering || !patterns.isEmpty {
                SectionHeader(
                    title: "Git LFS",
                    count: filtering ? patterns.count : repo.snapshot.lfs.files.count,
                    actionIcon: "arrow.down.circle",
                    actionHelp: "Download LFS objects (git lfs pull)"
                ) { repo.pullLFSObjects() }
                let missing = repo.snapshot.lfsMissing.count
                // A repo-wide total has nothing to do with the filter, so
                // it would read as a match that it isn't.
                if missing > 0, !filtering {
                    SidebarRow(icon: "arrow.down.circle.dotted", iconColor: .orange) {
                        Text("\(missing) not downloaded")
                            .zoomFont(11)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    .help("These files are pointers only — click to run git lfs pull")
                    .onTapGesture { repo.pullLFSObjects() }
                }
                ForEach(patterns, id: \.self) { pattern in
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
    }

    /// Always shown when unfiltered, empty or not: the + is the only way in
    /// to "Add Submodule…", and a repo with none is where you add one.
    @ViewBuilder
    private var submoduleSection: some View {
        let submodules = matchedSubmodules
        if !filtering || !submodules.isEmpty {
            SectionHeader(
                title: "Submodules",
                count: submodules.count,
                actionHelp: "Add submodule"
            ) { repo.promptAddSubmodule() }
            ForEach(submodules) { sub in
                SubmoduleRow(sub: sub, repo: repo)
            }
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
    /// Stands in for the count when the number would lie — an "—" while the
    /// list couldn't be fetched, rather than a confident 0.
    var countLabel: String?
    /// Space above the header, i.e. the gap that separates this group from
    /// the previous one. Only the first section overrides it (to 0) — the
    /// scroller's own top inset already stands in for the gap there.
    var topSpace: CGFloat = SidebarMetrics.sectionGap
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
                // Small type wants a little more air between letters, and
                // the extra width is the cheapest way to make an 11pt label
                // read as a label rather than as a 12pt row that shrank.
                .tracking(0.3)
                .foregroundStyle(.secondary)
            Spacer()
            // Count and + button share one centered slot, so the swap on
            // hover never shifts anything.
            ZStack {
                // String(count), never "\(count)": SwiftUI localises an Int
                // interpolated into a Text and 1000 becomes "1,000".
                Text(countLabel ?? String(count))
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(
                        countLabel == nil
                            ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.8)
                    )
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
        // Outside the hover shape on purpose: the gaps belong to the layout,
        // not to the header's hit area, or the + would arm itself while the
        // pointer is still in the space between two sections.
        .padding(.top, topSpace * zoom)
        .padding(.bottom, SidebarMetrics.headerGap * zoom)
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
    /// Above a section header: the gap that says "a new group starts here".
    static let sectionGap: CGFloat = 18
    /// Below a section header, before its own first row. Deliberately much
    /// smaller than `sectionGap` — proximity is the only thing telling the
    /// eye which rows the header owns, so the two values have to stay far
    /// enough apart to be read as different. It used to be 0: the header
    /// and the first row were both 22pt boxes sitting flush, and the only
    /// air under the label was whatever the hidden + button's 22pt hit
    /// target happened to leave, which is a byproduct rather than a choice.
    static let headerGap: CGFloat = 5
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
    /// Set while the sidebar is filtered: a match buried in a collapsed
    /// folder is a match the filter failed to show.
    var forceExpanded = false

    var body: some View {
        if let branch = node.branch {
            BranchRow(branch: branch, label: node.name, depth: depth, repo: repo)
        } else {
            FolderRow(node: node, depth: depth, repo: repo, forceExpanded: forceExpanded)
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
    var forceExpanded = false

    /// Filtering opens every folder without touching the user's own
    /// expansion state, so clearing the filter puts the tree back exactly
    /// as they left it.
    private var expanded: Bool { forceExpanded || repo.expandedNodes.contains(node.id) }

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
            // Collapsing is off while filtering: the row can't close, so a
            // tap would only silently rearrange the tree the filter is
            // hiding — noticed later, as a folder that changed by itself.
            guard !forceExpanded else { return }
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
                BranchNodeRow(node: child, depth: depth + 1, repo: repo, forceExpanded: forceExpanded)
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
        .help("\(forge.label(pr.number)) \(pr.title)\n\(pr.branch)\n\nDouble-click to open in the browser.")
        .contextTarget("pr:\(pr.number)", repo)
        .contextMenu {
            Button("Open in Browser") { repo.openPullRequestInBrowser(pr) }
            Button("Checkout \(forge.label(pr.number))") { repo.checkoutPullRequest(pr) }
            Divider()
            Button("Copy URL") { RepoState.copyToPasteboard(pr.url) }
            Button("Copy branch name") { RepoState.copyToPasteboard(pr.branch) }
            Divider()
            Button("Refresh") { repo.refreshPullRequests() }
        }
        // Opening the page is what you almost always want from this row,
        // and it changes nothing locally. Checkout moves HEAD, so it stays
        // an explicit choice in the menu.
        .onTapGesture(count: 2) { repo.openPullRequestInBrowser(pr) }
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

    /// One remote: a plain Push — `push()` picks the remote and sets the
    /// upstream itself when the branch hasn't got one. Several: pick, because
    /// "git push" with no upstream and two remotes has no correct default.
    @ViewBuilder
    private var pushMenu: some View {
        let remotes = repo.snapshot.remoteNames
        if remotes.count > 1 {
            Menu("Push to") {
                ForEach(remotes, id: \.self) { remote in
                    Button(branch.upstream == nil
                        ? "\(remote) (set upstream)"
                        : remote) {
                        repo.push(branch, to: remote)
                    }
                }
            }
        } else if branch.isCurrent {
            Button("Push") { repo.push() }
        } else {
            // Bare `git push` would push HEAD, not the branch clicked on.
            Button("Push") { repo.push(branch, to: repo.remote(for: branch)) }
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
