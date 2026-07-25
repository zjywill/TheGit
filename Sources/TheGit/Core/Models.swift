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

    var id: String { name }
    /// Branch name without the remote prefix, e.g. "origin/feature/x" -> "feature/x"
    var shortName: String {
        if case .remote(let remote) = kind, name.hasPrefix(remote + "/") {
            return String(name.dropFirst(remote.count + 1))
        }
        return name
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

struct RepoSnapshot {
    var commits: [Commit] = []
    var graphRows: [GraphRow] = []
    var localBranches: [Branch] = []
    var remoteBranches: [Branch] = []
    var worktrees: [Worktree] = []
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var currentBranch: String?
}
