import SwiftUI

/// Left panel: local branches, remote branches, worktrees.
struct SidebarView: View {
    @ObservedObject var repo: RepoState
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section {
                ForEach(BranchTree.build(repo.snapshot.localBranches, path: \.name)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
            } header: {
                SectionHeader(
                    title: "Local",
                    count: repo.snapshot.localBranches.count,
                    actionHelp: "Create branch at HEAD"
                ) { repo.promptNewBranch() }
            }
            Section {
                ForEach(BranchTree.remoteTree(repo.snapshot.remoteBranches)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
                if repo.snapshot.remoteBranches.isEmpty {
                    Button {
                        repo.promptAddRemote()
                    } label: {
                        Label("Add Remote…", systemImage: "plus.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            } header: {
                SectionHeader(
                    title: "Remote",
                    count: repo.snapshot.remoteNames.count,
                    actionHelp: "Add remote"
                ) { repo.promptAddRemote() }
            }
            Section {
                ForEach(repo.snapshot.worktrees) { wt in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wt.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if let branch = wt.branch {
                                Text(branch)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .help(wt.path)
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
                SectionHeader(title: "Worktrees", count: repo.snapshot.worktrees.count)
            }
            if !repo.snapshot.tags.isEmpty {
                Section {
                    ForEach(repo.snapshot.tags) { tag in
                        HStack(spacing: 6) {
                            Image(systemName: "tag")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text(tag.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { repo.locate(tag.hash) }
                        .help("\(tag.name) @ \(String(tag.hash.prefix(7))) — click to locate")
                        .contextMenu {
                            Button("Checkout \(tag.name) (detached)") { repo.checkoutTag(tag) }
                            Divider()
                            Button("Push tag to \(repo.snapshot.defaultRemote)") { repo.pushTag(tag) }
                            Button("Copy tag name") { RepoState.copyToPasteboard(tag.name) }
                            Divider()
                            Button("Delete tag…", role: .destructive) { repo.tagToDelete = tag }
                        }
                    }
                } header: {
                    SectionHeader(title: "Tags", count: repo.snapshot.tags.count)
                }
            }
            if !repo.snapshot.stashes.isEmpty {
                Section {
                    ForEach(repo.snapshot.stashes) { stash in
                        HStack(spacing: 6) {
                            Image(systemName: "tray.full")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stash.message)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(stash.ref) · \(stash.date.formatted(.relative(presentation: .named)))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .help(stash.message)
                        .contextMenu {
                            Button("Apply (keep stash)") { repo.applyStash(stash) }
                            Button("Pop (apply and remove)") { repo.popStash(stash) }
                            Divider()
                            Button("Drop…", role: .destructive) { repo.stashToDrop = stash }
                        }
                        .onTapGesture(count: 2) { repo.applyStash(stash) }
                    }
                } header: {
                    SectionHeader(title: "Stashes", count: repo.snapshot.stashes.count)
                }
            }
            if !repo.snapshot.submodules.isEmpty {
                Section {
                    ForEach(repo.snapshot.submodules) { sub in
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 11))
                                .foregroundStyle(sub.state == " " ? Color.secondary : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sub.displayName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                if sub.state != " " {
                                    Text(sub.stateDescription)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .help("\(sub.path) @ \(String(sub.sha.prefix(7))) — \(sub.stateDescription)")
                        .contextMenu {
                            Button("Open as Tab") {
                                appState.open(path: repo.path + "/" + sub.path)
                            }
                            Button("Update (init, recursive)") { repo.updateSubmodules() }
                        }
                        .onTapGesture(count: 2) {
                            appState.open(path: repo.path + "/" + sub.path)
                        }
                    }
                } header: {
                    SectionHeader(title: "Submodules", count: repo.snapshot.submodules.count)
                }
            }
        }
        .listStyle(.sidebar)
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
        }
        .sheet(isPresented: $repo.showAddRemote) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Remote")
                    .font(.headline)
                TextField("Name (e.g. origin)", text: $repo.newRemoteName)
                TextField("URL (https://… or git@…)", text: $repo.newRemoteURL)
                    .frame(minWidth: 320)
                HStack {
                    Spacer()
                    Button("Cancel") { repo.showAddRemote = false }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Add & Fetch") { repo.confirmAddRemote() }
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
            if case .remote(let remote) = repo.branchToDelete?.kind {
                Text("This deletes the branch on the \"\(remote)\" remote. Others using it will lose it.")
            } else {
                Text("The branch will be force-deleted, including unmerged commits.")
            }
        }
    }

    private var deleteTitle: String {
        guard let branch = repo.branchToDelete else { return "" }
        if case .remote = branch.kind { return "Delete \(branch.name) on remote?" }
        return "Delete \(branch.name)?"
    }
}

/// GitKraken-style section header: count on the right, and (when the
/// section has an action) a large bordered + button that appears on hover.
struct SectionHeader: View {
    let title: String
    let count: Int
    var actionHelp: String?
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            // Count and + button share one centered slot, so the swap on
            // hover never shifts anything.
            ZStack {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .opacity(action != nil && hovering ? 0 : 1)
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
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
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One sidebar tree row: a folder (git-flow prefix or a remote) or a branch.
struct BranchNodeRow: View {
    let node: BranchNode
    @ObservedObject var repo: RepoState

    var body: some View {
        if let branch = node.branch {
            BranchRow(branch: branch, label: node.name, repo: repo)
        } else {
            FolderDisclosure(node: node, repo: repo)
        }
    }
}

/// Folder row where clicking ANYWHERE on the row toggles expansion,
/// not just the chevron.
struct FolderDisclosure: View {
    let node: BranchNode
    @ObservedObject var repo: RepoState
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(node.children ?? []) { child in
                BranchNodeRow(node: child, repo: repo)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.id.hasPrefix("remote:") && !node.id.dropFirst(7).contains("/")
                    ? "cloud" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }
            .contextMenu {
                if isRemoteRoot {
                    Button("Fetch \(node.name) only") { repo.fetchRemoteOnly(node.name) }
                    Button("Copy URL") { repo.copyRemoteURL(node.name) }
                    Divider()
                    Button("Remove Remote…", role: .destructive) {
                        repo.remoteToRemove = node.name
                    }
                }
            }
        }
    }

    /// Top-level remote node ("remote:origin"), not a folder inside it.
    private var isRemoteRoot: Bool {
        node.id.hasPrefix("remote:") && !node.id.dropFirst(7).contains("/")
    }
}

struct BranchRow: View {
    let branch: Branch
    var label: String?
    @ObservedObject var repo: RepoState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
            Text(label ?? branch.name)
                .font(.system(size: 12, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if repo.soloRev == branch.name {
                Text("SOLO")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if branch.upstreamGone {
                Text("gone")
                    .font(.system(size: 9, weight: .medium))
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .help("\(branch.ahead) ahead, \(branch.behind) behind \(branch.upstream ?? "upstream")")
            }
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .onTapGesture(count: 2) {
            if !branch.isCurrent { repo.checkout(branch) }
        }
        // Single click locates the branch tip in the graph (GitKraken).
        .onTapGesture { repo.locate(branch.tipHash) }
        .help(branch.isCurrent ? "Current branch — click to locate" : "Click to locate, double-click to checkout")
        .opacity(repo.hiddenRefs.contains(branch.refPath) ? 0.45 : 1)
    }

    /// GitKraken-style menus: three variants — current branch,
    /// other local branch, remote branch.
    @ViewBuilder
    private var menuItems: some View {
        let current = repo.snapshot.currentBranch ?? "HEAD"

        if branch.isCurrent {
            Button("Pull (fast-forward if possible)") { repo.pull() }
            Button("Push") { repo.push() }
            Button("Set Upstream to \(repo.snapshot.defaultRemote)/\(branch.name)") { repo.setUpstream(branch) }
            Divider()
            Button("Create branch here…") { promptCreate() }
            Button("Rename…") { promptRename() }
        } else {
            Button("Checkout \(branch.shortName)") { repo.checkout(branch) }
            Divider()
            Button("Merge \(branch.name) into \(current)") { repo.merge(branch) }
            Button("Rebase \(current) onto \(branch.name)") { repo.rebaseOnto(branch) }
            Divider()
            Button("Create branch here…") { promptCreate() }
            if case .local = branch.kind {
                Button("Rename…") { promptRename() }
            }
            if case .remote = branch.kind {
                Button("Create worktree from \(branch.shortName)…") { repo.addWorktree(for: branch) }
            }
            Divider()
            if case .remote = branch.kind {
                Button("Delete on remote…", role: .destructive) { repo.branchToDelete = branch }
            } else {
                Button("Delete…", role: .destructive) { repo.branchToDelete = branch }
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

    private func promptCreate() {
        repo.promptText = ""
        repo.branchPrompt = .createBranch(from: branch)
    }

    private func promptRename() {
        repo.promptText = branch.name
        repo.branchPrompt = .rename(branch)
    }
}
