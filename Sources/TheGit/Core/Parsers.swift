import Foundation

enum GitParsers {
    // MARK: - log

    static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            // hash, parents, author, email, date, refs, subject — the
            // subject is last and may itself contain tabs, hence maxSplits.
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }
            let parents = fields[1].split(separator: " ").map(String.init)
            let timestamp = TimeInterval(fields[4]) ?? 0
            let refs = fields[5]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Commit(
                hash: String(fields[0]),
                parents: parents,
                author: String(fields[2]),
                date: Date(timeIntervalSince1970: timestamp),
                refs: refs,
                subject: String(fields[6]),
                email: String(fields[3])
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
                var branch = Branch(name: name, kind: .local, isCurrent: isCurrent)
                if fields.count > 4 { branch.tipHash = String(fields[4]) }
                if fields.count > 2, !fields[2].isEmpty {
                    branch.upstream = String(fields[2])
                }
                if fields.count > 3 {
                    // "[ahead 2, behind 1]" / "[ahead 2]" / "[gone]" / ""
                    let track = fields[3]
                    branch.upstreamGone = track.contains("gone")
                    if let r = track.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                        branch.ahead = Int(track[r].dropFirst(6)) ?? 0
                    }
                    if let r = track.range(of: #"behind (\d+)"#, options: .regularExpression) {
                        branch.behind = Int(track[r].dropFirst(7)) ?? 0
                    }
                }
                local.append(branch)
            } else if refname.hasPrefix("refs/remotes/") {
                let name = String(refname.dropFirst("refs/remotes/".count))
                guard !name.hasSuffix("/HEAD") else { continue }
                let remoteName = String(name.split(separator: "/").first ?? "")
                var branch = Branch(name: name, kind: .remote(remoteName), isCurrent: false)
                if fields.count > 4 { branch.tipHash = String(fields[4]) }
                remote.append(branch)
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
        var prunable = false
        var locked = false

        func flush() {
            if let p = path {
                result.append(Worktree(
                    // git always lists the main worktree first, whichever
                    // one the command ran in — there is no porcelain flag
                    // for it, the position is the whole signal.
                    path: p, branch: branch, head: head,
                    isMain: result.isEmpty,
                    prunable: prunable, locked: locked
                ))
            }
            path = nil
            head = ""
            branch = nil
            prunable = false
            locked = false
        }

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                // Bare flag or "prunable <reason>", depending on git version.
                prunable = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            }
        }
        flush()
        return result
    }

    // MARK: - review diff (numstat + name-status)

    /// The file list of a whole-branch diff, out of `git diff -z` run twice:
    /// once for `--numstat` (the line counts) and once for `--name-status`
    /// (the letters). Two commands because git prints one or the other, and
    /// `-z` because a rename is two paths and a path may hold anything at
    /// all except a NUL.
    ///
    /// The record shapes, which the walkers below encode:
    /// - numstat: `"12\t3\tpath"` per record; a rename instead sends
    ///   `"12\t3\t"` and then the old and new paths as two records of their
    ///   own.
    /// - name-status: `"M"` then its path; `"R100"` then old and new.
    ///
    /// Order is the numstat order (git's own), and a file missing from
    /// either side still lands in the list — a counted file with no letter
    /// is shown as modified rather than dropped.
    static func reviewFiles(numstat: String, nameStatus: String) -> [ReviewFile] {
        var statuses: [String: (status: Character, oldPath: String?)] = [:]
        let nameFields = nulFields(nameStatus)
        var index = 0
        while index + 1 < nameFields.count {
            let code = nameFields[index]
            guard let letter = code.first else { index += 1; continue }
            // R and C carry a similarity score ("R100") and two paths.
            if letter == "R" || letter == "C", index + 2 < nameFields.count {
                statuses[nameFields[index + 2]] = (letter, nameFields[index + 1])
                index += 3
            } else {
                statuses[nameFields[index + 1]] = (letter, nil)
                index += 2
            }
        }

        var files: [ReviewFile] = []
        var seen = Set<String>()
        let numFields = nulFields(numstat)
        index = 0
        while index < numFields.count {
            let record = numFields[index]
            let parts = record.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { index += 1; continue }
            let adds = String(parts[0])
            let dels = String(parts[1])
            var path = String(parts[2])
            var oldPath: String?
            if path.isEmpty {
                // Rename or copy: the two paths follow as their own records.
                guard index + 2 < numFields.count else { break }
                oldPath = numFields[index + 1]
                path = numFields[index + 2]
                index += 3
            } else {
                index += 1
            }
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let known = statuses[path]
            files.append(ReviewFile(
                path: path,
                oldPath: oldPath ?? known?.oldPath,
                status: known?.status ?? "M",
                additions: Int(adds) ?? 0,
                deletions: Int(dels) ?? 0,
                // "-\t-" is git saying the file is binary.
                isBinary: adds == "-" || dels == "-"
            ))
        }

        // Files with no line counts at all — a pure mode change, or a
        // rename git counted under a path numstat spelled differently.
        for (path, entry) in statuses where !seen.contains(path) {
            files.append(ReviewFile(path: path, oldPath: entry.oldPath, status: entry.status))
        }
        return files
    }

    /// A `-z` stream's records: NUL-separated, with the trailing empty tail
    /// the final separator leaves behind dropped.
    private static func nulFields(_ output: String) -> [String] {
        var fields = output.components(separatedBy: "\0")
        while fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }

    // MARK: - status (porcelain v2)

    struct StatusResult {
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []
        var conflicted: [FileChange] = []
        var branch: String?
        /// HEAD's sha — the only name a detached HEAD has.
        var head: String?
        /// Commits ahead of / behind the upstream. Both stay zero with no
        /// upstream configured, which is indistinguishable from being level
        /// with one; the caller that cares looks at `upstream`.
        var ahead = 0
        var behind = 0
        var upstream: String?
    }

    static func parseStatus(_ output: String) -> StatusResult {
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []
        var conflicted: [FileChange] = []
        var branch: String?
        var head: String?
        var ahead = 0
        var behind = 0
        var upstream: String?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                branch = name == "(detached)" ? nil : name
            } else if line.hasPrefix("# branch.oid ") {
                let oid = String(line.dropFirst("# branch.oid ".count))
                head = oid == "(initial)" ? nil : oid
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // "# branch.ab +2 -1"
                for field in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    let value = Int(field.dropFirst()) ?? 0
                    if field.hasPrefix("+") { ahead = value }
                    if field.hasPrefix("-") { behind = value }
                }
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
                conflicted.append(FileChange(path: String(fields[10]), status: "U", area: .unstaged))
            }
        }
        return StatusResult(
            staged: staged,
            unstaged: unstaged,
            conflicted: conflicted,
            branch: branch,
            head: head,
            ahead: ahead,
            behind: behind,
            upstream: upstream
        )
    }
}
