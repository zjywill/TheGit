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

    /// `timeout` is for the commands that go out to a remote — see
    /// `Shell.run`. Local ones leave it nil: a slow `git log` is still
    /// making progress, and killing it would only lose the work.
    @discardableResult
    func run(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
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
                    // A background `git status` opportunistically rewrites
                    // the index, holding index.lock just long enough for a
                    // user-triggered merge/stash to die on "File exists".
                    // Optional locks off skips that rewrite; commands whose
                    // locks are mandatory (commit, merge) are unaffected.
                    "GIT_OPTIONAL_LOCKS": "0",
                ],
                label: args.joined(separator: " "),
                timeout: timeout
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
    /// - extraRevs: additional start points — stash base commits, whose
    ///   history may be unreachable from any ref after a rebase, and would
    ///   otherwise have no row for the stash node to anchor to.
    func log(
        limit: Int = 500,
        solo: String? = nil,
        hiddenPatterns: [String] = [],
        extraRevs: [String] = []
    ) async throws -> [Commit] {
        // --date-order interleaves parallel branches chronologically
        // (GitKraken-style) while still keeping children before parents.
        var args = ["log", "--date-order"]
        // A freshly initialized repository has a symbolic HEAD but no
        // commit behind it yet. Passing that unborn HEAD as a revision makes
        // git log fail with "ambiguous argument 'HEAD'"; the named ref sets
        // are still valid and simply produce an empty history.
        let hasHead = (try? await run([
            "rev-parse", "--verify", "--quiet", "HEAD",
        ])) != nil
        if let solo {
            args.append(solo)
            if hasHead { args.append("HEAD") }
        } else {
            for pattern in hiddenPatterns { args.append("--exclude=\(pattern)") }
            args += ["--branches", "--remotes", "--tags"]
            if hasHead { args.append("HEAD") }
            args += extraRevs
        }
        args += ["--format=\(Self.logFormat)", "-n", String(limit)]
        let out = try await run(args)
        return GitParsers.parseLog(out)
    }

    /// Commits per day over the last `weeks` weeks, across every ref — the
    /// activity heatmap's histogram.
    ///
    /// `--since` is what keeps this cheap on a big repo: the walker stops
    /// descending a chain once it runs older than the cutoff, so the cost is
    /// the window rather than the history, and the output is one ten-byte
    /// line per commit in it. That's why the heatmap doesn't just count the
    /// log the graph already loaded — that log is the newest 500 commits,
    /// which in a busy repo can be less than a fortnight, and the days
    /// before it would draw as genuinely empty.
    ///
    /// Author date, not committer date: the cells are meant to say when the
    /// work was done, and a rebase rewrites the other one. `-local` renders
    /// it in this Mac's timezone, which is the timezone the grid is built in.
    func activity(weeks: Int = ActivityDay.windowWeeks) async throws -> [Int: Int] {
        let out = try await run([
            // Everything but the review refs: `--all` includes them, and a
            // fetched pull request is somebody else's work parked in this
            // repo — counting it would leave a permanent bump in the
            // heatmap for every request ever opened.
            "log", "--exclude=refs/thegit/*", "--all", "--since=\(weeks) weeks ago",
            "--date=short-local", "--pretty=%ad",
        ])
        var counts: [Int: Int] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "-")
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2])
            else { continue }
            counts[ActivityDay.key(year: year, month: month, day: day), default: 0] += 1
        }
        return counts
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

    /// The message git prepared for a paused merge (.git/MERGE_MSG),
    /// worktree-safe via --git-path; nil when no merge is in flight.
    func mergeMessage() async throws -> String? {
        let rel = try await run(["rev-parse", "--git-path", "MERGE_MSG"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rel.hasPrefix("/") ? rel : repoPath + "/" + rel
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
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

    /// The change a commit would record, for the AI message generator:
    /// the index against HEAD, or against HEAD's parent when amending.
    /// `--no-ext-diff` matters — a user's difftool would hand back
    /// something that isn't a unified diff at all.
    func stagedDiff(amend: Bool, stat: Bool) async throws -> String {
        var args = ["diff", "--cached", "--no-color", "--no-ext-diff"]
        args += stat ? ["--stat=200"] : ["-U3"]
        // A root commit has no HEAD~1; amending one still diffs the index
        // against HEAD, which is empty for it anyway.
        if amend, (try? await run(["rev-parse", "--verify", "HEAD~1"])) != nil {
            args.append("HEAD~1")
        }
        return try await run(args)
    }

    /// Recent messages, as a style sample for the generator. Merges are
    /// skipped: "Merge pull request #18" teaches a model nothing.
    func recentCommitMessages(limit: Int = 8) async throws -> [String] {
        let output = try await run([
            "log", "-n", String(limit), "--no-merges", "--format=%B%x00",
        ])
        return output
            .components(separatedBy: "\0")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Full messages of the commits a pull request would carry, newest
    /// first — `range` is `target..source`. Merges are skipped for the same
    /// reason as in `recentCommitMessages`.
    func commitMessages(in range: String, limit: Int = 30) async throws -> [String] {
        let output = try await run([
            "log", "-n", String(limit), "--no-merges", "--format=%B%x00", range,
        ])
        return output
            .components(separatedBy: "\0")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The branch's combined change for the AI description: `range` is
    /// `target...source` — three dots, so commits that landed on target
    /// meanwhile don't show up as this branch's work.
    func rangeDiff(_ range: String, stat: Bool) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        args += stat ? ["--stat=200"] : ["-U3"]
        args.append(range)
        return try await run(args)
    }

    // MARK: - Review diff

    /// Long enough for a big request over a slow link, short enough that a
    /// remote which accepts the connection and then goes quiet doesn't hold
    /// this repo's git — every other command queues behind it — until the
    /// app quits.
    private static let reviewFetchTimeout: TimeInterval = 120

    /// Where a fetched pull/merge request head is parked locally. Under
    /// `refs/thegit/` on purpose: the graph walks `--branches --remotes
    /// --tags`, so a review ref adds no rows and draws no badges, and it
    /// survives relaunches — reopening a review needs no network.
    nonisolated static func reviewRef(number: Int, forge: Forge) -> String {
        "refs/thegit/\(forge == .github ? "pr" : "mr")/\(number)"
    }

    /// The forge's own read-only ref for a pull/merge request, which exists
    /// whatever repo the branch lives in — a fork's head included, where the
    /// branch itself is on a remote we've never heard of.
    private nonisolated static func remoteReviewRef(number: Int, forge: Forge) -> String {
        forge == .github
            ? "refs/pull/\(number)/head"
            : "refs/merge-requests/\(number)/head"
    }

    /// Fetch what a review needs to be diffed locally: the request's head,
    /// and the branch it targets. Returns the two revs to diff between.
    ///
    /// The head fetch is the one that must work — without it there is
    /// nothing to review. The base fetch is best-effort: a base ref we
    /// can't update still has whatever `origin/main` we had, and a stale
    /// merge base makes a slightly wider diff, not a wrong one.
    func fetchReviewRefs(
        number: Int, base: String, remote: String, forge: Forge
    ) async throws -> (base: String, head: String) {
        let head = Self.reviewRef(number: number, forge: forge)
        try await run([
            "fetch", "--force", remote,
            "+\(Self.remoteReviewRef(number: number, forge: forge)):\(head)",
        ], timeout: Self.reviewFetchTimeout)
        // Cancelled between the two fetches — the panel is gone, or on
        // another request. `try?` below would swallow that and carry on
        // running git for a review nobody is reading.
        try Task.checkCancellation()
        if !base.isEmpty {
            _ = try? await run([
                "fetch", "--force", remote,
                "+refs/heads/\(base):refs/remotes/\(remote)/\(base)",
            ], timeout: Self.reviewFetchTimeout)
            try Task.checkCancellation()
        }
        return (await resolvedBase(base, remote: remote), head)
    }

    /// The rev to diff the review against: the remote's copy of the target
    /// branch by preference — it is what the forge merges into — then a
    /// local branch of that name, then the remote's default branch.
    private func resolvedBase(_ base: String, remote: String) async -> String {
        for candidate in ["refs/remotes/\(remote)/\(base)", "refs/heads/\(base)"]
        where !base.isEmpty {
            if (try? await run(["rev-parse", "--verify", "--quiet", candidate])) != nil {
                return candidate
            }
        }
        return "refs/remotes/\(remote)/\(await defaultBranch(remote: remote))"
    }

    /// Every file a review touches, with its line counts. `range` is
    /// `base...head` — three dots, so commits that landed on the base
    /// meanwhile don't show up as this request's work, exactly like the AI
    /// description's diff.
    func reviewFiles(range: String) async throws -> [ReviewFile] {
        let numstat = try await run([
            "diff", "--numstat", "--find-renames", "-z", "--no-ext-diff", range,
        ])
        let nameStatus = try await run([
            "diff", "--name-status", "--find-renames", "-z", "--no-ext-diff", range,
        ])
        return GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
    }

    /// One file's diff within a review.
    func reviewFileDiff(range: String, file: ReviewFile) async throws -> String {
        try await run(
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "-U3", range, "--"]
                + file.diffPaths
        )
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

    /// Take a path out of the index but leave it on disk — what git calls
    /// `rm --cached`, and what the UI calls "Stop tracking". `--force`
    /// covers the file that was staged and then edited again: its index
    /// content matches neither HEAD nor the working tree, and git would
    /// rather refuse than pick a side. Nothing is deleted either way.
    func untrack(_ path: String) async throws {
        try await run(["rm", "--cached", "--force", "--", path])
    }

    func commit(message: String) async throws {
        try await run(["commit", "-m", message])
    }

    /// `catchUp` advances the branch to its upstream when it is behind —
    /// see `fastForward(to:)`. Off by default so the checkouts that are a
    /// step inside a larger operation (drag-and-drop merge/rebase, tags,
    /// detached commits) keep landing exactly where they're told.
    func checkout(branch: String, catchUp: Bool = false) async throws {
        try await withAutoStash("checkout") {
            try await run(["checkout", branch])
            if catchUp { try await fastForward(to: "@{upstream}") }
        }
    }

    /// Checkout a remote branch as a new local tracking branch (or switch
    /// if a local with the same name exists). `--track <remote>/<branch>`
    /// is explicit, so it stays unambiguous with multiple remotes —
    /// DWIM `checkout <name>` errors when two remotes have the branch.
    ///
    /// The local branch is then caught up to the remote one: picking
    /// "Checkout origin/main" and landing on a local `main` from last week
    /// is the one thing the menu item doesn't say.
    func checkoutRemote(_ branch: Branch, localExists: Bool) async throws {
        guard case .remote = branch.kind else {
            try await checkout(branch: branch.name)
            return
        }
        try await withAutoStash("checkout") {
            if localExists {
                try await run(["checkout", branch.shortName])
                try await fastForward(to: branch.name)
            } else {
                try await run(["checkout", "--track", branch.name])
            }
        }
    }

    /// Move the checked-out branch up to `ref` when it is strictly behind
    /// it — HEAD an ancestor of the ref, so no local commit and no local
    /// state is at stake, and every object is already here from the last
    /// fetch. Anything else (diverged, ahead, no upstream, detached HEAD,
    /// unknown ref) leaves HEAD alone: that's a real pull's job, and it
    /// belongs to the Pull button.
    private func fastForward(to ref: String) async throws {
        // `merge-base --is-ancestor` exits non-zero both when HEAD isn't an
        // ancestor and when the ref doesn't resolve — nothing to do either way.
        guard (try? await run(["merge-base", "--is-ancestor", "HEAD", ref])) != nil else { return }
        let head = try await run(["rev-parse", "HEAD"])
        let target = try await run(["rev-parse", ref])
        guard head != target else { return }
        try await run(["merge", "--ff-only", ref])
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

    /// Clones the repo into `path` and records it in `.gitmodules`. Both
    /// are left staged, the way git leaves them.
    func addSubmodule(url: String, path: String) async throws {
        try await run(["submodule", "add", "--", url, path])
    }

    /// `deinit` unregisters it and empties the working copy; `git rm` drops
    /// the gitlink and its `.gitmodules` section (staged, not committed).
    ///
    /// The submodule's own clone under `.git/modules` is what `purgeGitDir`
    /// decides about. git keeps it deliberately — it holds anything
    /// committed inside the submodule but never pushed — but while it is
    /// there, adding a submodule at the same path again fails with
    /// "a git directory is found locally", with no way out from the GUI.
    func removeSubmodule(_ path: String, purgeGitDir: Bool = false) async throws {
        // Resolve the clone before deinit empties the working copy.
        var moduleDir: String?
        if purgeGitDir {
            moduleDir = (try? await run(["-C", path, "rev-parse", "--absolute-git-dir"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await run(["submodule", "deinit", "-f", "--", path])
        try await run(["rm", "-f", "--", path])
        try await dropEmptyGitmodules()
        guard purgeGitDir else { return }
        // Both sides go through resolvingSymlinksInPath: git answers with
        // the real path, and a repo under /var or /tmp on macOS is a
        // symlink into /private, so the guard below would never match.
        let modulesRoot = resolved(absolute(try await run(["rev-parse", "--git-common-dir"])) + "/modules")
        // An uninitialized submodule has no working copy to ask, but a
        // clone left by an earlier `deinit` can still be sitting there.
        // git names it after the path unless it was added with --name,
        // which we never do.
        let dir = resolved(moduleDir ?? (modulesRoot + "/" + path))
        // Never delete outside .git/modules, whatever git handed back.
        guard dir.hasPrefix(modulesRoot + "/") else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A `.gitmodules` with no sections left is pure noise — but deleting
    /// it is only safe while HEAD has no copy of it: with one in HEAD and
    /// none in the working tree, git refuses every later `submodule add`
    /// until the removal is committed.
    private func dropEmptyGitmodules() async throws {
        let file = repoPath + "/.gitmodules"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              !text.contains("[submodule"),
              (try? await run(["cat-file", "-e", "HEAD:.gitmodules"])) == nil
        else { return }
        try await run(["rm", "-f", "--ignore-unmatch", "--", ".gitmodules"])
        // Never staged in the first place, so git rm matched nothing. Only
        // ours to delete when git left it truly empty — a hand-written file
        // with comments in it stays.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    /// git reports paths relative to the repo root unless they escape it.
    private func absolute(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") ? trimmed : repoPath + "/" + trimmed
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Git LFS

    /// Whether the `git-lfs` binary exists at all. Without it `git lfs` is
    /// not even a subcommand, and the whole feature stays hidden — the
    /// same stance ForgeClient takes on `gh`/`glab`.
    static let hasLFS = Shell.which("git-lfs") != nil

    /// `ls-files` walks the whole index — 180 ms on a 2000-file LFS repo
    /// against 10 ms for `git status` — and the file watcher fires a
    /// refresh every time a file is saved. A short time-to-live collapses
    /// each of those bursts into one call.
    ///
    /// Deliberately not keyed on the index or `.gitattributes` mtime:
    /// editing a tracked file flips its `*` to `-` and `git lfs pull`
    /// fills the object store, and neither writes the index — a cache
    /// keyed that way went stale exactly when the user was watching.
    private var lfsCache: (at: Date, status: LFSStatus)?
    private static let lfsCacheTTL: TimeInterval = 2

    /// What LFS looks like in this repo. Cheap when it isn't an LFS repo:
    /// no `.gitattributes`, no process spawned.
    func lfsStatus() async -> LFSStatus {
        guard Self.hasLFS,
              let attributes = try? String(
                  contentsOfFile: repoPath + "/.gitattributes", encoding: .utf8
              )
        else { return LFSStatus() }
        let patterns = LFSParsers.trackedPatterns(gitattributes: attributes)
        guard !patterns.isEmpty else { return LFSStatus() }
        if let cache = lfsCache, Date().timeIntervalSince(cache.at) < Self.lfsCacheTTL {
            // Patterns come from a file we just read, so they are never stale.
            return LFSStatus(patterns: patterns, files: cache.status.files)
        }
        let files = (try? await run(["lfs", "ls-files"])).map(LFSParsers.lsFiles) ?? []
        let status = LFSStatus(patterns: patterns, files: files)
        lfsCache = (Date(), status)
        return status
    }

    /// Route a pattern through LFS. `lfs install --local` first: it writes
    /// the clean/smudge filters into this repo's config, without which
    /// `.gitattributes` says lfs and git still commits the whole file.
    /// It only ever touches `.git/config` — never the user's global one.
    func lfsTrack(_ pattern: String) async throws {
        try await run(["lfs", "install", "--local"])
        try await run(["lfs", "track", "--", pattern])
        try await run(["add", "--", ".gitattributes"])
        lfsCache = nil
    }

    /// Re-run the filters over a file already in the index, turning a file
    /// that was committed whole into a pointer. Without it, tracking an
    /// existing file changes nothing until the file is edited again.
    func lfsRenormalize(_ path: String) async throws {
        try await run(["add", "--renormalize", "--", path])
        lfsCache = nil
    }

    /// Download the objects behind the pointers in the working tree.
    ///
    /// `lfs install --local` first, and it is not optional: in a repo
    /// without the filters configured — a fresh clone on a machine that
    /// never ran `git lfs install` — `git lfs pull` prints "Skipping
    /// object checkout", exits 0, and leaves every file a pointer. A
    /// button that silently does nothing is worse than no button.
    func lfsPull() async throws {
        try await run(["lfs", "install", "--local"])
        try await run(["lfs", "pull"])
        lfsCache = nil
    }

    // MARK: - Ignore files

    /// Absolute path of `.git/info/exclude`. Resolved through git because
    /// `.git` is a file, not a directory, in worktrees and submodules.
    func excludeFilePath() async throws -> String {
        absolute(try await run(["rev-parse", "--git-path", "info/exclude"]))
    }

    /// An explicit merge (menu or drag-drop) always records a merge commit.
    /// Without --no-ff, merging a branch that is strictly ahead just slides
    /// the current ref forward — no "Merge branch 'x' into y" in history,
    /// indistinguishable from a reset. Fast-forward updates go through
    /// `mergeFastForwardOnly`, which wants the opposite guarantee.
    func merge(_ branch: String) async throws {
        try await withAutoStash("merge") { try await run(["merge", "--no-ff", "--no-edit", branch]) }
    }

    func rebase(onto branch: String) async throws {
        try await withAutoStash("rebase") { try await run(["rebase", branch]) }
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
        try await withAutoStash("cherry-pick") { try await run(["cherry-pick", hash]) }
    }

    func revert(_ hash: String) async throws {
        try await withAutoStash("revert") { try await run(["revert", "--no-edit", hash]) }
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

    /// Remote names, one per line. The snapshot knows them too, but only
    /// after a full refresh — this is for the Dashboard asking about a repo
    /// whose tab has never been opened.
    func remotes() async throws -> [String] {
        try await run(["remote"])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func remoteURL(_ remote: String = "origin") async throws -> String {
        try await run(["remote", "get-url", remote])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch() async throws {
        try await run(["fetch", "--all", "--prune"])
    }

    /// Substrings git prints when refusing to *start* an operation over
    /// uncommitted changes. Matched loosely because the wording varies per
    /// command: "cannot rebase: You have unstaged changes", "Your local
    /// changes to the following files would be overwritten by checkout",
    /// "Please commit your changes or stash them before you merge".
    private static let dirtyRefusalMarkers = [
        "commit your changes or stash them",
        "would be overwritten by",
        "you have unstaged changes",
        "index contains uncommitted changes",
    ]

    private func isDirtyRefusal(_ error: Error) -> Bool {
        guard let message = (error as? GitError)?.message.lowercased() else { return false }
        return Self.dirtyRefusalMarkers.contains { message.contains($0) }
    }

    /// GitKraken-style dirty-tree handling for checkout/merge/rebase/
    /// cherry-pick/revert: run the operation as-is, and only when git
    /// refuses it over uncommitted changes, stash them, retry, and pop
    /// the stash back. A clean tree — or a dirty one git is happy to
    /// carry along — never touches the stash. Same manual stash dance
    /// as `pull`, for the same reason: git's own --autostash hides
    /// conflicted changes back in the stash instead of leaving markers
    /// where the conflict UI shows them.
    private func withAutoStash(_ command: String, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            return
        } catch {
            guard isDirtyRefusal(error) else { throw error }
        }

        // `stash push` can exit 0 without creating a stash entry — the
        // refs/stash before/after comparison is the only reliable "did we
        // actually stash" signal; popping without it would eat a
        // pre-existing stash.
        let before = try? await run(["rev-parse", "--verify", "-q", "refs/stash"])
        try await run(["stash", "push", "-u", "-m", "Auto-stash before \(command)"])
        let after = try? await run(["rev-parse", "--verify", "-q", "refs/stash"])
        guard let after, after != before else {
            try await operation()
            return
        }

        do {
            try await operation()
        } catch {
            if ((try? await operationState()) ?? nil) != nil {
                // Stopped on conflicts mid-operation. Popping onto a
                // conflicted tree would tangle the WIP into the conflict,
                // so the stash stays put until the user resolves.
                let detail = (error as? GitError)?.message ?? error.localizedDescription
                throw GitError(
                    command: command,
                    message: detail
                        + "\n\nYour uncommitted changes are safe in the stash — pop it after resolving."
                )
            }
            // Failed without touching the tree: put it back as it was.
            try? await run(["stash", "pop"])
            throw error
        }

        do {
            try await run(["stash", "pop"])
        } catch {
            // A conflicted pop marks the files in the working tree and keeps
            // the stash entry — report it as an outcome, not a git failure.
            throw GitError(
                command: "stash pop",
                message: "The \(command) succeeded, but restoring your uncommitted changes hit conflicts — "
                    + "they're marked in the working tree, and the stash was kept as a backup."
            )
        }
    }

    /// GitKraken-style pull: a dirty working tree is auto-stashed first and
    /// the stash popped back afterwards. Deliberately not `pull --autostash`
    /// — when the final apply conflicts, git's autostash resets the tree and
    /// hides the changes back in the stash, whereas popping leaves the
    /// conflict markers in the working tree where the conflict UI shows them.
    func pull(extraArgs: [String] = [], remote: String? = nil, branch: String? = nil) async throws {
        var pullArgs = ["pull"] + extraArgs
        if let remote, let branch { pullArgs += [remote, branch] }

        let dirty = try await !run(["status", "--porcelain"])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard dirty else {
            try await run(pullArgs)
            return
        }

        // `stash push` can exit 0 without creating a stash entry. Comparing
        // refs/stash before and after is the only reliable "did we actually
        // stash" signal — popping without it would eat a pre-existing stash.
        let before = try? await run(["rev-parse", "--verify", "-q", "refs/stash"])
        try await run(["stash", "push", "-u", "-m", "Auto-stash before pull"])
        let after = try? await run(["rev-parse", "--verify", "-q", "refs/stash"])
        guard let after, after != before else {
            try await run(pullArgs)
            return
        }

        do {
            try await run(pullArgs)
        } catch {
            if ((try? await operationState()) ?? nil) != nil {
                // The pull stopped on merge/rebase conflicts. Popping onto a
                // conflicted tree would tangle the WIP into the conflict, so
                // the stash stays put until the user resolves and pops it.
                let detail = (error as? GitError)?.message ?? error.localizedDescription
                throw GitError(
                    command: "pull",
                    message: detail
                        + "\n\nYour uncommitted changes are safe in the stash — pop it after resolving."
                )
            }
            // The pull failed without touching the tree (offline, refused
            // fast-forward): put the working tree back exactly as it was.
            try? await run(["stash", "pop"])
            throw error
        }

        do {
            try await run(["stash", "pop"])
        } catch {
            // A conflicted pop marks the files in the working tree and keeps
            // the stash entry — report it as an outcome, not a git failure.
            throw GitError(
                command: "stash pop",
                message: "The pull succeeded, but restoring your uncommitted changes hit conflicts — "
                    + "they're marked in the working tree, and the stash was kept as a backup."
            )
        }
    }

    func stashPush(message: String? = nil, paths: [String] = []) async throws {
        var args = ["stash", "push", "-u"]
        if let message, !message.isEmpty { args += ["-m", message] }
        if !paths.isEmpty { args += ["--"] + paths }
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
        // %P: parents of the stash commit — the first is the commit the
        // stash was taken on, which anchors its node in the graph.
        let out = try await run(["stash", "list", "--format=%gd%x09%at%x09%P%x09%gs"])
        return out.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            return Stash(
                ref: String(fields[0]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0),
                message: String(fields[3]),
                baseHash: fields[2].split(separator: " ").first.map(String.init) ?? ""
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

    /// Remote-tracking refs already contained by `base`. Keep the full
    /// `origin/name` spelling so a same-named local branch cannot collide
    /// with it in the cleanup scan.
    func mergedRemoteBranches(remote: String, into base: String) async throws -> Set<String> {
        let out = try await run([
            "for-each-ref", "--merged=\(base)", "--format=%(refname:short)",
            "refs/remotes/\(remote)",
        ])
        return Set(out.split(separator: "\n").compactMap {
            let name = String($0).trimmingCharacters(in: .whitespaces)
            return name.hasSuffix("/HEAD") ? nil : name
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
                env: ["GIT_EDITOR": "true", "GIT_PAGER": "cat",
                      "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
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

    /// `force` is never guessed here: the scan counts what's uncommitted in
    /// the folder, the dialog says so, and only a yes to that reaches this
    /// with `force: true`. A clean folder still goes without it, so a change
    /// made since the scan hits git's own refusal rather than the disk.
    func removeWorktree(_ path: String, force: Bool) async throws {
        try await run(["worktree", "remove"] + (force ? ["--force"] : []) + [path])
    }

    /// Uncommitted and untracked entries in a worktree — run against that
    /// folder, not the repo we're browsing. Untracked directories stay
    /// collapsed: a `node_modules` counts once, and counting the 40k files
    /// inside it would cost more than the answer is worth.
    nonisolated static func dirtyEntryCount(at path: String) async -> Int {
        let out = try? await Shell.run(
            "/usr/bin/env",
            ["git", "-C", path, "status", "--porcelain"],
            env: ["GIT_EDITOR": "true", "GIT_PAGER": "cat",
                  "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        )
        guard let out else { return 0 }
        return out.components(separatedBy: "\n").filter { !$0.isEmpty }.count
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
        try await withAutoStash("merge") { try await run(["merge", "--ff-only", ref]) }
    }

    func renameRemote(_ old: String, to new: String) async throws {
        try await run(["remote", "rename", old, new])
    }
}
