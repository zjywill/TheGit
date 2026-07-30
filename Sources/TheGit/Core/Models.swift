import Foundation

struct Commit: Identifiable, Hashable {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let refs: [String]
    let subject: String
    /// Author email — the avatar lookup key. Defaulted so the graph layout
    /// tests can keep building commits without one.
    var email: String = ""

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }

    /// Synthetic hash for the uncommitted-changes row in the graph.
    static let wipHash = "WIP"
    var isWip: Bool { hash == Self.wipHash }

    /// Stash rows are synthetic commits too: hash is the stash ref behind a
    /// prefix no real sha can collide with. Like WIP, they run through the
    /// regular lane algorithm, which is what routes their dashed line into
    /// the base commit wherever it sits.
    static let stashHashPrefix = "STASH:"
    var isStash: Bool { hash.hasPrefix(Self.stashHashPrefix) }
    /// "stash@{0}" for a stash row, nil for real commits.
    var stashRef: String? {
        isStash ? String(hash.dropFirst(Self.stashHashPrefix.count)) : nil
    }
}

enum BranchKind: Hashable {
    case local
    case remote(String) // remote name, e.g. "origin"
}

struct Branch: Identifiable, Hashable {
    let name: String      // e.g. "main" or "origin/main"
    let kind: BranchKind
    let isCurrent: Bool
    /// Commit the branch points at (for locating it in the graph).
    var tipHash: String = ""
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
    /// The repo's own working directory. git refuses to remove it — "is a
    /// main working tree" — so nothing may offer to.
    var isMain = false
    /// git can't find the working directory any more. Only the admin files
    /// in .git/worktrees are left, so pruning it loses nothing.
    var prunable = false
    var locked = false

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

struct Tag: Identifiable, Hashable {
    let name: String
    let hash: String
    var id: String { name }
}

struct Stash: Identifiable, Hashable {
    let ref: String      // "stash@{0}"
    let date: Date
    let message: String  // "WIP on main: abc123 subject" or custom -m text
    /// The commit the stash was taken on (first parent of the stash
    /// commit) — anchors the stash node in the graph.
    var baseHash: String = ""

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

/// The commits-per-day histogram behind the activity heatmap.
///
/// Days are integer keys — 2026-07-28 is 20260728 — rather than dates or
/// "yyyy-MM-dd" strings, because both ends of this deal in whole days and
/// nothing else: git prints them, the grid looks them up once per cell, and
/// neither side should be building or parsing a date to do it.
enum ActivityDay {
    static func key(year: Int, month: Int, day: Int) -> Int {
        year * 10_000 + month * 100 + day
    }

    /// How far back the histogram is read: one week wider than the widest
    /// grid ActivityGraph will draw, so that dragging the splitter reveals
    /// real weeks instead of a false quiet spell, without waiting for a
    /// refresh. The cost is the window rather than the history — measured
    /// on a 12k-commit repo, half a year is 100ms against 80ms for a
    /// quarter, concurrent with the eight other reads a refresh makes.
    static let windowWeeks = 27
}

struct RepoSnapshot: Equatable {
    var commits: [Commit] = []
    /// Commits per day over the last `ActivityDay.windowWeeks`, all refs.
    var activity: [Int: Int] = [:]
    var graphRows: [GraphRow] = []
    var localBranches: [Branch] = []
    var remoteBranches: [Branch] = []
    var worktrees: [Worktree] = []
    var submodules: [Submodule] = []
    var lfs = LFSStatus()
    var stashes: [Stash] = []
    var tags: [Tag] = []
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var conflicted: [FileChange] = []
    var currentBranch: String?
    var operation: OngoingOperation?
    /// Contents of .git/MERGE_MSG while a merge is paused: git's own
    /// prepared message — "Merge branch 'main' into X" plus a
    /// "# Conflicts:" comment block.
    var mergeMessage: String?
    /// Commits reachable from HEAD within the loaded window — the current
    /// branch's history, used to spotlight it in the graph.
    var reachableFromHead: Set<String> = []
    /// Branch-line color ids that belong to HEAD's history: lines keep
    /// full brightness along their whole run, others dim entirely.
    var brightColors: Set<Int> = []

    /// The commit HEAD points at, within the loaded window. Read off the
    /// ref list rather than tracked separately, so it can never disagree
    /// with what the graph draws.
    var headHash: String? {
        commits.first { c in c.refs.contains { $0.hasPrefix("HEAD") } }?.hash
    }

    /// The checked-out local branch, when HEAD isn't detached.
    var headBranch: Branch? { localBranches.first(where: \.isCurrent) }

    /// First line of the prepared merge message — names both branches
    /// ("Merge branch 'main' into X"), which "Merge in progress" doesn't.
    var operationHeadline: String? {
        mergeMessage?.split(separator: "\n").first.map(String.init)
    }

    /// The prepared merge message without its comment block. `commit -m`
    /// records '#' lines verbatim (cleanup mode "whitespace", not the
    /// editor's "strip"), so they must never reach the message box.
    var mergeCommitDraft: String? {
        guard let mergeMessage else { return nil }
        let text = mergeMessage
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// LFS objects that genuinely have to be downloaded: pointer in the
    /// working tree, object nowhere on disk. A locally modified LFS file
    /// also reads as "not in the store" — verified against git-lfs 3.7 —
    /// but there is nothing to fetch for it, so it is filtered out here.
    var lfsMissing: [LFSFile] {
        guard !lfs.files.isEmpty else { return [] }
        let changed = Set((staged + unstaged + conflicted).map(\.path))
        return lfs.notInLocalStore.filter { !changed.contains($0.path) }
    }

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
