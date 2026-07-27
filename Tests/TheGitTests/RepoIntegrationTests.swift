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
}
