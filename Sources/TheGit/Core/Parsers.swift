import Foundation

enum GitParsers {
    // MARK: - log

    static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count >= 6 else { return nil }
            let parents = fields[1].split(separator: " ").map(String.init)
            let timestamp = TimeInterval(fields[3]) ?? 0
            let refs = fields[4]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Commit(
                hash: String(fields[0]),
                parents: parents,
                author: String(fields[2]),
                date: Date(timeIntervalSince1970: timestamp),
                refs: refs,
                subject: String(fields[5])
            )
        }
    }

    // MARK: - branches

    static func parseBranches(_ output: String) -> (local: [Branch], remote: [Branch]) {
        var local: [Branch] = []
        var remote: [Branch] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let refname = fields.first.map(String.init) else { continue }
            let isCurrent = fields.count > 1 && fields[1] == "*"
            if refname.hasPrefix("refs/heads/") {
                let name = String(refname.dropFirst("refs/heads/".count))
                local.append(Branch(name: name, kind: .local, isCurrent: isCurrent))
            } else if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                guard !name.hasSuffix("/HEAD") else { continue }
                let remoteName = String(name.split(separator: "/").first ?? "")
                remote.append(Branch(name: name, kind: .remote(remoteName), isCurrent: false))
            }
        }
        return (local, remote)
    }

    // MARK: - worktrees

    static func parseWorktrees(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var head = ""
        var branch: String?

        func flush() {
            if let p = path {
                result.append(Worktree(path: p, branch: branch, head: head))
            }
            path = nil
            head = ""
            branch = nil
        }

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return result
    }

    // MARK: - status (porcelain v2)

    static func parseStatus(_ output: String) -> (staged: [FileChange], unstaged: [FileChange], branch: String?) {
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []
        var branch: String?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                branch = name == "(detached)" ? nil : name
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 XY sub mH mI mW hH hI path" / "2 ... path\torigPath"
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let xy = fields[1]
                var path = String(fields[8])
                if line.hasPrefix("2 "), let tab = path.firstIndex(of: "\t") {
                    path = String(path[..<tab]) // new path for renames
                }
                let x = xy.first ?? "."
                let y = xy.count > 1 ? Array(xy)[1] : "."
                if x != "." {
                    staged.append(FileChange(path: path, status: x, area: .staged))
                }
                if y != "." {
                    unstaged.append(FileChange(path: path, status: y, area: .unstaged))
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                unstaged.append(FileChange(path: path, status: "?", area: .unstaged))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count >= 11 else { continue }
                unstaged.append(FileChange(path: String(fields[10]), status: "U", area: .unstaged))
            }
        }
        return (staged, unstaged, branch)
    }
}
