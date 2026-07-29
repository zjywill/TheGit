import XCTest
@testable import TheGit

/// Drives GitClient/RepoState against a real repository in a temp dir.
/// These are the ignore + submodule paths from issue #17, checked against
/// git itself rather than against our idea of what git does.
@MainActor
final class RepoIntegrationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // git refuses to clone a submodule over the `file` transport
        // (CVE-2022-39253). GIT_CONFIG_* reaches every git process in the
        // tree, including the clone git spawns for the submodule. This is
        // the harness cloning from a temp dir — the app never sets it.
        setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "protocol.file.allow", 1)
        setenv("GIT_CONFIG_VALUE_0", "always", 1)
    }

    override func tearDownWithError() throws {
        for key in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] {
            unsetenv(key)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ dir: String, _ args: [String]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    /// A repo with one commit in it.
    private func makeRepo(_ name: String) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        try write("seed\n", to: path + "/seed.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "init"])
        return path
    }

    private func write(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// RepoState's actions are fire-and-forget Tasks, so wait for the
    /// effect rather than for the call.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Same, for state that only moves when something re-reads the repo.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 8,
        _ condition: () -> Bool,
        refreshing refresh: () async -> Void
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await refresh()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func untrackedPaths(_ repo: RepoState) -> [String] {
        repo.snapshot.unstaged.filter { $0.status == "?" }.map(\.path)
    }

    // MARK: - Ignore

    /// The whole menu action: write the pattern, and the file is gone from
    /// the untracked list on the next refresh.
    func testIgnoreFileWritesGitignoreAndHidesTheFile() async throws {
        let path = try await makeRepo("ignore-file")
        try write("noise\n", to: path + "/build.log")
        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(untrackedPaths(repo), ["build.log"])

        repo.ignore(pattern: GitIgnore.filePattern("build.log"))
        try await waitUntil("the .gitignore write") {
            FileManager.default.fileExists(atPath: path + "/.gitignore")
        }
        await repo.refresh()
        XCTAssertEqual(read(path + "/.gitignore"), "/build.log\n")
        // .gitignore itself is the only untracked file left.
        XCTAssertEqual(untrackedPaths(repo), [".gitignore"])
        XCTAssertNil(repo.errorMessage)
    }

    /// Ignoring the same thing twice must not add a second line.
    func testIgnoringTwiceLeavesOneLine() async throws {
        let path = try await makeRepo("ignore-twice")
        try write("x\n", to: path + "/a.log")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.ignore(pattern: GitIgnore.extensionPattern("log"))
        try await waitUntil("first write") { self.read(path + "/.gitignore") == "*.log\n" }
        repo.ignore(pattern: GitIgnore.extensionPattern("log"))
        // Give the second write a chance to land before asserting it didn't.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(read(path + "/.gitignore"), "*.log\n")
    }

    /// The escaping test that matters: a name full of glob characters must
    /// ignore exactly itself, and git has to agree. Unescaped,
    /// `notes[draft].md` is a character class that also swallows `notesd.md`.
    func testGlobCharactersInNameIgnoreOnlyThatFile() async throws {
        let path = try await makeRepo("ignore-glob")
        try write("x\n", to: path + "/notes[draft].md")
        try write("x\n", to: path + "/notesd.md")
        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(untrackedPaths(repo).sorted(), ["notes[draft].md", "notesd.md"])

        repo.ignore(pattern: GitIgnore.filePattern("notes[draft].md"))
        try await waitUntil("the .gitignore write") {
            FileManager.default.fileExists(atPath: path + "/.gitignore")
        }
        await repo.refresh()
        XCTAssertEqual(untrackedPaths(repo).sorted(), [".gitignore", "notesd.md"])
    }

    /// A whole untracked directory: git reports it as one entry with a
    /// trailing slash, and the directory pattern has to cover it.
    func testIgnoreDirectory() async throws {
        let path = try await makeRepo("ignore-dir")
        try FileManager.default.createDirectory(atPath: path + "/gen", withIntermediateDirectories: true)
        try write("x\n", to: path + "/gen/out.txt")
        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(untrackedPaths(repo), ["gen/"])

        repo.ignore(pattern: GitIgnore.directoryPattern("gen/"))
        try await waitUntil("the .gitignore write") {
            FileManager.default.fileExists(atPath: path + "/.gitignore")
        }
        await repo.refresh()
        XCTAssertEqual(read(path + "/.gitignore"), "/gen/\n")
        XCTAssertEqual(untrackedPaths(repo), [".gitignore"])
    }

    /// "Ignore for me only" writes .git/info/exclude — no .gitignore, so
    /// nothing to commit, and the file is still ignored.
    func testLocalIgnoreWritesExcludeAndLeavesNothingToCommit() async throws {
        let path = try await makeRepo("ignore-local")
        try write("x\n", to: path + "/scratch.txt")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.ignore(pattern: GitIgnore.filePattern("scratch.txt"), local: true)
        try await waitUntil("the exclude write") {
            self.read(path + "/.git/info/exclude").contains("/scratch.txt")
        }
        await repo.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/.gitignore"))
        XCTAssertTrue(untrackedPaths(repo).isEmpty)
        XCTAssertNil(repo.errorMessage)
    }

    /// The exclude path comes from git, so it is right even where `.git`
    /// is a file rather than a directory (worktrees, submodules).
    func testExcludeFilePathInAWorktree() async throws {
        let path = try await makeRepo("exclude-worktree")
        let worktree = root.appendingPathComponent("wt").path
        try await git(path, ["worktree", "add", "-q", "-b", "side", worktree])

        let resolved = try await GitClient(repoPath: worktree).excludeFilePath()
        XCTAssertTrue(resolved.hasPrefix("/"), resolved)
        // A worktree shares the main repo's info/exclude.
        XCTAssertEqual(
            URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: path + "/.git/info/exclude").resolvingSymlinksInPath().path
        )
    }

    // MARK: - Submodules

    /// Add → status parse → deinit state → remove, all through GitClient.
    func testAddParseAndRemoveSubmodule() async throws {
        let upstream = try await makeRepo("upstream")
        let superPath = try await makeRepo("super")
        let client = GitClient(repoPath: superPath)

        try await client.addSubmodule(url: upstream, path: "vendor/lib")
        var subs = try await client.submodules()
        XCTAssertEqual(subs.map(\.path), ["vendor/lib"])
        XCTAssertEqual(subs.first?.state, " ")
        XCTAssertEqual(subs.first?.displayName, "lib")
        XCTAssertTrue(read(superPath + "/.gitmodules").contains("vendor/lib"))
        // The gitlink and .gitmodules are staged, ready to commit.
        let repo = RepoState(path: superPath)
        await repo.refresh()
        XCTAssertEqual(repo.snapshot.staged.map(\.path).sorted(), [".gitmodules", "vendor/lib"])
        XCTAssertEqual(repo.snapshot.submodules.count, 1)

        try await git(superPath, ["commit", "-qm", "add submodule"])

        // An uninitialized submodule reads as "-" — the state the row
        // disables "Open as Tab" for.
        try await git(superPath, ["submodule", "deinit", "-f", "--", "vendor/lib"])
        subs = try await client.submodules()
        XCTAssertEqual(subs.first?.state, "-")
        XCTAssertEqual(subs.first?.stateDescription, "Not initialized")

        // ...and updating it puts it back in sync.
        try await client.updateSubmodules()
        subs = try await client.submodules()
        XCTAssertEqual(subs.first?.state, " ")

        try await client.removeSubmodule("vendor/lib")
        let afterRemoval = try await client.submodules()
        XCTAssertTrue(afterRemoval.isEmpty)
        XCTAssertFalse(read(superPath + "/.gitmodules").contains("vendor/lib"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: superPath + "/vendor/lib/.git"))
        await repo.refresh()
        XCTAssertTrue(repo.snapshot.submodules.isEmpty)
        // Removal is staged, not committed: the gitlink is a staged delete.
        XCTAssertTrue(repo.snapshot.staged.map(\.path).contains("vendor/lib"))
    }

    /// Added, then removed before committing: the repo has to end up
    /// exactly as it started — including no leftover empty `.gitmodules`
    /// staged for a commit the user never wanted to make.
    func testRemovingAnUncommittedSubmoduleLeavesNoTrace() async throws {
        let upstream = try await makeRepo("upstream-uncommitted")
        let superPath = try await makeRepo("super-uncommitted")
        let client = GitClient(repoPath: superPath)

        try await client.addSubmodule(url: upstream, path: "lib")
        try await client.removeSubmodule("lib", purgeGitDir: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: superPath + "/.gitmodules"))
        let status = try await git(superPath, ["status", "--porcelain"])
        XCTAssertEqual(status, "", "expected a clean tree, got: \(status)")
        // And the path is free again.
        try await client.addSubmodule(url: upstream, path: "lib")
        let subs = try await client.submodules()
        XCTAssertEqual(subs.map(\.path), ["lib"])
    }

    /// After a committed submodule is removed, `.gitmodules` stays (empty,
    /// staged): deleting it while HEAD still has one makes git refuse every
    /// later `submodule add` until the removal is committed.
    func testRemovingACommittedSubmoduleKeepsGitmodulesForLaterAdds() async throws {
        let upstream = try await makeRepo("upstream-committed")
        let superPath = try await makeRepo("super-committed")
        let client = GitClient(repoPath: superPath)

        try await client.addSubmodule(url: upstream, path: "lib")
        try await git(superPath, ["commit", "-qm", "add submodule"])
        try await client.removeSubmodule("lib", purgeGitDir: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: superPath + "/.gitmodules"))
        XCTAssertFalse(read(superPath + "/.gitmodules").contains("[submodule"))
        // The removal is not committed yet, and adding still works.
        try await client.addSubmodule(url: upstream, path: "other")
        let subs = try await client.submodules()
        XCTAssertEqual(subs.map(\.path), ["other"])
    }

    /// The clone under .git/modules is what decides whether the same path
    /// can be used again — the choice the removal dialog offers.
    func testPurgeControlsWhetherThePathCanBeReused() async throws {
        let upstream = try await makeRepo("upstream-purge")

        /// add → commit → remove, and hand back whether the clone survived
        /// and whether the same path can be used again.
        func removeThenReadd(purge: Bool, in name: String) async throws -> (kept: Bool, readded: Bool) {
            let superPath = try await makeRepo(name)
            let client = GitClient(repoPath: superPath)
            try await client.addSubmodule(url: upstream, path: "lib")
            try await git(superPath, ["commit", "-qm", "add submodule"])
            try await client.removeSubmodule("lib", purgeGitDir: purge)
            let kept = FileManager.default.fileExists(atPath: superPath + "/.git/modules/lib")
            do {
                try await client.addSubmodule(url: upstream, path: "lib")
                return (kept, true)
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("git directory"),
                    "unexpected failure: \(error.localizedDescription)"
                )
                return (kept, false)
            }
        }

        // Keeping the clone is safe for the submodule's own history, but
        // git then refuses to put anything at that path again.
        let kept = try await removeThenReadd(purge: false, in: "super-keep")
        XCTAssertTrue(kept.kept)
        XCTAssertFalse(kept.readded)

        // Purging it frees the path — the reason the dialog offers it.
        let purged = try await removeThenReadd(purge: true, in: "super-purge")
        XCTAssertFalse(purged.kept)
        XCTAssertTrue(purged.readded)
    }

    // MARK: - Git LFS

    /// Writes `bytes` of deterministic filler — real content, no network.
    private func writeBinary(_ bytes: Int, to path: String, seed: UInt8 = 7) throws {
        try Data(repeating: seed, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    /// Tracking a file that git already has: `.gitattributes` gets the
    /// pattern, and the file's index entry becomes a pointer.
    func testTrackWithLFSConvertsAnExistingFile() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-track")
        try writeBinary(120_000, to: path + "/art.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "add art"])

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertFalse(repo.snapshot.lfs.isEnabled)
        let file = FileChange(path: "art.psd", status: "M", area: .unstaged)

        repo.trackWithLFS(file, pattern: "*.psd")
        try await waitUntil("the .gitattributes write") {
            self.read(path + "/.gitattributes").contains("filter=lfs")
        }
        try await waitUntil("the refresh after tracking") { repo.snapshot.lfs.isEnabled }

        XCTAssertEqual(repo.snapshot.lfs.patterns, ["*.psd"])
        XCTAssertEqual(repo.snapshot.lfs.files.map(\.path), ["art.psd"])
        XCTAssertTrue(repo.snapshot.lfsMissing.isEmpty)
        XCTAssertNil(repo.errorMessage)
        // The index entry is a pointer now, not 120 KB of blob.
        let staged = try await git(path, ["show", ":art.psd"])
        XCTAssertTrue(staged.hasPrefix("version https://git-lfs.github.com/spec/v1"), staged)
        // .gitattributes is staged too — LFS is broken for everyone else
        // until that file is committed.
        XCTAssertTrue(repo.snapshot.staged.map(\.path).contains(".gitattributes"))
    }

    /// The diff of an LFS file is three lines of pointer text; the view
    /// gets a parsed summary instead.
    func testDiffOfAnLFSFileIsReportedAsAPointer() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-diff")
        try await git(path, ["lfs", "install", "--local"])
        try await git(path, ["lfs", "track", "*.psd"])
        try writeBinary(200_000, to: path + "/art.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "add art"])
        // Change it: 150 KB instead of 200 KB.
        try writeBinary(150_000, to: path + "/art.psd", seed: 9)

        let repo = RepoState(path: path)
        await repo.refresh()
        guard let file = repo.snapshot.unstaged.first(where: { $0.path == "art.psd" }) else {
            return XCTFail("expected art.psd to be modified: \(repo.snapshot.unstaged)")
        }
        repo.selectFile(file)
        try await waitUntil("the diff to load") { repo.lfsPointer != nil }

        XCTAssertEqual(repo.lfsPointer?.old?.size, 200_000)
        XCTAssertEqual(repo.lfsPointer?.new?.size, 150_000)
        XCTAssertEqual(repo.lfsPointer?.sizeDelta, -50_000)
        // Closing the diff clears it, so the next file starts clean.
        repo.closeDiff()
        XCTAssertNil(repo.lfsPointer)
        XCTAssertFalse(repo.showRawPointer)
    }

    /// A plain text file in the very same repo must not be mistaken for
    /// an LFS object.
    func testDiffOfANormalFileHasNoPointer() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-mixed")
        try await git(path, ["lfs", "install", "--local"])
        try await git(path, ["lfs", "track", "*.psd"])
        try writeBinary(50_000, to: path + "/art.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "add art"])
        try write("changed\n", to: path + "/seed.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertTrue(repo.snapshot.lfs.isEnabled)
        guard let file = repo.snapshot.unstaged.first(where: { $0.path == "seed.txt" }) else {
            return XCTFail("expected seed.txt to be modified")
        }
        repo.selectFile(file)
        try await waitUntil("the diff to load") { !repo.diffLines.isEmpty }
        XCTAssertNil(repo.lfsPointer)
        XCTAssertFalse(repo.isLFSTracked("seed.txt"))
        XCTAssertTrue(repo.isLFSTracked("art.psd"))
    }

    /// `git lfs ls-files` marks a locally modified file `-` exactly like a
    /// file that was never downloaded — its new content is not in the
    /// object store yet. Reporting that as "not downloaded" would push the
    /// user to run `git lfs pull` over their own uncommitted work.
    func testLocallyModifiedLFSFileIsNotReportedAsMissing() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-modified")
        try await git(path, ["lfs", "install", "--local"])
        try await git(path, ["lfs", "track", "*.psd"])
        try writeBinary(80_000, to: path + "/art.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "add art"])

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertTrue(repo.snapshot.lfs.files[0].downloaded)
        XCTAssertTrue(repo.snapshot.lfsMissing.isEmpty)

        // Edit it: git-lfs now says the object is not in the store. The
        // ls-files cache has a 2 s life, so poll rather than assume.
        try writeBinary(90_000, to: path + "/art.psd", seed: 3)
        try await waitUntil("ls-files to see the edit") {
            repo.snapshot.lfs.notInLocalStore.map(\.path) == ["art.psd"]
        } refreshing: {
            await repo.refresh()
        }
        // ...but nothing is missing, so the sidebar stays quiet and the
        // diff offers Open rather than Download.
        XCTAssertTrue(repo.snapshot.lfsMissing.isEmpty)
        XCTAssertFalse(repo.isLFSObjectMissing("art.psd"))
    }

    /// The ls-files cache: a burst of refreshes costs one call, the answer
    /// catches up once the TTL passes, and patterns are never cached at
    /// all (they come from a file we read on every call).
    func testLFSStatusCacheServesBurstsButCatchesUp() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-cache")
        try await git(path, ["lfs", "install", "--local"])
        try await git(path, ["lfs", "track", "*.psd"])
        try writeBinary(20_000, to: path + "/one.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "one"])

        let client = GitClient(repoPath: path)
        var status = await client.lfsStatus()
        XCTAssertEqual(status.files.map(\.path), ["one.psd"])

        // Added behind the client's back: within the TTL it keeps the
        // cached list — that is the whole point of it.
        try writeBinary(30_000, to: path + "/two.psd")
        try await git(path, ["add", "-A"])
        status = await client.lfsStatus()
        XCTAssertEqual(status.files.map(\.path), ["one.psd"])

        // A pattern added meanwhile still shows up immediately.
        try await git(path, ["lfs", "track", "*.blend"])
        status = await client.lfsStatus()
        XCTAssertEqual(status.patterns.sorted(), ["*.blend", "*.psd"])

        // ...and the file list catches up once the TTL is over.
        try await Task.sleep(for: .milliseconds(2100))
        status = await client.lfsStatus()
        XCTAssertEqual(status.files.map(\.path).sorted(), ["one.psd", "two.psd"])
    }

    /// Our own LFS commands must not wait for the TTL — pressing Download
    /// and still reading "not downloaded" is the bug this prevents.
    func testLFSActionsInvalidateTheCacheImmediately() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let path = try await makeRepo("lfs-invalidate")
        try await git(path, ["lfs", "install", "--local"])
        try await git(path, ["lfs", "track", "*.psd"])
        try writeBinary(20_000, to: path + "/one.psd")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "one"])

        let client = GitClient(repoPath: path)
        var status = await client.lfsStatus()
        XCTAssertEqual(status.files.count, 1)

        // The flow for a brand-new big file: track the extension, then
        // stage it. `ls-files` reads the index, so it only counts once
        // staged — and the status right after that must already show it.
        try writeBinary(30_000, to: path + "/model.blend")
        try await client.lfsTrack("*.blend")
        try await client.stage("model.blend")
        status = await client.lfsStatus()
        XCTAssertEqual(status.files.map(\.path).sorted(), ["model.blend", "one.psd"])
        // Staged as a pointer, not as 30 KB of blob.
        let staged = try await client.run(["show", ":model.blend"])
        XCTAssertTrue(staged.hasPrefix("version https://git-lfs.github.com/spec/v1"), staged)
    }

    /// The state a fresh clone is in when the objects were skipped: real
    /// pointers in the working tree and nothing in the store. This is what
    /// the sidebar's "N not downloaded" and its pull button exist for.
    func testFreshCloneReportsMissingObjectsAndPullFetchesThem() async throws {
        try XCTSkipUnless(GitClient.hasLFS, "git-lfs is not installed")
        let origin = try await makeRepo("lfs-origin")
        try await git(origin, ["lfs", "install", "--local"])
        try await git(origin, ["lfs", "track", "*.psd"])
        try writeBinary(64_000, to: origin + "/art.psd")
        try await git(origin, ["add", "-A"])
        try await git(origin, ["commit", "-qm", "add art"])

        // GIT_LFS_SKIP_SMUDGE leaves the pointers in place — exactly what
        // a clone over a slow link, or with lfs.fetchexclude set, gives you.
        let clone = root.appendingPathComponent("lfs-clone").path
        try await Shell.run(
            "/usr/bin/env",
            ["git", "clone", "-q", origin, clone],
            env: ["GIT_LFS_SKIP_SMUDGE": "1", "GIT_TERMINAL_PROMPT": "0"]
        )

        let repo = RepoState(path: clone)
        await repo.refresh()
        XCTAssertEqual(repo.snapshot.lfsMissing.map(\.path), ["art.psd"])
        XCTAssertTrue(repo.isLFSObjectMissing("art.psd"))
        // The working tree really does hold the pointer, not the picture.
        XCTAssertLessThan(
            try Data(contentsOf: URL(fileURLWithPath: clone + "/art.psd")).count, 200
        )

        repo.pullLFSObjects()
        try await waitUntil("git lfs pull") { repo.snapshot.lfsMissing.isEmpty }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: clone + "/art.psd")).count, 64_000
        )
        XCTAssertNil(repo.errorMessage)
    }

    /// A repo with no `.gitattributes` must not spawn `git lfs` at all,
    /// and reports itself as not using LFS.
    func testPlainRepoReportsNoLFS() async throws {
        let path = try await makeRepo("lfs-absent")
        let status = await GitClient(repoPath: path).lfsStatus()
        XCTAssertFalse(status.isEnabled)
        XCTAssertTrue(status.files.isEmpty)
    }

    /// A submodule whose checked-out commit moved shows "+", the state the
    /// row paints orange.
    func testSubmoduleOutOfSyncState() async throws {
        let upstream = try await makeRepo("upstream-moved")
        let superPath = try await makeRepo("super-moved")
        let client = GitClient(repoPath: superPath)
        try await client.addSubmodule(url: upstream, path: "lib")
        try await git(superPath, ["commit", "-qm", "add submodule"])

        // New commit inside the submodule, not yet recorded by the parent.
        let inner = superPath + "/lib"
        try write("more\n", to: inner + "/seed.txt")
        try await git(inner, ["commit", "-qam", "move on"])

        let subs = try await client.submodules()
        XCTAssertEqual(subs.first?.state, "+")
        XCTAssertEqual(subs.first?.stateDescription, "Checked-out commit differs from index")
    }

    /// The Push button on a freshly created branch: bare `git push` refuses
    /// to guess a destination, so it has to set the upstream itself instead
    /// of leaving the user to type `push -u origin <branch>`.
    func testPushSetsUpstreamForABranchThatHasNone() async throws {
        let origin = root.appendingPathComponent("origin.git").path
        try await Shell.run("/usr/bin/env", ["git", "init", "-q", "--bare", "-b", "main", origin])
        let path = try await makeRepo("push-new-branch")
        try await git(path, ["remote", "add", "origin", origin])
        try await git(path, ["push", "-q", "-u", "origin", "main"])

        try await git(path, ["checkout", "-q", "-b", "feature/x"])
        try write("work\n", to: path + "/work.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "work"])

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertNil(repo.snapshot.localBranches.first(where: \.isCurrent)?.upstream)

        repo.push()
        try await waitUntil("the push to set an upstream", { [weak repo] in
            repo?.snapshot.localBranches.first(where: \.isCurrent)?.upstream == "origin/feature/x"
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        let remoteRefs = try await git(origin, ["branch", "--format=%(refname:short)"])
        XCTAssertTrue(remoteRefs.contains("feature/x"), remoteRefs)
    }

    /// A branch created off origin/main keeps tracking it, and bare
    /// `git push` refuses under push.default=simple because the names
    /// differ. The button must push the branch under its own name and
    /// re-point the tracking there (GitKraken's behaviour), not surface
    /// git's fatal.
    func testPushOnBranchTrackingDifferentlyNamedUpstream() async throws {
        let origin = root.appendingPathComponent("origin-mismatch.git").path
        try await Shell.run("/usr/bin/env", ["git", "init", "-q", "--bare", "-b", "main", origin])
        let path = try await makeRepo("push-mismatch")
        try await git(path, ["remote", "add", "origin", origin])
        try await git(path, ["push", "-q", "-u", "origin", "main"])
        try await git(path, ["checkout", "-q", "-b", "fix/thing", "--track", "origin/main"])
        try write("fix\n", to: path + "/fix.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "fix"])

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(
            repo.snapshot.localBranches.first(where: \.isCurrent)?.upstream, "origin/main")

        repo.push()
        try await waitUntil("the push to land under the branch's own name", { [weak repo] in
            repo?.snapshot.localBranches.first(where: \.isCurrent)?.upstream == "origin/fix/thing"
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        let remoteRefs = try await git(origin, ["branch", "--format=%(refname:short)"])
        XCTAssertTrue(remoteRefs.contains("fix/thing"), remoteRefs)
    }

    /// Nothing has ever been pushed, so there are no remote-tracking
    /// branches to read a remote name off — the very first push still has to
    /// land on the configured `origin`.
    func testFirstPushOfAllInARepoWithNoRemoteBranchesYet() async throws {
        let origin = root.appendingPathComponent("origin-empty.git").path
        try await Shell.run("/usr/bin/env", ["git", "init", "-q", "--bare", "-b", "main", origin])
        let path = try await makeRepo("push-first-ever")
        try await git(path, ["remote", "add", "origin", origin])

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertTrue(repo.snapshot.remoteNames.isEmpty)

        repo.push()
        try await waitUntil("the first push to set an upstream", { [weak repo] in
            repo?.snapshot.localBranches.first(where: \.isCurrent)?.upstream == "origin/main"
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)
    }

    /// Pushing a branch that is not checked out — the sidebar's Push on
    /// another branch row. It must move that branch's ref, not HEAD's.
    func testPushingANonCurrentBranchLeavesHEADAlone() async throws {
        let origin = root.appendingPathComponent("origin-other.git").path
        try await Shell.run("/usr/bin/env", ["git", "init", "-q", "--bare", "-b", "main", origin])
        let path = try await makeRepo("push-other-branch")
        try await git(path, ["remote", "add", "origin", origin])
        try await git(path, ["push", "-q", "-u", "origin", "main"])

        // A commit on `side`, then back to main and a commit there too.
        try await git(path, ["checkout", "-q", "-b", "side"])
        try write("side\n", to: path + "/side.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "side work"])
        try await git(path, ["checkout", "-q", "main"])
        try write("main\n", to: path + "/main.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "main work"])

        let repo = RepoState(path: path)
        await repo.refresh()
        let side = try XCTUnwrap(repo.snapshot.localBranches.first { $0.name == "side" })
        repo.push(side, to: repo.remote(for: side))

        try await waitUntil("side to reach the remote", { [weak repo] in
            repo?.snapshot.localBranches.first { $0.name == "side" }?.upstream == "origin/side"
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        // main's new commit stayed local: the push targeted `side` only.
        let remoteMain = try await git(origin, ["log", "-1", "--format=%s", "main"])
        XCTAssertEqual(remoteMain.trimmingCharacters(in: .whitespacesAndNewlines), "init")
        let remoteSide = try await git(origin, ["log", "-1", "--format=%s", "side"])
        XCTAssertEqual(remoteSide.trimmingCharacters(in: .whitespacesAndNewlines), "side work")
    }

    /// Merge straight from a commit row in the graph: git takes the sha, so
    /// the commit's work lands on the current branch even though no branch
    /// name was involved.
    func testMergingACommitBringsItsWorkOntoTheCurrentBranch() async throws {
        let path = try await makeRepo("merge-commit")
        try await git(path, ["checkout", "-q", "-b", "side"])
        try write("side\n", to: path + "/side.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "side work"])
        try await git(path, ["checkout", "-q", "main"])

        let repo = RepoState(path: path)
        await repo.refresh()
        let commit = try XCTUnwrap(repo.snapshot.commits.first { $0.subject == "side work" })
        repo.merge(commit)

        try await waitUntil("the merge to land", {
            FileManager.default.fileExists(atPath: path + "/side.txt")
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)
        XCTAssertEqual(repo.snapshot.currentBranch, "main")
    }

    /// The sidebar's "Merge into main" on a branch that is strictly ahead
    /// must still record a merge commit. Git's default fast-forward just
    /// slides the ref — history then shows the branch as never merged,
    /// indistinguishable from a reset.
    func testExplicitMergeRecordsAMergeCommitEvenWhenFastForwardIsPossible() async throws {
        let path = try await makeRepo("merge-no-ff")
        try await git(path, ["checkout", "-q", "-b", "side"])
        try write("side\n", to: path + "/side.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "side work"])
        try await git(path, ["checkout", "-q", "main"])

        let repo = RepoState(path: path)
        await repo.refresh()
        let side = try XCTUnwrap(repo.snapshot.localBranches.first { $0.name == "side" })
        repo.merge(side)

        // Wait for the merge COMMIT, not the file: --no-ff lays down the
        // working tree first, so side.txt exists a beat before HEAD moves.
        try await waitUntil("the merge commit to land", {
            repo.snapshot.commits.first { !$0.isWip }?
                .subject.hasPrefix("Merge branch") == true
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)
        // Two parents at HEAD = a real merge commit, not a fast-forward.
        let parents = try await git(path, ["log", "-1", "--format=%P"])
        XCTAssertEqual(
            parents.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").count,
            2
        )
    }

    // MARK: - Stash

    /// "Stash n Staged Files" takes the staged ones and nothing else — the
    /// rest of the working tree is still there afterwards.
    func testStashingOnlyStagedFilesLeavesTheRestInTheWorkingTree() async throws {
        let path = try await makeRepo("stash-staged")
        try write("keep\n", to: path + "/keep.txt")      // untracked, stays
        try write("new\n", to: path + "/new.png")        // staged, goes
        try await git(path, ["add", "new.png"])
        try write("seed\nedited\n", to: path + "/seed.txt")  // unstaged, stays

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(repo.snapshot.staged.map(\.path), ["new.png"])

        repo.stashChanges(only: repo.snapshot.staged.map(\.path))
        try await waitUntil("the staged file to be stashed", {
            repo.snapshot.staged.isEmpty && repo.snapshot.stashes.count == 1
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/new.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/keep.txt"))
        XCTAssertEqual(read(path + "/seed.txt"), "seed\nedited\n")
        XCTAssertEqual(untrackedPaths(repo), ["keep.txt"])
    }

    /// The mirror image: the unstaged half goes, and what was staged is
    /// still staged and ready to commit.
    func testStashingOnlyUnstagedFilesKeepsTheIndex() async throws {
        let path = try await makeRepo("stash-unstaged")
        try write("new\n", to: path + "/new.png")
        try await git(path, ["add", "new.png"])
        try write("seed\nedited\n", to: path + "/seed.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        let unstaged = repo.snapshot.unstaged.map(\.path)
        XCTAssertEqual(unstaged, ["seed.txt"])

        repo.stashChanges(only: unstaged)
        try await waitUntil("the unstaged file to be stashed", {
            repo.snapshot.unstaged.isEmpty && repo.snapshot.stashes.count == 1
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        XCTAssertEqual(read(path + "/seed.txt"), "seed\n")
        XCTAssertEqual(repo.snapshot.staged.map(\.path), ["new.png"])
    }

    /// A file with both staged and unstaged edits is what makes
    /// `git stash push --staged` fail halfway, leaving a stash entry whose
    /// changes are still in the tree. The pathspec push takes it whole.
    func testStashingAFileStagedAndEditedAgainTakesItWhole() async throws {
        let path = try await makeRepo("stash-mixed")
        try write("one\n", to: path + "/seed.txt")
        try await git(path, ["add", "seed.txt"])
        try write("one\ntwo\n", to: path + "/seed.txt")   // staged + unstaged

        let repo = RepoState(path: path)
        await repo.refresh()
        repo.stashChanges(only: ["seed.txt"])
        try await waitUntil("the mixed file to be stashed", {
            repo.snapshot.stashes.count == 1
        }, refreshing: { await repo.refresh() })
        XCTAssertNil(repo.errorMessage)

        // Both halves left: back to the committed content, nothing pending.
        XCTAssertEqual(read(path + "/seed.txt"), "seed\n")
        XCTAssertTrue(repo.snapshot.staged.isEmpty)
        XCTAssertTrue(repo.snapshot.unstaged.isEmpty)
    }

    // MARK: - Pull auto-stash

    /// Origin seeded with `main`, the app's working clone, and a second
    /// clone to push upstream work from.
    private func makePullFixture(_ name: String) async throws -> (path: String, theirs: String) {
        let origin = root.appendingPathComponent("\(name)-origin.git").path
        try await Shell.run("/usr/bin/env", ["git", "init", "-q", "--bare", "-b", "main", origin])
        let path = try await makeRepo(name)
        try await git(path, ["remote", "add", "origin", origin])
        try await git(path, ["push", "-q", "-u", "origin", "main"])
        let theirs = root.appendingPathComponent("\(name)-theirs").path
        try await git(root.path, ["clone", "-q", origin, theirs])
        return (path, theirs)
    }

    private func pushUpstream(_ theirs: String, file: String, contents: String) async throws {
        try write(contents, to: theirs + "/" + file)
        try await git(theirs, ["add", "-A"])
        try await git(theirs, ["commit", "-qm", "upstream work"])
        try await git(theirs, ["push", "-q"])
    }

    /// Pull on a dirty tree, GitKraken-style: the upstream commit arrives,
    /// the uncommitted edits (tracked and untracked) come back, and no
    /// stash entry is left behind.
    func testPullAutoStashesADirtyTreeAndRestoresIt() async throws {
        let (path, theirs) = try await makePullFixture("pull-dirty")
        try await pushUpstream(theirs, file: "upstream.txt", contents: "up\n")

        try write("wip\n", to: path + "/seed.txt")
        try write("note\n", to: path + "/note.txt")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.pull()
        // Snapshot state matches the pre-pull state mid-flight, so the wait
        // has to pin the timing on the working-tree contents themselves.
        try await waitUntil("the pull to land and the WIP to come back") { [weak repo] in
            self.read(path + "/upstream.txt") == "up\n"
                && self.read(path + "/seed.txt") == "wip\n"
                && self.read(path + "/note.txt") == "note\n"
                && repo?.snapshot.unstaged.map(\.path).sorted() == ["note.txt", "seed.txt"]
                && repo?.snapshot.stashes.isEmpty == true
        }
        XCTAssertNil(repo.errorMessage)
    }

    /// The pop conflicts: upstream rewrote the same lines the uncommitted
    /// edit touches. The markers land in the working tree where the
    /// conflict UI presents them, and the stash is kept as the backup.
    func testPullPopConflictMarksTheFileAndKeepsTheStash() async throws {
        let (path, theirs) = try await makePullFixture("pull-pop-conflict")
        try await pushUpstream(theirs, file: "seed.txt", contents: "upstream\n")

        try write("local\n", to: path + "/seed.txt")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.pull()
        try await waitUntil("the pop conflict to surface") { [weak repo] in
            repo?.snapshot.conflicted.map(\.path) == ["seed.txt"]
                && repo?.snapshot.stashes.count == 1
        }
        XCTAssertTrue(read(path + "/seed.txt").contains("<<<<<<<"))
        XCTAssertTrue(repo.errorMessage?.contains("kept as a backup") == true,
                      repo.errorMessage ?? "no error message")
    }

    /// A refused pull (`--ff-only` on a diverged branch) never touched the
    /// tree, so the auto-stashed WIP must go straight back — as if the
    /// stash dance never happened.
    func testRefusedPullRestoresTheAutoStash() async throws {
        let (path, theirs) = try await makePullFixture("pull-refused")
        try await pushUpstream(theirs, file: "seed.txt", contents: "upstream\n")

        // Diverge locally (different file, so only fast-forward is refused,
        // not the merge itself), then dirty the tree.
        try write("mine\n", to: path + "/mine.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "local work"])
        try write("wip\n", to: path + "/wip.txt")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.runPull(.ffOnly)
        try await waitUntil("the refused pull to restore the WIP") { [weak repo] in
            repo?.errorMessage != nil
                && repo?.snapshot.unstaged.map(\.path) == ["wip.txt"]
                && repo?.snapshot.stashes.isEmpty == true
        }
        XCTAssertEqual(read(path + "/wip.txt"), "wip\n")
    }

    /// The pull itself stops on merge conflicts. Popping onto a conflicted
    /// tree would tangle the WIP into the merge, so the stash must stay
    /// put — and the error must say where the changes went.
    func testConflictedPullKeepsTheAutoStashForLater() async throws {
        let (path, theirs) = try await makePullFixture("pull-merge-conflict")
        try await pushUpstream(theirs, file: "seed.txt", contents: "upstream\n")

        // Modern git refuses a plain pull on divergence unless told how.
        try await git(path, ["config", "pull.rebase", "false"])
        try write("mine\n", to: path + "/seed.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "local work"])
        try write("wip\n", to: path + "/wip.txt")
        let repo = RepoState(path: path)
        await repo.refresh()

        repo.pull()
        try await waitUntil("the merge conflict to surface with the stash kept") { [weak repo] in
            repo?.snapshot.operation == .merge
                && repo?.snapshot.conflicted.map(\.path) == ["seed.txt"]
                && repo?.snapshot.stashes.count == 1
        }
        // The WIP is in the stash, not in the conflicted tree.
        XCTAssertEqual(read(path + "/wip.txt"), "")
        XCTAssertTrue(repo.errorMessage?.contains("safe in the stash") == true,
                      repo.errorMessage ?? "no error message")
    }

    // MARK: - Status-only refresh

    /// Staging is a move within the index. The lists have to change and
    /// nothing that costs a subprocess to re-read is allowed to change with
    /// them — that identity is the whole point of the narrow path, so it is
    /// asserted rather than assumed.
    func testStagingAFileMovesItWithoutRebuildingTheGraph() async throws {
        let path = try await makeRepo("stage-narrow")
        try write("one\n", to: path + "/one.txt")
        try write("two\n", to: path + "/two.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertEqual(untrackedPaths(repo).sorted(), ["one.txt", "two.txt"])
        let rowsBefore = repo.snapshot.graphRows.map(\.commit.hash)
        let commitsBefore = repo.snapshot.commits

        guard let one = repo.snapshot.unstaged.first(where: { $0.path == "one.txt" }) else {
            return XCTFail("one.txt is missing from the unstaged list")
        }
        repo.stage(one)
        try await waitUntil("one.txt to move to the staged list") {
            repo.snapshot.staged.map(\.path) == ["one.txt"]
        }

        XCTAssertEqual(untrackedPaths(repo), ["two.txt"])
        XCTAssertEqual(repo.snapshot.graphRows.map(\.commit.hash), rowsBefore)
        XCTAssertEqual(repo.snapshot.commits, commitsBefore)
        XCTAssertNil(repo.errorMessage)
    }

    /// The WIP node means "the working tree differs from HEAD", not "there
    /// are unstaged files". Staging the last unstaged edit leaves the tree
    /// just as dirty, so the row has to stay — reading the dirty flag off
    /// the unstaged list alone would drop it here.
    func testStagingTheLastUnstagedFileKeepsTheWipNode() async throws {
        let path = try await makeRepo("stage-wip")
        try write("seed\nedited\n", to: path + "/seed.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        XCTAssertFalse(repo.snapshot.unstaged.isEmpty)
        XCTAssertTrue(repo.snapshot.graphRows.contains { $0.commit.isWip })

        repo.stageAll()
        try await waitUntil("the edit to reach the index") {
            repo.snapshot.unstaged.isEmpty && !repo.snapshot.staged.isEmpty
        }
        XCTAssertTrue(
            repo.snapshot.graphRows.contains { $0.commit.isWip },
            "the working tree still differs from HEAD, so the WIP row belongs in the graph"
        )
        XCTAssertNil(repo.errorMessage)
    }

    /// Unstage is the same path in reverse, and it also has to leave the
    /// selected-file bookkeeping alone when the file is still pending.
    func testUnstagingReturnsTheFileToTheUnstagedList() async throws {
        let path = try await makeRepo("unstage-narrow")
        try write("seed\nedited\n", to: path + "/seed.txt")
        try await git(path, ["add", "seed.txt"])

        let repo = RepoState(path: path)
        await repo.refresh()
        guard let staged = repo.snapshot.staged.first else {
            return XCTFail("seed.txt is missing from the staged list")
        }
        repo.unstage(staged)
        try await waitUntil("seed.txt to come back unstaged") {
            repo.snapshot.staged.isEmpty && repo.snapshot.unstaged.map(\.path) == ["seed.txt"]
        }
        XCTAssertTrue(repo.snapshot.graphRows.contains { $0.commit.isWip })
        XCTAssertNil(repo.errorMessage)
    }

    /// What actually makes staging cheap, stated as behaviour: it re-reads
    /// `git status` and nothing else, so a commit made behind the app's back
    /// is still not in the log afterwards. The file watcher's full refresh
    /// is what picks that up — this asserts the narrow path stayed narrow.
    func testStagingDoesNotReReadTheLog() async throws {
        let path = try await makeRepo("stage-log-untouched")
        try write("one\n", to: path + "/one.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        let commitsBefore = repo.snapshot.commits.count
        guard let one = repo.snapshot.unstaged.first(where: { $0.path == "one.txt" }) else {
            return XCTFail("one.txt is missing from the unstaged list")
        }

        try await git(path, ["commit", "--allow-empty", "-qm", "made outside the app"])
        repo.stage(one)
        try await waitUntil("one.txt to reach the index") {
            repo.snapshot.staged.map(\.path) == ["one.txt"]
        }
        XCTAssertEqual(
            repo.snapshot.commits.count, commitsBefore,
            "staging re-read the whole repo — the point of the narrow path is that it doesn't"
        )

        await repo.refresh()
        XCTAssertEqual(repo.snapshot.commits.count, commitsBefore + 1)
    }

    // MARK: - Clean up (batch delete)

    /// Adds `name` as a branch whose one commit is already merged into main,
    /// which is what makes it a cleanup candidate.
    private func makeMergedBranch(_ path: String, _ name: String) async throws {
        try await git(path, ["checkout", "-q", "-b", name])
        try write(name + "\n", to: path + "/\(name).txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "work on \(name)"])
        try await git(path, ["checkout", "-q", "main"])
        try await git(path, ["merge", "-q", "--no-ff", "-m", "merge \(name)", name])
    }

    private func localBranches(_ path: String) async throws -> [String] {
        try await git(path, ["branch", "--format=%(refname:short)"])
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .sorted()
    }

    /// Select all then delete is the whole list in one click: every candidate
    /// branch is gone from git afterwards, and main — never a candidate — is
    /// untouched.
    func testSelectAllThenDeleteRemovesEveryCandidateBranch() async throws {
        let path = try await makeRepo("clean-all")
        for name in ["feat-a", "feat-b", "feat-c"] {
            try await makeMergedBranch(path, name)
        }
        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        XCTAssertEqual(repo.cleanupCandidates.map(\.name).sorted(), ["feat-a", "feat-b", "feat-c"])

        repo.selectAllCleanup(true)
        XCTAssertEqual(repo.selectedCleanupCandidates.count, 3)
        repo.requestClean(repo.selectedCleanupCandidates)
        repo.confirmPendingClean()
        try await waitUntil("all three branches to go") { repo.cleanupCandidates.isEmpty }
        let after = try await localBranches(path)
        XCTAssertEqual(after, ["main"], "Delete All left branches behind")
        XCTAssertNil(repo.cleanupError)
        // Eleven deletes are one click, so they are one Undo.
        XCTAssertEqual(repo.cleanupUndo.count, 1)
        XCTAssertEqual(repo.cleanupUndo.last?.deletes.count, 3)
    }

    /// The ticks decide the batch: unticked rows survive it untouched.
    func testBatchDeletesOnlyTheTickedRows() async throws {
        let path = try await makeRepo("clean-selected")
        for name in ["keep-me", "drop-a", "drop-b"] {
            try await makeMergedBranch(path, name)
        }
        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()

        for candidate in repo.cleanupCandidates where candidate.name.hasPrefix("drop-") {
            repo.toggleCleanupSelection(candidate)
        }
        XCTAssertEqual(repo.selectedCleanupCandidates.map(\.name).sorted(), ["drop-a", "drop-b"])

        repo.requestClean(repo.selectedCleanupCandidates)
        // A batch always asks, even when every row in it is safe.
        XCTAssertNotNil(repo.cleanToConfirm)
        repo.confirmPendingClean()

        try await waitUntil("the two ticked branches to go") {
            repo.cleanupCandidates.map(\.name) == ["keep-me"]
        }
        let remaining = try await localBranches(path)
        XCTAssertEqual(remaining, ["keep-me", "main"])
        // Nothing is left ticked that no longer exists.
        XCTAssertTrue(repo.cleanupSelection.isEmpty)
        XCTAssertNil(repo.cleanupError)
    }

    /// Undo covers the click, not the branch: one Undo after a batch puts
    /// every branch back at exactly the tip it had.
    func testUndoAfterABatchRestoresEveryBranchAtItsTip() async throws {
        let path = try await makeRepo("clean-undo")
        for name in ["feat-a", "feat-b"] {
            try await makeMergedBranch(path, name)
        }
        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        var tips: [String: String] = [:]
        for name in ["feat-a", "feat-b"] {
            tips[name] = try await git(path, ["rev-parse", name])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        repo.clean(repo.cleanupCandidates)
        try await waitUntil("both branches to go") { repo.cleanupCandidates.isEmpty }
        let deleted = try await localBranches(path)
        XCTAssertEqual(deleted, ["main"])

        repo.undoLastClean()
        try await waitUntil("both branches to come back") {
            repo.cleanupCandidates.count == 2
        }
        let restoredBranches = try await localBranches(path)
        XCTAssertEqual(restoredBranches, ["feat-a", "feat-b", "main"])
        for (name, tip) in tips {
            let restored = try await git(path, ["rev-parse", name])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(restored, tip, "\(name) came back at a different commit")
        }
        XCTAssertTrue(repo.cleanupUndo.isEmpty)
        XCTAssertNil(repo.cleanupError)
    }

    /// One row that git refuses must not strand the rows behind it. The lock
    /// lands after the scan, so the batch meets a refusal the rows couldn't
    /// have carried — which is the case per-row error handling exists for.
    func testAFailedRowDoesNotStopTheRestOfTheBatch() async throws {
        let path = try await makeRepo("clean-partial")
        try await makeMergedBranch(path, "feat-a")
        try await makeMergedBranch(path, "wt-branch")
        let worktree = root.appendingPathComponent("clean-partial-wt").path
        try await git(path, ["worktree", "add", "-q", worktree, "wt-branch"])

        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        // The branch is checked out in the worktree, so the worktree is the
        // candidate for it — not the branch.
        XCTAssertEqual(repo.cleanupCandidates.map(\.name).sorted(), ["clean-partial-wt", "feat-a"])

        try await git(path, ["worktree", "lock", worktree])
        repo.clean(repo.cleanupCandidates)
        try await waitUntil("the batch to finish") { !repo.cleaning }
        let survivors = try await localBranches(path)
        XCTAssertEqual(
            survivors, ["main", "wt-branch"],
            "the merged branch should have gone even though the worktree refused"
        )
        XCTAssertNotNil(repo.cleanupError, "a refused row has to be reported")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree),
            "the locked worktree must survive"
        )
    }

    /// A worktree of any JS project has `node_modules` in it forever, so
    /// "git refuses when it's dirty" would mean the row never works. The
    /// scan counts what's there, the row says so, and the delete goes
    /// through — untracked directories counting once, not per file inside.
    func testDirtyWorktreeCountsWhatItWillDeleteAndGoes() async throws {
        let path = try await makeRepo("clean-dirty-wt")
        try await makeMergedBranch(path, "wt-branch")
        let worktree = root.appendingPathComponent("clean-dirty-wt-tree").path
        try await git(path, ["worktree", "add", "-q", worktree, "wt-branch"])
        try FileManager.default.createDirectory(
            atPath: worktree + "/node_modules", withIntermediateDirectories: true
        )
        try write("dep\n", to: worktree + "/node_modules/dep.js")
        try write("dep2\n", to: worktree + "/node_modules/dep2.js")
        try write("edited\n", to: worktree + "/wt-branch.txt")

        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        let candidate = try XCTUnwrap(repo.cleanupCandidates.first { $0.isWorktree })
        XCTAssertEqual(
            candidate.dirtyEntries, 2,
            "one modified file plus one untracked directory, not three files"
        )
        XCTAssertFalse(candidate.isSafe, "a dirty folder has to ask first")
        XCTAssertEqual(
            candidate.riskText, "deletes the folder and 2 uncommitted changes"
        )

        repo.clean([candidate])
        try await waitUntil("the worktree to go") { !repo.cleaning }
        XCTAssertNil(repo.cleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    /// The confirmation is valid only for the count it displayed. A change
    /// made after the scan must survive, along with the worktree that owns it.
    func testDirtyWorktreeChangedAfterScanIsNotRemoved() async throws {
        let path = try await makeRepo("clean-dirty-wt-changed")
        try await makeMergedBranch(path, "wt-branch")
        let worktree = root.appendingPathComponent("clean-dirty-wt-changed-tree").path
        try await git(path, ["worktree", "add", "-q", worktree, "wt-branch"])
        let originalChange = worktree + "/wt-branch.txt"
        let lateChange = worktree + "/after-scan.txt"
        try write("edited\n", to: originalChange)

        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        let candidate = try XCTUnwrap(repo.cleanupCandidates.first { $0.isWorktree })
        XCTAssertEqual(candidate.dirtyEntries, 1)

        try write("created after confirmation\n", to: lateChange)
        repo.clean([candidate])
        try await waitUntil("cleanup refusal and rescan") { !repo.cleaning }

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalChange))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateChange))
        XCTAssertEqual(
            repo.cleanupError,
            "git worktree remove: The worktree changed after it was scanned. "
                + "Review its 2 uncommitted changes and try again."
        )
        let refreshed = try XCTUnwrap(repo.cleanupCandidates.first { $0.isWorktree })
        XCTAssertEqual(refreshed.dirtyEntries, 2)
    }

    /// The repo's own working directory is the first thing `git worktree
    /// list` prints. Left unmarked it becomes a Clean row — on a branch
    /// merged long ago, that row offers to delete the repo you're in, and
    /// git can only answer "is a main working tree".
    func testMainWorktreeIsNeverACandidate() async throws {
        let path = try await makeRepo("clean-main-wt")
        try await makeMergedBranch(path, "test")
        // The repo sits on a merged branch that isn't the default one —
        // every signal the scan reads says "done with this".
        try await git(path, ["checkout", "-q", "test"])

        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        XCTAssertEqual(
            repo.cleanupCandidates.filter(\.isWorktree).map(\.name), [],
            "the main worktree must not be offered for deletion"
        )
    }

    /// A rescan hands back fresh structs, so the ticks are kept by id — and
    /// dropped for rows the rescan no longer finds.
    func testSelectionSurvivesARescanAndDropsVanishedRows() async throws {
        let path = try await makeRepo("clean-selection-rescan")
        for name in ["feat-a", "feat-b"] {
            try await makeMergedBranch(path, name)
        }
        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.scanCleanup()
        repo.selectAllCleanup(true)
        XCTAssertEqual(repo.cleanupSelection.count, 2)

        await repo.scanCleanup()
        XCTAssertEqual(repo.cleanupSelection.count, 2, "a rescan dropped the ticks")

        // Deleted behind the app's back: the tick has nothing left to point at.
        try await git(path, ["branch", "-D", "feat-a"])
        await repo.refresh()
        await repo.scanCleanup()
        XCTAssertEqual(repo.cleanupSelection, ["branch:feat-b"])
    }
}
