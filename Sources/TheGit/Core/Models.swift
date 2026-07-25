import Foundation

struct Commit: Identifiable, Hashable {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let refs: [String]
    let subject: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

enum BranchKind: Hashable {
    case local
    case remote(String) // remote name, e.g. "origin"
}

struct Branch: Identifiable, Hashable {
    let name: String      // e.g. "main" or "origin/main"
    let kind: BranchKind
    let isCurrent: Bool
    /// Commits ahead/behind the upstream (local branches with an upstream only).
    var ahead: Int = 0
    var behind: Int = 0
    /// Upstream ref short name, nil when none is configured.
    var upstream: String?
    /// Upstream is configured but the remote branch no longer exists.
    var upstreamGone: Bool = false

    var id: String { name }
    /// Branch name without the remote prefix, e.g. "origin/feature/x" -> "feature/x"
    var shortName: String {
        if case .remote(let remote) = kind, name.hasPrefix(remote + "/") {
            return String(name.dropFirst(remote.count + 1))
        }
        return name
    }

    /// Full ref path, e.g. "refs/heads/main" / "refs/remotes/origin/main".
    var refPath: String {
        switch kind {
        case .local: return "refs/heads/\(name)"
        case .remote: return "refs/remotes/\(name)"
        }
    }
}

struct Worktree: Identifiable, Hashable {
    let path: String
    let branch: String?
    let head: String

    var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }
}

enum ChangeArea {
    case staged
    case unstaged
}

struct FileChange: Identifiable, Hashable {
    let path: String
    let status: Character // M A D R C U ? etc.
    let area: ChangeArea

    var id: String { path + String(status) + (area == .staged ? "+s" : "+u") }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// A multi-step git operation that is paused mid-flight (usually on conflicts).
enum OngoingOperation: String {
    case merge = "Merge"
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case revert = "Revert"

    var continueArgs: [String] {
        switch self {
        case .merge: return ["merge", "--continue"]
        case .rebase: return ["rebase", "--continue"]
        case .cherryPick: return ["cherry-pick", "--continue"]
        case .revert: return ["revert", "--continue"]
        }
    }

    var abortArgs: [String] {
        switch self {
        case .merge: return ["merge", "--abort"]
        case .rebase: return ["rebase", "--abort"]
        case .cherryPick: return ["cherry-pick", "--abort"]
        case .revert: return ["revert", "--abort"]
        }
    }
}

struct Stash: Identifiable, Hashable {
    let ref: String      // "stash@{0}"
    let date: Date
    let message: String  // "WIP on main: abc123 subject" or custom -m text

    var id: String { ref }
}

struct Submodule: Identifiable, Hashable {
    let path: String
    let sha: String
    /// From `git submodule status`: " " in sync, "+" checked-out commit
    /// differs, "-" not initialized, "U" merge conflicts.
    let state: Character

    var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    var stateDescription: String {
        switch state {
        case "+": return "Checked-out commit differs from index"
        case "-": return "Not initialized"
        case "U": return "Has merge conflicts"
        default: return "In sync"
        }
    }
}

struct RepoSnapshot {
    var commits: [Commit] = []
    var graphRows: [GraphRow] = []
    var localBranches: [Branch] = []
    var remoteBranches: [Branch] = []
    var worktrees: [Worktree] = []
    var submodules: [Submodule] = []
    var stashes: [Stash] = []
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var conflicted: [FileChange] = []
    var currentBranch: String?
    var operation: OngoingOperation?

    /// Remote names in stable order, e.g. ["origin", "upstream"].
    var remoteNames: [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for branch in remoteBranches {
            if case .remote(let name) = branch.kind, seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// The remote used when one must be picked without asking: origin
    /// if present, else the first remote (GitKraken's behaviour).
    var defaultRemote: String {
        remoteNames.contains("origin") ? "origin" : (remoteNames.first ?? "origin")
    }
}
