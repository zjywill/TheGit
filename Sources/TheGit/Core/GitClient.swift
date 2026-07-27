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
        do {
            return try await Shell.run(
                "/usr/bin/env",
                ["git", "-C", repoPath] + args,
                // Never let git open an editor or prompt on the terminal —
                // continue/amend flows must complete non-interactively.
                env: [
                    "GIT_EDITOR": "true",
                    "GIT_PAGER": "cat",
                    "GIT_TERMINAL_PROMPT": "0",
                ],
                label: args.joined(separator: " ")
            )
        } catch let error as ShellError {
            throw GitError(command: error.command, message: error.message)
        }
    }

    // MARK: - Queries

    // hash, parents, author, email, unix-date, refs, subject — tab
    // separated, subject last (it's the only field that can contain tabs).
    private static let logFormat = "%H%x09%P%x09%an%x09%ae%x09%at%x09%D%x09%s"

    /// - solo: show only history reachable from this rev (GitKraken Solo).
    /// - hiddenPatterns: full ref paths to exclude (GitKraken Hide).
    func log(limit: Int = 500, solo: String? = nil, hiddenPatterns: [String] = []) async throws -> [Commit] {
        // --date-order interleaves parallel branches chronologically
        // (GitKraken-style) while still keeping children before parents.
        var args = ["log", "--date-order"]
        if let solo {
            args += [solo, "HEAD"]
        } else {
            for pattern in hiddenPatterns { args.append("--exclude=\(pattern)") }
            args += ["--branches", "--remotes", "--tags", "HEAD"]
        }
        args += ["--format=\(Self.logFormat)", "-n", String(limit)]
        let out = try await run(args)
        return GitParsers.parseLog(out)
    }

    /// Commits that touched one file, following renames.
    func fileHistory(_ path: String, limit: Int = 200) async throws -> [Commit] {
        let out = try await run([
            "log", "--follow", "--format=\(Self.logFormat)", "-n", String(limit), "--", path,
        ])
        return GitParsers.parseLog(out)
    }

    /// Apply a patch to the index only (hunk-level stage/unstage).
    func applyPatch(_ patch: String, reverse: Bool) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thegit-hunk-\(UUID().uuidString).patch")
        try patch.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["apply", "--cached"]
        if reverse { args.append("--reverse") }
        args.append(tmp.path)
        try await run(args)
    }

    func branches() async throws -> (local: [Branch], remote: [Branch]) {
        let out = try await run([
            "for-each-ref",
            "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track)%09%(objectname)",
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

    func unsetUpstream(_ branch: String) async throws {
        try await run(["branch", "--unset-upstream", branch])
    }

    func setRemoteURL(_ remote: String, url: String) async throws {
        try await run(["remote", "set-url", remote, url])
    }

    /// Restores a stash onto a fresh branch off the commit it was made on —
    /// the clean way out of "I stashed this on the wrong branch". Succeeds
    /// only if it applies cleanly, and drops the stash when it does.
    func stashBranch(_ name: String, from ref: String) async throws {
        try await run(["stash", "branch", name, ref])
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

    func tags() async throws -> [Tag] {
        let out = try await run([
            "for-each-ref", "--sort=-creatordate",
            // %(*objectname) dereferences annotated tags to their commit.
            "--format=%(refname:short)%09%(objectname)%09%(*objectname)",
            "refs/tags",
        ])
        return out.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let commit = fields.count > 2 && !fields[2].isEmpty ? fields[2] : fields[1]
            return Tag(name: String(fields[0]), hash: String(commit))
        }
    }

    func deleteTag(_ name: String) async throws {
        try await run(["tag", "-d", name])
    }

    func pushTag(_ name: String, remote: String) async throws {
        try await run(["push", remote, "tag", name])
    }

    func fetchRemote(_ name: String) async throws {
        try await run(["fetch", "--prune", name])
    }

    func removeWorktree(_ path: String) async throws {
        try await run(["worktree", "remove", "--force", path])
    }

    // MARK: - Cleanup

    /// The repo's mainline: whatever `<remote>/HEAD` points at, falling
    /// back to a local main/master.
    func defaultBranch(remote: String) async -> String {
        if let out = try? await run(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"]) {
            let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(remote + "/") { return String(name.dropFirst(remote.count + 1)) }
        }
        for candidate in ["main", "master"] {
            if (try? await run(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"])) != nil {
                return candidate
            }
        }
        return "main"
    }

    /// Local branches whose tip is an ancestor of `base` — plain merges
    /// and fast-forwards only. Squash merges are invisible here.
    func mergedBranches(into base: String) async throws -> Set<String> {
        let out = try await run(["branch", "--merged", base, "--format=%(refname:short)"])
        return Set(out.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespaces)
        })
    }

    /// True when `base` already contains this branch's work as a single
    /// squashed commit — the state a merged-and-deleted PR leaves behind.
    ///
    /// Neither `branch --merged` nor `git cherry` sees it, because a squash
    /// shares no commit with the branch. So we build the commit a squash
    /// *would* have produced (the branch's tree, parented on the merge
    /// base) and ask git whether an equivalent patch is already upstream.
    /// A branch that got new commits after its squash still reads as
    /// unmerged, which is what we want.
    /// Deliberately `nonisolated`: this is four git calls per branch and it
    /// mutates nothing the app reads, so it must not queue behind the
    /// actor's write lock. Serialised, a 150-branch repo took 16 seconds;
    /// the caller runs these concurrently instead.
    ///
    /// (`commit-tree` does write a loose object, but it's dangling and
    /// content-addressed — concurrent writes are safe, and gc reclaims it.)
    nonisolated static func isSquashMerged(
        repoPath: String, branch: String, into base: String
    ) async -> Bool {
        func git(_ args: [String]) async -> String? {
            try? await Shell.run(
                "/usr/bin/env",
                ["git", "-C", repoPath] + args,
                env: ["GIT_EDITOR": "true", "GIT_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0"]
            )
        }
        func trimmed(_ args: [String]) async -> String? {
            let out = await git(args)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (out?.isEmpty ?? true) ? nil : out
        }
        guard let mergeBase = await trimmed(["merge-base", base, branch]),
              let tree = await trimmed(["rev-parse", "\(branch)^{tree}"]),
              let synthetic = await trimmed(
                  ["commit-tree", tree, "-p", mergeBase, "-m", "squash-probe"]
              ),
              let verdict = await git(["cherry", base, synthetic])
        else { return false }
        // "- <sha>" = an equivalent patch is already in base, "+" = not.
        return verdict.hasPrefix("-")
    }

    func isSquashMerged(branch: String, into base: String) async -> Bool {
        await Self.isSquashMerged(repoPath: repoPath, branch: branch, into: base)
    }

    func countCommits(_ range: String) async throws -> Int {
        let out = try await run(["rev-list", "--count", range])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Drops admin files for worktrees whose directory is gone. Nothing on
    /// disk is deleted — and it always prunes every stale entry at once,
    /// git offers no way to prune just one.
    func pruneWorktrees() async throws {
        try await run(["worktree", "prune"])
    }

    /// Deliberately without `--force`: git refuses when the worktree has
    /// uncommitted changes, which is exactly the safety net we want here.
    func removeWorktreeIfClean(_ path: String) async throws {
        try await run(["worktree", "remove", path])
    }

    /// Full commit message (subject + body).
    func commitMessage(_ hash: String) async throws -> String {
        try await run(["show", "-s", "--format=%B", hash])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discard every working-tree change: restore tracked, clean untracked.
    func discardAll() async throws {
        try await run(["reset", "-q", "HEAD"])
        try await run(["restore", "--", "."])
        try await run(["clean", "-fd"])
    }

    func push() async throws {
        try await run(["push"])
    }

    // MARK: - Multi-remote

    func push(remote: String, branch: String, setUpstream: Bool) async throws {
        var args = ["push"]
        if setUpstream { args.append("-u") }
        args += [remote, branch]
        try await run(args)
    }

    func pull(remote: String, branch: String, extraArgs: [String] = []) async throws {
        try await run(["pull"] + extraArgs + [remote, branch])
    }

    /// Advance a branch you are NOT on, without checking it out. git only
    /// updates the ref when it's a true fast-forward and refuses otherwise,
    /// so this can't silently discard local commits.
    func fastForward(remote: String, branch: String) async throws {
        try await run(["fetch", remote, "\(branch):\(branch)"])
    }

    /// The current branch can't be updated by refspec — its ref is checked
    /// out — so it fast-forwards through merge instead. `--ff-only` keeps
    /// the same guarantee: no merge commit, no surprise.
    func mergeFastForwardOnly(_ ref: String) async throws {
        try await run(["merge", "--ff-only", ref])
    }

    func renameRemote(_ old: String, to new: String) async throws {
        try await run(["remote", "rename", old, new])
    }
}
