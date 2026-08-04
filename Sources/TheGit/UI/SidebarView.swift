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
    /// Folded sections. AppStorage, not @State: closing a backlog you
    /// don't want in your face is a decision about the app, and it should
    /// hold across tabs and launches — unlike the filter above, which is
    /// a way of looking and dies with the view.
    @AppStorage("TheGit.sidebar.issuesCollapsed") private var issuesCollapsed = false
    @AppStorage("TheGit.sidebar.pullRequestsCollapsed") private var prsCollapsed = false
    @AppStorage("TheGit.sidebar.localCollapsed") private var localCollapsed = false
    @AppStorage("TheGit.sidebar.remoteCollapsed") private var remoteCollapsed = false
    @AppStorage("TheGit.sidebar.worktreesCollapsed") private var worktreesCollapsed = false
    @AppStorage("TheGit.sidebar.tagsCollapsed") private var tagsCollapsed = false
    @AppStorage("TheGit.sidebar.stashesCollapsed") private var stashesCollapsed = false
    @AppStorage("TheGit.sidebar.lfsCollapsed") private var lfsCollapsed = false
    @AppStorage("TheGit.sidebar.submodulesCollapsed") private var submodulesCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            headChip
            filterField
            // ScrollView + LazyVStack instead of List: List is NSTableView
            // underneath, and it was the app's one source of AppKit layout
            // exceptions (reentrant-delegate asserts, fatal under zoom changes).
            // Same reasoning as the graph column.
            ScrollView {
                // Every row carries its own height (SidebarMetrics.row), so the
                // vertical rhythm is a property of the rows rather than of the
                // gaps between them — which is what lets one-line and two-line
                // rows sit on the same grid. The 2pt gap is only so that two
                // filled rows (hovered, selected) read as two rows and not as
                // one taller block; the section paddings give it back.
                // pinnedViews, so every group's header stays on screen while
                // its own rows scroll under it: in a repo with fifty branches
                // the list you are looking at is the one fact the sidebar
                // used to lose first — you scroll into the middle of it and
                // nothing says whether these are locals, tags or stashes.
                LazyVStack(
                    alignment: .leading,
                    spacing: SidebarMetrics.rowGap,
                    pinnedViews: [.sectionHeaders]
                ) {
                    localSection
                    remoteSection
                    forgeSection
                    issueSection
                    worktreeSection
                    tagSection
                    stashSection
                    lfsSection
                    submoduleSection
                    if filtering, !hasAnyMatch {
                        SidebarRow(icon: "magnifyingglass", hoverable: false) {
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
            // Pinned under the scroller, not inside it: it describes the
            // repo rather than sitting in the list of its refs, and it's
            // the one thing here that's worth a glance without scrolling.
            // A repo with no commits at all gets no grid — a whole empty
            // quarter is a wrong answer to "nothing has happened yet".
            if !repo.snapshot.commits.isEmpty {
                Divider()
                ActivityGraph(counts: repo.snapshot.activity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
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
            Button("Refresh") { Task { await repo.refreshAll() } }
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
    private var matchedIssues: [Issue] {
        matching(repo.issues ?? []) { "#\($0.number) \($0.title) \($0.author)" }
    }
    /// Never the checkout this tab already is. `git worktree list` always
    /// includes the directory it ran in, so a repo with no linked worktrees
    /// at all still listed one row — itself, under whatever branch is
    /// checked out — which reads as "HEAD lives in a worktree" when it is
    /// simply this window. Nothing it offers is real either: "Open as Tab"
    /// reopens the tab you are on, and `git worktree remove` refuses the
    /// main working tree. The other entries stay, including the main one
    /// when you're standing in a linked worktree — that's the way back.
    private var matchedWorktrees: [Worktree] {
        let others = repo.snapshot.worktrees.filter {
            AppState.canonical(path: $0.path) != repo.path
        }
        return matching(others) { "\($0.displayName) \($0.branch ?? "") \($0.path)" }
    }
    private var matchedTags: [Tag] { matching(repo.snapshot.tags) { $0.name } }
    private var matchedStashes: [Stash] { matching(repo.snapshot.stashes) { "\($0.ref) \($0.message)" } }
    private var matchedLFS: [String] { matching(repo.snapshot.lfs.patterns) { $0 } }
    private var matchedSubmodules: [Submodule] {
        matching(repo.snapshot.submodules) { "\($0.displayName) \($0.path)" }
    }

    private var hasAnyMatch: Bool {
        !matchedLocal.isEmpty || !matchedRemote.isEmpty || !matchedPRs.isEmpty
            || !matchedIssues.isEmpty || !matchedWorktrees.isEmpty || !matchedTags.isEmpty
            || !matchedStashes.isEmpty || !matchedLFS.isEmpty || !matchedSubmodules.isEmpty
    }

    // MARK: - Sections

    // Each section is its own property: the body used to be one expression
    // large enough to be slow to type-check, and filtering adds a condition
    // to every branch of it.
    //
    // Every one of them is a real `Section` with its header in the header
    // slot — that, and nothing else, is what the LazyVStack pins. A header
    // emitted as a plain sibling row (which is how these were written)
    // scrolls away like any other row.

    @ViewBuilder
    private var localSection: some View {
        let branches = matchedLocal
        // While filtering, a section with nothing in it is noise — the
        // header would claim a "Local" group that isn't there.
        if !filtering || !branches.isEmpty {
            Section {
                // A filter overrides the fold everywhere in this sidebar:
                // asking for "crash" and getting a closed section that
                // secretly holds the match is a wrong answer.
                if !localCollapsed || filtering {
                    ForEach(BranchTree.build(branches, path: \.name)) { node in
                        BranchNodeRow(node: node, repo: repo, forceExpanded: filtering)
                    }
                }
            } header: {
                SectionHeader(
                    title: "Local",
                    count: branches.count,
                    actionHelp: "Create branch at HEAD",
                    collapsed: $localCollapsed
                ) { repo.promptNewBranch() }
            }
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        let branches = matchedRemote
        if !filtering || !branches.isEmpty {
            Section {
                if !remoteCollapsed || filtering {
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
            } header: {
                SectionHeader(
                    title: "Remote",
                    // Unfiltered, this section's unit is the remote — that's
                    // what the rows collapse to. Filtering counts branches,
                    // because that's what the user is looking at.
                    count: filtering ? branches.count : repo.snapshot.remoteNames.count,
                    actionHelp: "Add remote",
                    collapsed: $remoteCollapsed
                ) { repo.promptAddRemote() }
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
                Section {
                    if !prsCollapsed || filtering {
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
                                .onTapGesture { repo.refreshPullRequests(from: .pullRequests) }
                            } else if repo.pullRequests.isEmpty {
                                SidebarRow(icon: nil, hoverable: false) {
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
                } header: {
                    SectionHeader(
                        title: forge.sectionTitle,
                        count: prs.count,
                        // A "0" next to a failed list reads as "none open",
                        // which is exactly the wrong thing to believe.
                        countLabel: repo.forgeError == nil ? nil : "—",
                        actionHelp: "New \(forge.itemNoun)…",
                        secondary: .init(
                            icon: "arrow.clockwise",
                            help: "Refresh \(forge.sectionTitle.lowercased())",
                            spinning: repo.refreshingForgeSection == .pullRequests,
                            run: { repo.refreshPullRequests(from: .pullRequests) }
                        ),
                        collapsed: $prsCollapsed
                    ) { repo.createPullRequest() }
                }
            }
        } else if let missing = repo.missingForgeCLI, !filtering {
            // The host is GitHub/GitLab but the CLI isn't installed. One
            // hint row instead of an invisible feature: this is the only
            // place a user can learn that installing `gh` puts their pull
            // requests in this sidebar.
            Section {
                ForgeInstallHintRow(repo: repo, missing: missing)
            } header: {
                SectionHeader(
                    title: missing.sectionTitle,
                    count: 0,
                    countLabel: "—",
                    secondary: .init(
                        icon: "arrow.clockwise",
                        help: "Check for \(missing.binary) again",
                        run: { repo.recheckForgeCLI() }
                    )
                )
            }
        }
    }

    /// Under the PR section and on the same terms: only when the forge is
    /// live. No section while the list has never loaded — an "Issues —"
    /// header would just restate whatever the PR section's error already
    /// says — but once a fetch has succeeded, an empty section stays: "no
    /// open issues" is an answer, and the section vanishing reads as the
    /// feature breaking.
    @ViewBuilder
    private var issueSection: some View {
        if let forge = repo.forge, repo.issues != nil || repo.loadingPullRequests {
            let issues = matchedIssues
            if !filtering || !issues.isEmpty {
                Section {
                    if !issuesCollapsed || filtering {
                        if !filtering, repo.issues?.isEmpty != false {
                            SidebarRow(icon: nil, hoverable: false) {
                                Text(repo.issues == nil ? "Loading…" : "No open issues")
                                    .zoomFont(11)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        ForEach(issues) { issue in
                            IssueRow(issue: issue, forge: forge, repo: repo)
                        }
                    }
                } header: {
                    SectionHeader(
                        title: "Issues",
                        count: issues.count,
                        countLabel: repo.issues == nil ? "…" : nil,
                        secondary: .init(
                            icon: "arrow.clockwise",
                            help: "Refresh issues",
                            spinning: repo.refreshingForgeSection == .issues,
                            run: { repo.refreshPullRequests(from: .issues) }
                        ),
                        collapsed: $issuesCollapsed
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var worktreeSection: some View {
        let worktrees = matchedWorktrees
        if !worktrees.isEmpty {
            Section {
                // Folded ⇒ iterate nothing; the header still counts the real
                // list. A filter overrides the fold, here and below.
                ForEach(worktreesCollapsed && !filtering ? [] : worktrees) { wt in
                    SidebarRow(icon: "folder") {
                        VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
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
                    .contextTarget("wt:" + wt.path, repo, corner: SidebarMetrics.corner)
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
            } header: {
                SectionHeader(title: "Worktrees", count: worktrees.count, collapsed: $worktreesCollapsed)
            }
        }
    }

    @ViewBuilder
    private var tagSection: some View {
        let tags = matchedTags
        if !tags.isEmpty {
            Section {
                ForEach(tagsCollapsed && !filtering ? [] : tags) { tag in
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
                    .contextTarget("tag:" + tag.name, repo, corner: SidebarMetrics.corner)
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
            } header: {
                SectionHeader(title: "Tags", count: tags.count, collapsed: $tagsCollapsed)
            }
        }
    }

    @ViewBuilder
    private var stashSection: some View {
        let stashes = matchedStashes
        if !stashes.isEmpty {
            Section {
                ForEach(stashesCollapsed && !filtering ? [] : stashes) { stash in
                    // `selected` lights up when the stash's graph node is clicked.
                    SidebarRow(icon: "tray.full", selected: repo.selectedStashRef == stash.ref) {
                        VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
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
                    .help(stash.message)
                    .contextTarget("stash:" + stash.ref, repo, corner: SidebarMetrics.corner)
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
            } header: {
                SectionHeader(title: "Stashes", count: stashes.count, collapsed: $stashesCollapsed)
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
                Section {
                    let missing = repo.snapshot.lfsMissing.count
                    // A repo-wide total has nothing to do with the filter, so
                    // it would read as a match that it isn't.
                    if missing > 0, !filtering, !lfsCollapsed {
                        SidebarRow(icon: "arrow.down.circle.dotted", iconColor: .orange) {
                            Text("\(missing) not downloaded")
                                .zoomFont(11)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        .help("These files are pointers only — click to run git lfs pull")
                        .onTapGesture { repo.pullLFSObjects() }
                    }
                    ForEach(lfsCollapsed && !filtering ? [] : patterns, id: \.self) { pattern in
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
                        .contextTarget("lfs:" + pattern, repo, corner: SidebarMetrics.corner)
                        .contextMenu {
                            Button("Copy pattern") { RepoState.copyToPasteboard(pattern) }
                            Button("Download LFS objects") { repo.pullLFSObjects() }
                        }
                    }
                } header: {
                    SectionHeader(
                        title: "Git LFS",
                        count: filtering ? patterns.count : repo.snapshot.lfs.files.count,
                        actionIcon: "arrow.down.circle",
                        actionHelp: "Download LFS objects (git lfs pull)",
                        collapsed: $lfsCollapsed
                    ) { repo.pullLFSObjects() }
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
            Section {
                ForEach(submodulesCollapsed && !filtering ? [] : submodules) { sub in
                    SubmoduleRow(sub: sub, repo: repo)
                }
            } header: {
                SectionHeader(
                    title: "Submodules",
                    count: submodules.count,
                    actionHelp: "Add submodule",
                    collapsed: $submodulesCollapsed
                ) { repo.promptAddSubmodule() }
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
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
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
        .contextTarget("sub:" + sub.path, repo, corner: SidebarMetrics.corner)
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
///
/// Pinned by the sidebar's LazyVStack, which is why it carries an opaque
/// backdrop of its own: a sticky header is drawn OVER the rows still
/// scrolling past it, and a transparent one lets branch names slide
/// through the letters of its title.
struct SectionHeader: View {
    let title: String
    let count: Int
    /// Stands in for the count when the number would lie — an "—" while the
    /// list couldn't be fetched, rather than a confident 0.
    var countLabel: String?
    var actionIcon = "plus"
    var actionHelp: String?
    /// A second, quieter button left of the primary one. A struct, not a
    /// second closure parameter: two optional closures make every existing
    /// trailing closure ambiguous between forward and backward matching.
    struct Secondary {
        let icon: String
        let help: String
        /// Work this button started still in flight. Turns the glyph, and
        /// holds the button on screen while it turns — otherwise the only
        /// trace of a three-second fetch disappears the moment the pointer
        /// leaves the header.
        var spinning = false
        let run: () -> Void
    }
    var secondary: Secondary?
    /// A collapsible section hands its state in; the header then wears a
    /// disclosure chevron and the whole strip toggles on click. nil — most
    /// sections — means always open, and nothing about the header changes.
    var collapsed: Binding<Bool>?
    var action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    /// What the badge shows. It's a badge, not a number field: past two
    /// digits the exact value tells the eye nothing it can use, and a repo
    /// with 999999 tags would widen this one header's column and knock the
    /// whole right-hand strip out of alignment to say so. So anything over
    /// 99 reads as "99+" and the column stays fixed.
    ///
    /// String(count), never "\(count)": SwiftUI localises an Int
    /// interpolated into a Text and 1000 becomes "1,000".
    private var countText: String {
        if let countLabel { return countLabel }
        return count > 99 ? "99+" : String(count)
    }

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
            // The same chevron the rows carry, in the same rotation
            // grammar: right is closed, down is open.
            if let collapsed {
                Image(systemName: "chevron.right")
                    .zoomFont(8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
            }
            Spacer()
            // Borderless on purpose: two outlined buttons side by side
            // read as a segmented control, and this one is the lesser act.
            if let secondary {
                Button(action: secondary.run) {
                    Image(systemName: secondary.icon)
                        .zoomFont(11, weight: .semibold)
                        .refreshSpin(secondary.spinning)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(Color.accentColor)
                .help(secondary.help)
                // Work in flight keeps it up with the pointer gone: a turning
                // glyph is the only thing on this strip that says the list is
                // being fetched. Visible means clickable — a button you can
                // see and can't press is worse than one that isn't there.
                .opacity(hovering || secondary.spinning ? 1 : 0)
                .allowsHitTesting(hovering || secondary.spinning)
            }
            // Count and + button share one centered slot, so the swap on
            // hover never shifts anything.
            ZStack {
                Text(countText)
                    .zoomFont(11, weight: .semibold)
                    // Digits of equal width, so a count that ticks 9 → 10
                    // doesn't shift its own centre inside the column.
                    .monospacedDigit()
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
            // Fixed, not minWidth: the column has to be the same width on
            // every header for the centres to line up, and a count that
            // outgrew it would drag its own row's centre off the strip.
            .frame(width: SidebarMetrics.badge * zoom, height: 22, alignment: .center)
        }
        // Same trailing inset as the rows, so the counts and the branch
        // ahead/behind badges share one right-hand baseline.
        .padding(.trailing, SidebarMetrics.trailing * zoom)
        .contentShape(Rectangle())
        // The buttons on the strip keep their own clicks; everywhere else
        // toggles. Deliberately not animated, for the same reason the PR
        // list pops in unanimated — a section closing is a full-list
        // reflow, and animating it drags every section below through a
        // cross-fade.
        .onTapGesture { collapsed?.wrappedValue.toggle() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // The buttons only exist on hover (opacity 0 removes them from the
        // accessibility tree too), so VoiceOver gets the header as one
        // element carrying the same acts as custom actions instead.
        .accessibilityElement(children: .ignore)
        // The exact count, not the capped badge: "99+" is a layout
        // compromise, and VoiceOver has no column to keep aligned.
        .accessibilityLabel("\(title), \(countLabel ?? String(count))")
        .accessibilityActions {
            if let collapsed {
                Button(collapsed.wrappedValue ? "Expand" : "Collapse") {
                    collapsed.wrappedValue.toggle()
                }
            }
            if let secondary {
                Button(secondary.help, action: secondary.run)
            }
            if let action {
                Button(actionHelp ?? "New", action: action)
            }
        }
        // Outside the hover shape on purpose: the gaps belong to the layout,
        // not to the header's hit area, or the + would arm itself while the
        // pointer is still in the space between two sections. The gap ABOVE
        // a header now lives at the end of the previous section instead —
        // it would otherwise stick to the ceiling along with the header.
        .padding(.top, SidebarMetrics.headerLead * zoom)
        .padding(.bottom, SidebarMetrics.headerGap * zoom)
        // Under the paddings, so the backdrop covers the air the header
        // owns and no row shows through it — and 10pt wider on both sides,
        // which is the list's own inset: the gutters have no rows of their
        // own to hide, but a strip of background that stops short of the
        // panel edge reads as a floating card rather than as a header.
        // The same sidebar material as the capsule, NOT an opaque window
        // color: behind-window sampling makes the two indistinguishable, so
        // the pinned header only exists while rows scroll under it. The
        // opaque fill this replaces happened to match the material in dark
        // mode and striped the whole panel white in light mode.
        .background {
            SidebarGlass()
                .padding(.horizontal, -10)
        }
    }
}

/// The sidebar's layout grid, at zoom 1. Everything multiplies by
/// `\.uiZoom`, so the columns hold at all five zoom levels.
enum SidebarMetrics {
    /// One row's height. One-line rows are exactly this tall; two-line
    /// rows (worktrees, stashes, PRs) grow past it but keep the same
    /// leading columns. 24 is the macOS list row and what the commit
    /// panel's file rows already use — and every one of these rows is a
    /// click target (locate, expand, select), not just a line of text.
    static let row: CGFloat = 24
    /// Air above and below a row's content. It changes nothing on a
    /// one-line row (15pt of text + 6 still fits inside `row`); it exists
    /// for the two-line rows, where title and subtitle used to run flush
    /// into the next row's title and the eye had no way to tell which
    /// pair of lines belonged together.
    static let rowPad: CGFloat = 3
    /// Between the two lines of a two-line row. 1pt read as a typo rather
    /// than as a gap: the 10pt subtitle needs to sit *under* its title,
    /// not touch it.
    static let lineGap: CGFloat = 2
    /// Row highlight corner. Same radius as the HEAD chip and the filter
    /// field above the list, which are the same width — three surfaces on
    /// one column want one corner.
    static let corner: CGFloat = 6
    /// Between rows. Enough that two highlighted rows read as two rows;
    /// taken back out of the section paddings so the rhythm is unchanged.
    static let rowGap: CGFloat = 2
    /// The trailing column: section counts, the hover buttons that replace
    /// them, and the disclosure chevrons all CENTRE in it. Right-aligning
    /// them instead lines up their edges, which is not what the eye reads —
    /// a 1, an 11 and a 22pt button ending on the same pixel still look
    /// like three columns. 22 is the button's own size, and the widest a
    /// count gets is "99+", which fits inside it.
    static let badge: CGFloat = 22
    /// Disclosure-chevron column, at the TRAILING edge. Kept off the
    /// leading edge on purpose: only folders have a chevron, so a leading
    /// gutter would be dead space on every branch, PR, tag and stash row
    /// — visible as a hole in front of whole sections that contain no
    /// folders at all. On the right it costs nothing, because the rows
    /// that carry one (folders) are the only rows with no trailing badge.
    /// Same width as `badge` so a folder's chevron sits on the same centre
    /// as the count of the section it lives in.
    static let chevron: CGFloat = badge
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
    /// Inside a row, past the badge column — zero on purpose. The list
    /// already sits 10pt in from the panel's edge, the same 10 as the HEAD
    /// chip and the filter field, so anything more here is a second inset
    /// that only the rows pay. And the hover button is a drawn box: its
    /// stroke has to land on the filter field's edge, or the sidebar has
    /// two right edges 4pt apart. The counts and chevrons still read as
    /// inset, because they're centred in the badge column above.
    static let trailing: CGFloat = 0
    /// Inside a pinned header, above its label — and now the only air
    /// between one group and the next.
    ///
    /// There used to be 16pt of spacer at the end of every section as well.
    /// It read as a gap belonging to nothing: folded sections left it hanging
    /// under a closed header, and an expanded one put a hole between its last
    /// row and the next heading that no other list on this screen has. The
    /// headers are opaque strips with their own weight and colour — they
    /// separate the groups by being headers, which is what a pinned header is
    /// for.
    static let headerLead: CGFloat = 2
    /// Below a section header, before its own first row. Bigger than the air
    /// above the label, so proximity still says which rows the header owns —
    /// with no spacer between groups any more, that asymmetry is the only
    /// thing that does. It used to be 0: the header
    /// and the first row were both 22pt boxes sitting flush, and the only
    /// air under the label was whatever the hidden + button's 22pt hit
    /// target happened to leave, which is a byproduct rather than a choice.
    /// Like `sectionGap`, stated net of `rowGap`.
    static let headerGap: CGFloat = 3
}

/// Every row in the sidebar: `[icon][content][chevron]`, fixed columns.
/// Going through one primitive is what makes alignment a structural
/// property instead of something each section has to remember — and now
/// the same for the row's fill: hover and selection are one stack in one
/// place, so no two lists can disagree about what a live row looks like.
struct SidebarRow<Content: View>: View {
    @Environment(\.uiZoom) private var zoom
    var depth = 0
    var chevron = false
    var expanded = false
    /// nil reserves the column without drawing anything, for rows that
    /// are text only ("No open pull requests") but still have to line up.
    var icon: String?
    /// The one icon SF Symbols can't provide: GitHub's own pull-request
    /// shape, hand-drawn as `PullRequestGlyph`. Takes the icon column in
    /// `iconColor` when set; `icon` should then stay nil.
    var pullRequestIcon = false
    var iconColor: Color = .secondary
    /// Row the rest of the UI is currently pointing at — the stash whose
    /// commit is showing, the branch a drag is over. Beats hover, because
    /// it's a fact about the app and hover is only about the pointer.
    var selected = false
    /// Off for the rows that say something instead of doing something
    /// ("No matches", "Loading…"). A highlight on those promises a click
    /// that leads nowhere, which is worse than no feedback at all.
    var hoverable = true
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        // firstTextBaseline, not center: on a two-line row the icon
        // belongs to the title, and centring it against title+subtitle
        // floats it into the gap between them.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if pullRequestIcon {
                    // Bottom lands on the text baseline (the default for a
                    // view with no baseline of its own), which is where an
                    // 11pt symbol's round bottom sits too.
                    PullRequestGlyph()
                        .foregroundStyle(iconColor)
                        .frame(width: 11 * zoom, height: 11 * zoom)
                } else if let icon {
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
        .padding(.vertical, SidebarMetrics.rowPad * zoom)
        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.row * zoom, alignment: .leading)
        // Behind the padding, not inside it: the highlight is the row, so
        // it runs the full width of the list — including under an indented
        // child, the way every macOS source list draws it.
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.corner * zoom)
                .fill(fill)
        )
        .background {
            if hoverable { PressCatcher { pressed = $0 } }
        }
        // Full width, so the empty space to the right of a short branch
        // name is as clickable as the name itself — it wasn't on half the
        // rows before, which made the list feel arbitrary.
        .contentShape(Rectangle())
        .onHover {
            if hoverable { hovering = $0 }
            // The mouse-up that would clear the press can land outside this
            // window, and then it never reaches the monitor. Leaving the row
            // is the backstop.
            if !$0 { pressed = false }
        }
        // Asymmetric on purpose. Arriving is the answer to the pointer and
        // has to be immediate — a fade there is latency you can see, and
        // this list is crossed dozens of times a day. Leaving is the app
        // talking to itself, so it fades: sweeping down twenty branches
        // would otherwise be twenty hard flashes.
        .animation(hovering ? nil : .easeOut(duration: 0.12), value: hovering)
        // Same asymmetry, and here it's the whole point: the press cue has
        // to be on screen before the click is finished, or it isn't feedback
        // — it's a report. The release can afford the 120ms.
        .animation(pressed ? nil : .easeOut(duration: 0.12), value: pressed)
    }

    /// Three states on one channel, deepest first. Selection beats hover —
    /// while a stash is open, the pointer passing over it must not make it
    /// look *less* selected — and a press deepens whichever it lands on.
    ///
    /// Colour only: `rowPressEffect` shrinks the HEAD chip by 1.5%, which on
    /// a 400pt row is 6pt of text sliding under a stationary pointer, in a
    /// list where the next row is 26pt away. A wide target dims, it doesn't
    /// move — the same reasoning that sized that style in the first place,
    /// taken one step further.
    private var fill: Color {
        if selected { return Color.accentColor.opacity(pressed ? 0.24 : 0.15) }
        if pressed { return Color.primary.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.06) : .clear
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
        .contextTarget("node:" + node.id, repo, corner: SidebarMetrics.corner)
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
/// The sidebar's "install gh/glab" hint. Its own view for one reason:
/// the copy needs an acknowledgement (the command line briefly becomes
/// "Copied — paste it in Terminal"), and that transient state belongs to
/// this row, not to the repo.
struct ForgeInstallHintRow: View {
    @ObservedObject var repo: RepoState
    let missing: Forge
    @State private var copied = false

    private var hint: InstallHint { Toolchain.hint(for: missing.cliTool) }

    private func tapped() {
        repo.forgeInstallHintTapped()
        guard hint.isCommand else { return }
        AccessibilityNotification.Announcement("Copied \(hint.display)").post()
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    var body: some View {
        SidebarRow(icon: copied ? "checkmark.circle" : "arrow.down.circle", iconColor: .secondary) {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                Text("Install \(missing.binary) to see \(missing.sectionTitle.lowercased()) here")
                    .zoomFont(10)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(copied ? "Copied — paste it in Terminal" : hint.display)
                    .zoomFont(10, design: .monospaced)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
        .help(
            hint.isCommand
                ? "TheGit drives \(missing.sectionTitle.lowercased()) through the \(missing.binary) CLI.\n\nClick to copy the install command, run it in Terminal, then sign in with `\(missing.loginHint)`."
                : "TheGit drives \(missing.sectionTitle.lowercased()) through the \(missing.binary) CLI.\n\nClick to open its install page. After installing, sign in with `\(missing.loginHint)`."
        )
        .onTapGesture { tapped() }
        // A tap gesture is invisible to VoiceOver; give the row a
        // button's name, trait and action explicitly.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            hint.isCommand
                ? "Copies the install command."
                : "Opens the install page in your browser."
        )
        .accessibilityAction { tapped() }
    }
}

struct PullRequestRow: View {
    let pr: PullRequest
    let forge: Forge
    @ObservedObject var repo: RepoState

    var body: some View {
        SidebarRow(
            pullRequestIcon: true,
            iconColor: pr.isDraft ? Color.secondary : .green
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
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
        .help("\(forge.label(pr.number)) \(pr.title)\n\(pr.branch)\n\nClick to review it here, double-click for the browser.")
        .contextTarget("pr:\(pr.number)", repo, corner: SidebarMetrics.corner)
        .contextMenu {
            // Same transaction-owned fade as the row's click, below.
            Button("Review \(forge.label(pr.number))") {
                repo.openingPanel { repo.viewPullRequest(pr) }
            }
            Button("Open in Browser") { repo.openPullRequestInBrowser(pr) }
            Button("Checkout \(forge.label(pr.number))") { repo.checkoutPullRequest(pr) }
                // Already standing on it: see RepoState.isCheckedOut.
                .disabled(repo.isCheckedOut(pr))
            Divider()
            Button("Copy URL") { RepoState.copyToPasteboard(pr.url) }
            Button("Copy branch name") { RepoState.copyToPasteboard(pr.branch) }
            Divider()
            Button("Refresh") { repo.refreshPullRequests(from: .pullRequests) }
        }
        // The browser stays a double-click away; checkout moves HEAD, so it
        // stays an explicit choice in the menu.
        .onTapGesture(count: 2) { repo.openPullRequestInBrowser(pr) }
        // A single click reviews it in-app — reading the change is what this
        // row is for now. The graph underneath still jumps to the branch tip
        // when we've fetched it, so closing the panel leaves you at the work
        // rather than wherever you were before.
        .onTapGesture {
            if let tip = remoteTip { repo.locate(tip) }
            // The panel's fade-in lives here, not on its transition in
            // RepoView: opening one is the only moment it should play.
            // Attached to the transition it also played on a repo switch,
            // where the panel is merely revealed, and the graph flashed
            // through it on the way up. `openingPanel` is what decides
            // whether this click is that moment — see RepoState.
            repo.openingPanel { repo.viewPullRequest(pr) }
        }
    }

    /// The remote-tracking branch this PR was opened from, when we've fetched it.
    private var remoteTip: String? {
        repo.snapshot.remoteBranches
            .first { $0.shortName == pr.branch }?
            .tipHash
    }
}

struct IssueRow: View {
    let issue: Issue
    let forge: Forge
    @ObservedObject var repo: RepoState

    var body: some View {
        SidebarRow(
            icon: "smallcircle.filled.circle",
            iconColor: .green
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                    HStack(spacing: 4) {
                        Text(forge.label(issue.number))
                            .zoomFont(10, weight: .semibold, design: .monospaced)
                            .foregroundStyle(.tertiary)
                        Text(issue.title)
                            .zoomFont(12)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if !issue.author.isEmpty {
                        Text(issue.author)
                            .zoomFont(10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let created = issue.createdAt {
                    Text(AgeBreaks.compact(date: created))
                        .zoomFont(9)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help("\(forge.label(issue.number)) \(issue.title)\n\nClick to read it here, double-click for the browser.")
        // Unlike a PR row, a single click opens the thread in-app: an
        // issue has no branch tip to locate, so reading it IS the primary
        // action — nothing about the graph changes underneath.
        .onTapGesture(count: 2) { repo.openIssueInBrowser(issue) }
        // The fade belongs to this transaction, not to the panel's
        // transition — see the PR row above.
        .onTapGesture { repo.openingPanel { repo.viewIssue(issue) } }
        .contextMenu {
            Button("View Issue") {
                repo.openingPanel { repo.viewIssue(issue) }
            }
            Button("Open in Browser") { repo.openIssueInBrowser(issue) }
            Divider()
            Button("Copy URL") { RepoState.copyToPasteboard(issue.url) }
            Divider()
            Button("Refresh") { repo.refreshPullRequests(from: .issues) }
        }
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
            iconColor: branch.isCurrent ? Color.accentColor : .secondary,
            // No animation on the drop highlight: it rides the row's fill,
            // and that fill only animates on hover changes — during a drag
            // the pointer is moving fast and a fade reads as lag.
            selected: targeted
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
        .contextTarget("branch:" + branch.name, repo, corner: SidebarMetrics.corner)
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
