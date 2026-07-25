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
                }
            } header: {
                SectionHeader(title: "Worktrees", count: repo.snapshot.worktrees.count)
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
