import SwiftUI

/// Left panel: local branches, remote branches, worktrees.
struct SidebarView: View {
    @ObservedObject var repo: RepoState
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section("Local") {
                ForEach(BranchTree.build(repo.snapshot.localBranches, path: \.name)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
            }
            Section("Remote") {
                ForEach(BranchTree.remoteTree(repo.snapshot.remoteBranches)) { node in
                    BranchNodeRow(node: node, repo: repo)
                }
            }
            Section("Worktrees") {
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
                }
            }
            if !repo.snapshot.submodules.isEmpty {
                Section("Submodules") {
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
        }
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
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .onTapGesture(count: 2) {
            if !branch.isCurrent { repo.checkout(branch) }
        }
        .help(branch.isCurrent ? "Current branch" : "Double-click to checkout")
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
