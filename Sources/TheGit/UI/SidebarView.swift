import SwiftUI

/// Left panel: local branches, remote branches, worktrees.
struct SidebarView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        List {
            Section("Local") {
                ForEach(repo.snapshot.localBranches) { branch in
                    BranchRow(branch: branch, repo: repo)
                }
            }
            Section("Remote") {
                ForEach(repo.snapshot.remoteBranches) { branch in
                    BranchRow(branch: branch, repo: repo)
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
        }
        .listStyle(.sidebar)
    }
}

struct BranchRow: View {
    let branch: Branch
    @ObservedObject var repo: RepoState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
            Text(branch.name)
                .font(.system(size: 12, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Checkout") { repo.checkout(branch) }
                .disabled(branch.isCurrent)
        }
        .onTapGesture(count: 2) {
            if !branch.isCurrent { repo.checkout(branch) }
        }
        .help(branch.isCurrent ? "Current branch" : "Double-click to checkout")
    }
}
