import Foundation

struct Commit: Identifiable, Hashable, Codable {
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

/// One line's `git blame` record — which commit (and which author) last
/// touched a given line of a file, in the revision it was blamed against.
/// Keyed by final line number; lines a blame couldn't attribute (a
/// boundary commit, or uncommitted working-tree content) carry the
/// all-zeros uncommitted hash.
struct BlameLine: Equatable, Hashable {
    /// 1-based line number in the blamed file's final revision.
    let lineNumber: Int
    /// Full commit hash attributing this line. The all-zeros hash marks
    /// uncommitted working-tree content; boundary commits report a real
    /// hash but carry no author fields git could name.
    let commitHash: String
    let author: String
    let date: Date
    let summary: String

    /// The synthetic hash `git blame` uses for lines with no commit behind
    /// them yet — new working-tree lines that have never been committed.
    static let uncommittedHash = "0000000000000000000000000000000000000000"
    var isUncommitted: Bool { commitHash == Self.uncommittedHash }

    /// A boundary commit has a real hash but nothing git can name for it —
    /// the blamed line fell off the beginning of history.
    var isBoundary: Bool { author.isEmpty }
    var shortHash: String { String(commitHash.prefix(7)) }

    var id: Int { lineNumber }
}

enum BranchKind: Hashable, Codable {
    case local
    case remote(String) // remote name, e.g. "origin"
}

struct Branch: Identifiable, Hashable, Codable {
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

struct Worktree: Identifiable, Hashable, Codable {
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

enum ChangeArea: String, Codable {
    case staged
    case unstaged
}

struct FileChange: Identifiable, Hashable, Codable {
    let path: String
    let status: Character // M A D R C U ? etc.
    let area: ChangeArea
    /// The source path for a rename or copy.
    var oldPath: String? = nil

    var id: String { path + String(status) + (area == .staged ? "+s" : "+u") }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    // `status` is a Character — git's own one-letter code — which JSON has
    // no notion of. Bridged through a String rather than changed here: the
    // whole app switches on that Character, and widening it to String for
    // the sake of the cache would touch every one of those sites.
    enum CodingKeys: String, CodingKey { case path, status, area, oldPath }

    init(path: String, status: Character, area: ChangeArea, oldPath: String? = nil) {
        self.path = path
        self.status = status
        self.area = area
        self.oldPath = oldPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decode(String.self, forKey: .status).first ?? " "
        area = try c.decode(ChangeArea.self, forKey: .area)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(String(status), forKey: .status)
        try c.encode(area, forKey: .area)
        try c.encodeIfPresent(oldPath, forKey: .oldPath)
    }
}

/// One file in a review's diff: a whole branch's worth of change to it,
/// not one commit's. Separate from `FileChange` because a review needs what
/// a working-tree row doesn't — the line counts, and the path the file used
/// to have, without which a renamed file's diff can't be asked for.
struct ReviewFile: Identifiable, Hashable {
    let path: String
    /// The pre-rename path, when git detected a rename or copy.
    var oldPath: String? = nil
    /// git's own letter: A M D R C T.
    let status: Character
    var additions = 0
    var deletions = 0
    /// git reports "-" for both counts of a binary file — no line counts to
    /// show, and nothing a diff view can render either.
    var isBinary = false

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    /// What `git diff -- …` has to be given: a rename's diff lives under
    /// both names, and asking for only the new one shows an empty file.
    var diffPaths: [String] {
        if let oldPath, oldPath != path { return [oldPath, path] }
        return [path]
    }
}

/// A multi-step git operation that is paused mid-flight (usually on conflicts).
enum OngoingOperation: String, Codable {
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

struct Tag: Identifiable, Hashable, Codable {
    let name: String
    let hash: String
    var id: String { name }
}

struct Stash: Identifiable, Hashable, Codable {
    let ref: String      // "stash@{0}"
    let date: Date
    let message: String  // "WIP on main: abc123 subject" or custom -m text
    /// The commit the stash was taken on (first parent of the stash
    /// commit) — anchors the stash node in the graph.
    var baseHash: String = ""

    var id: String { ref }
}

struct Submodule: Identifiable, Hashable, Codable {
    let path: String
    let sha: String
    /// From `git submodule status`: " " in sync, "+" checked-out commit
    /// differs, "-" not initialized, "U" merge conflicts.
    let state: Character

    var id: String { path }

    /// Same Character-through-String bridge as `FileChange.status`.
    enum CodingKeys: String, CodingKey { case path, sha, state }

    init(path: String, sha: String, state: Character) {
        self.path = path
        self.sha = sha
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        sha = try c.decode(String.self, forKey: .sha)
        state = try c.decode(String.self, forKey: .state).first ?? " "
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(sha, forKey: .sha)
        try c.encode(String(state), forKey: .state)
    }
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

    /// The Dashboard's aggregate grid draws a year, and reads one week past
    /// it for the same reason `windowWeeks` does — the window's trailing
    /// edge is this week, so resizing the wall slides it, and a column the
    /// histogram doesn't cover would draw as a quiet week.
    ///
    /// Twice the sidebar's window is roughly twice its cost, and it's paid
    /// once per open repository, which is why the wall reads them one at a
    /// time rather than all at once.
    static let yearWeeks = 53
}

struct RepoSnapshot: Equatable, Codable {
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

    /// What the disk cache stores — everything git had to be asked for, and
    /// nothing that can be recomputed from it. The three omissions
    /// (`graphRows`, `reachableFromHead`, `brightColors`) are pure functions
    /// of `commits` plus the file lists, and together they are the bulk of a
    /// snapshot's bytes: a 500-commit graph is a row per commit, each with
    /// its own lane arrays. `RepoState.rehydrate` runs the same two
    /// functions `refresh()` does, so a restored snapshot draws identically
    /// to a read one — which also means the cache can never disagree with
    /// the layout code as it changes.
    enum CodingKeys: String, CodingKey {
        case commits, activity, localBranches, remoteBranches, worktrees
        case submodules, lfs, stashes, tags, staged, unstaged, conflicted
        case currentBranch, operation, mergeMessage
    }

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
