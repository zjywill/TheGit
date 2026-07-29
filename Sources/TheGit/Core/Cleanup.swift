import Foundation

/// Something the repo has finished with, plus the evidence for saying so.
/// Nothing here is ever acted on without the user clicking it.
struct CleanupCandidate: Identifiable, Hashable {
    enum Target: Hashable {
        /// `tip` is kept so a delete can be undone: `git branch <name> <tip>`
        /// puts it back byte for byte.
        case branch(name: String, tip: String)
        case worktree(path: String, prunable: Bool)
    }

    enum Reason: Hashable {
        case mergedPullRequest(number: Int, prefix: String)
        case squashMerged(into: String)
        case merged(into: String)
        case upstreamGone(String)
        case worktreeGone
    }

    let target: Target
    let reason: Reason
    /// Commits that exist nowhere else. Non-zero means deleting loses work,
    /// so the row asks before doing anything.
    var strandedCommits = 0
    /// Uncommitted and untracked entries sitting in a worktree folder.
    /// git won't remove such a folder without `--force`, so this is both
    /// what the row warns about and what decides whether to pass it.
    var dirtyEntries = 0

    var id: String {
        switch target {
        case .branch(let name, _): return "branch:" + name
        case .worktree(let path, _): return "worktree:" + path
        }
    }

    var name: String {
        switch target {
        case .branch(let name, _): return name
        case .worktree(let path, _): return (path as NSString).lastPathComponent
        }
    }

    var isWorktree: Bool {
        if case .worktree = target { return true }
        return false
    }

    var reasonText: String {
        switch reason {
        case .mergedPullRequest(let number, let prefix): return "\(prefix)\(number) merged"
        case .squashMerged(let base): return "squash-merged into \(base)"
        case .merged(let base): return "merged into \(base)"
        case .upstreamGone(let upstream):
            return upstream.isEmpty ? "upstream deleted" : "\(upstream) deleted"
        case .worktreeGone: return "folder no longer exists"
        }
    }

    /// Safe means: the work provably lives somewhere else, and nothing on
    /// disk gets deleted. Safe cleans one click; everything else asks first.
    var isSafe: Bool {
        if case .worktree(_, let prunable) = target { return prunable }
        return strandedCommits == 0
    }

    /// What the user stands to lose — shown in orange on the row itself,
    /// so the risk is visible before the click, not after.
    var riskText: String? {
        if case .worktree(_, let prunable) = target {
            if prunable { return nil }
            guard dirtyEntries > 0 else { return "deletes the folder on disk" }
            return "deletes the folder and \(dirtyEntries) uncommitted "
                + (dirtyEntries == 1 ? "change" : "changes")
        }
        guard strandedCommits > 0 else { return nil }
        return "\(strandedCommits) commit\(strandedCommits == 1 ? "" : "s") only here"
    }
}
