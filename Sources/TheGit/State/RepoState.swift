import Foundation
import SwiftUI

/// Observable state for one open repository (one tab).
@MainActor
final class RepoState: ObservableObject, Identifiable {
    let path: String
    let git: GitClient

    @Published var snapshot = RepoSnapshot()
    @Published var commitMessage = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var selectedCommit: String?

    nonisolated var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    init(path: String) {
        self.path = path
        self.git = GitClient(repoPath: path)
    }

    private var hasLoaded = false

    /// Called when the repo tab appears. First time: full load with busy
    /// indicator. Subsequent tab switches show cached data instantly and
    /// only freshen quietly in the background — switching tabs is a
    /// many-times-a-day action and must never flash a spinner.
    func appeared() async {
        if hasLoaded {
            await refresh(quiet: true)
        } else {
            hasLoaded = true
            await refresh()
        }
    }

    func refresh(quiet: Bool = false) async {
        if !quiet { isBusy = true }
        defer { if !quiet { isBusy = false } }
        do {
            async let commits = git.log()
            async let branches = git.branches()
            async let worktrees = git.worktrees()
            async let status = git.status()

            var snap = RepoSnapshot()
            snap.commits = try await commits
            snap.graphRows = GraphLayout.layout(commits: snap.commits)
            let b = try await branches
            snap.localBranches = b.local
            snap.remoteBranches = b.remote
            snap.worktrees = try await worktrees
            let s = try await status
            snap.staged = s.staged
            snap.unstaged = s.unstaged
            snap.currentBranch = s.branch
            snapshot = snap
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run a mutating git action, then refresh everything.
    func perform(_ action: @escaping (GitClient) async throws -> Void) {
        Task {
            isBusy = true
            do {
                try await action(git)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    // MARK: - Convenience actions

    func stage(_ file: FileChange) { perform { try await $0.stage(file.path) } }
    func unstage(_ file: FileChange) { perform { try await $0.unstage(file.path) } }
    func stageAll() { perform { try await $0.stageAll() } }
    func unstageAll() { perform { try await $0.unstageAll() } }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !snapshot.staged.isEmpty else { return }
        Task {
            isBusy = true
            do {
                try await git.commit(message: message)
                commitMessage = "" // only clear once the commit actually succeeded
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    func checkout(_ branch: Branch) {
        perform { git in
            if case .remote = branch.kind {
                try await git.checkoutRemote(branch)
            } else {
                try await git.checkout(branch: branch.name)
            }
        }
    }

    func fetch() { perform { try await $0.fetch() } }
    func pull() { perform { try await $0.pull() } }
    func push() { perform { try await $0.push() } }
}
