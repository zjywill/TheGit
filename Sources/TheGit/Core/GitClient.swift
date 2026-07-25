import Foundation

struct GitError: LocalizedError {
    let command: String
    let message: String
    var errorDescription: String? { "git \(command): \(message)" }
}

/// Thin wrapper around the system `git` binary. All mutations go through here,
/// serialized by the actor so we never run two writing commands concurrently.
actor GitClient {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    @discardableResult
    func run(_ args: [String]) async throws -> String {
        let path = repoPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git", "-C", path] + args
                // Never let git open an editor or prompt on the terminal —
                // continue/amend flows must complete non-interactively.
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "GIT_EDITOR": "true",
                    "GIT_PAGER": "cat",
                    "GIT_TERMINAL_PROMPT": "0",
                ]) { _, new in new }
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: GitError(
                        command: args.joined(separator: " "),
                        message: err.isEmpty ? out : err
                    ))
                } else {
                    continuation.resume(returning: out)
                }
            }
        }
    }

    // MARK: - Queries

    func log(limit: Int = 500) async throws -> [Commit] {
        // hash, parents, author, unix-date, refs, subject — tab separated, subject last.
        let format = "%H%x09%P%x09%an%x09%at%x09%D%x09%s"
        let out = try await run([
            // --date-order interleaves parallel branches chronologically
            // (GitKraken-style) while still keeping children before parents.
            "log", "--date-order", "--branches", "--remotes", "--tags", "HEAD",
            "--format=\(format)", "-n", String(limit),
        ])
        return GitParsers.parseLog(out)
    }

    func branches() async throws -> (local: [Branch], remote: [Branch]) {
        let out = try await run([
            "for-each-ref",
            "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track)",
            "refs/heads", "refs/remotes",
        ])
        return GitParsers.parseBranches(out)
    }

    func worktrees() async throws -> [Worktree] {
        let out = try await run(["worktree", "list", "--porcelain"])
        return GitParsers.parseWorktrees(out)
    }

    func status() async throws -> GitParsers.StatusResult {
        let out = try await run(["status", "--porcelain=v2", "--branch"])
        return GitParsers.parseStatus(out)
    }

    /// Detect a paused merge/rebase/cherry-pick/revert by checking the
    /// state files inside the git dir (worktree-safe via --git-path).
    func operationState() async throws -> OngoingOperation? {
        let out = try await run([
            "rev-parse",
            "--git-path", "rebase-merge",
            "--git-path", "rebase-apply",
            "--git-path", "MERGE_HEAD",
            "--git-path", "CHERRY_PICK_HEAD",
            "--git-path", "REVERT_HEAD",
        ])
        let paths = out.split(separator: "\n").map(String.init)
        guard paths.count >= 5 else { return nil }
        let base = repoPath
        func exists(_ p: String) -> Bool {
            FileManager.default.fileExists(atPath: p.hasPrefix("/") ? p : base + "/" + p)
        }
        // Rebase first: a paused rebase can also leave CHERRY_PICK_HEAD around.
        if exists(paths[0]) || exists(paths[1]) { return .rebase }
        if exists(paths[2]) { return .merge }
        if exists(paths[3]) { return .cherryPick }
        if exists(paths[4]) { return .revert }
        return nil
    }

    /// Files touched by a commit, with their status letters.
    func commitFiles(_ hash: String) async throws -> [FileChange] {
        let out = try await run(["show", "--name-status", "--format=", hash])
        return out.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let status = fields[0].first else { return nil }
            // Renames/copies: "R100\told\tnew" — show the new path.
            return FileChange(path: String(fields.last!), status: status, area: .unstaged)
        }
    }

    /// One file's diff within a commit (works for root commits too).
    func commitFileDiff(_ hash: String, path: String) async throws -> String {
        try await run(["show", "--format=", hash, "--", path])
    }

    func diff(path: String, staged: Bool) async throws -> String {
        var args = ["diff"]
        if staged { args.append("--cached") }
        args += ["--", path]
        return try await run(args)
    }

    // MARK: - Conflict resolution

    /// Take one side of a conflicted file wholesale, then mark it resolved.
    func acceptSide(_ path: String, ours: Bool) async throws {
        try await run(["checkout", ours ? "--ours" : "--theirs", "--", path])
        try await run(["add", "--", path])
    }

    func continueOperation(_ op: OngoingOperation) async throws {
        try await run(op.continueArgs)
    }

    func abortOperation(_ op: OngoingOperation) async throws {
        try await run(op.abortArgs)
    }

    // MARK: - Mutations

    func stage(_ path: String) async throws {
        try await run(["add", "--", path])
    }

    func stageAll() async throws {
        try await run(["add", "-A"])
    }

    func unstage(_ path: String) async throws {
        try await run(["reset", "-q", "HEAD", "--", path])
    }

    func unstageAll() async throws {
        try await run(["reset", "-q", "HEAD"])
    }

    func commit(message: String) async throws {
        try await run(["commit", "-m", message])
    }

    func checkout(branch: String) async throws {
        try await run(["checkout", branch])
    }

    /// Checkout a remote branch as a new local tracking branch (or switch
    /// if a local with the same name exists). `--track <remote>/<branch>`
    /// is explicit, so it stays unambiguous with multiple remotes —
    /// DWIM `checkout <name>` errors when two remotes have the branch.
    func checkoutRemote(_ branch: Branch, localExists: Bool) async throws {
        guard case .remote = branch.kind else {
            try await checkout(branch: branch.name)
            return
        }
        if localExists {
            try await run(["checkout", branch.shortName])
        } else {
            try await run(["checkout", "--track", branch.name])
        }
    }

    // MARK: - Submodules

    func submodules() async throws -> [Submodule] {
        // Fast path: no .gitmodules, no submodules.
        guard FileManager.default.fileExists(atPath: repoPath + "/.gitmodules") else { return [] }
        let out = try await run(["submodule", "status"])
        // Format: "<flag><sha> <path> (<ref>)", flag ∈ {' ', '+', '-', 'U'}.
        return out.split(separator: "\n").compactMap { line in
            guard let flag = line.first else { return nil }
            let fields = line.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { return nil }
            return Submodule(path: String(fields[1]), sha: String(fields[0]), state: flag)
        }
    }

    func updateSubmodules() async throws {
        try await run(["submodule", "update", "--init", "--recursive"])
    }

    func merge(_ branch: String) async throws {
        try await run(["merge", "--no-edit", branch])
    }

    func rebase(onto branch: String) async throws {
        try await run(["rebase", branch])
    }

    func createBranch(_ name: String, at startPoint: String, checkout: Bool) async throws {
        if checkout {
            try await run(["checkout", "-b", name, startPoint])
        } else {
            try await run(["branch", name, startPoint])
        }
    }

    func renameBranch(_ old: String, to new: String) async throws {
        try await run(["branch", "-m", old, new])
    }

    func deleteLocalBranch(_ name: String) async throws {
        try await run(["branch", "-D", name])
    }

    func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await run(["push", remote, "--delete", branch])
    }

    func setUpstream(_ branch: String, to upstream: String) async throws {
        try await run(["branch", "--set-upstream-to=\(upstream)", branch])
    }

    func addWorktree(at path: String, branch: String) async throws {
        try await run(["worktree", "add", path, branch])
    }

    // MARK: - Commit operations

    func cherryPick(_ hash: String) async throws {
        try await run(["cherry-pick", hash])
    }

    func revert(_ hash: String) async throws {
        try await run(["revert", "--no-edit", hash])
    }

    enum ResetMode: String {
        case soft = "--soft"
        case mixed = "--mixed"
        case hard = "--hard"
    }

    func reset(to hash: String, mode: ResetMode) async throws {
        try await run(["reset", mode.rawValue, hash])
    }

    func tag(_ name: String, at hash: String) async throws {
        try await run(["tag", name, hash])
    }

    func amendMessage(_ message: String) async throws {
        try await run(["commit", "--amend", "-m", message])
    }

    func formatPatch(_ hash: String) async throws -> String {
        try await run(["format-patch", "-1", hash, "--stdout"])
    }

    func addRemote(name: String, url: String) async throws {
        try await run(["remote", "add", name, url])
    }

    func removeRemote(_ name: String) async throws {
        try await run(["remote", "remove", name])
    }

    func remoteURL(_ remote: String = "origin") async throws -> String {
        try await run(["remote", "get-url", remote])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch() async throws {
        try await run(["fetch", "--all", "--prune"])
    }

    func pull(extraArgs: [String] = []) async throws {
        try await run(["pull"] + extraArgs)
    }

    func stashPush(message: String? = nil) async throws {
        var args = ["stash", "push", "-u"]
        if let message, !message.isEmpty { args += ["-m", message] }
        try await run(args)
    }

    func commitAmend(message: String) async throws {
        try await run(["commit", "--amend", "-m", message])
    }

    func stashPop() async throws {
        try await run(["stash", "pop"])
    }

    func stashFile(_ path: String) async throws {
        try await run(["stash", "push", "-u", "--", path])
    }

    func stashes() async throws -> [Stash] {
        let out = try await run(["stash", "list", "--format=%gd%x09%at%x09%gs"])
        return out.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            return Stash(
                ref: String(fields[0]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0),
                message: String(fields[2])
            )
        }
    }

    func stashApply(_ ref: String) async throws {
        try await run(["stash", "apply", ref])
    }

    func stashPop(_ ref: String) async throws {
        try await run(["stash", "pop", ref])
    }

    func stashDrop(_ ref: String) async throws {
        try await run(["stash", "drop", ref])
    }

    func push() async throws {
        try await run(["push"])
    }
}
