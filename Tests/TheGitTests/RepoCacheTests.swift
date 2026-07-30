import XCTest
@testable import TheGit

/// The launch cache: what survives a restart, what is deliberately dropped
/// and recomputed, and what must never be restored.
final class RepoCacheTests: XCTestCase {

    /// A directory of its own per test. `prune` deletes every file it wasn't
    /// told to keep, so running these against the real cache would clear the
    /// caches of whatever repos the person running the tests has open.
    private var path = ""
    private var tempDir: URL!
    private var realDir: URL?

    override func setUp() {
        super.setUp()
        path = "/tmp/thegit-cache-test-\(UUID().uuidString)"
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thegit-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        realDir = RepoCache.dir
        RepoCache.dir = tempDir
    }

    override func tearDown() {
        RepoCache.dir = realDir
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func commit(_ hash: String, parents: [String] = []) -> Commit {
        Commit(
            hash: hash, parents: parents, author: "Tao",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            refs: [], subject: "s-" + hash, email: "tao@example.com"
        )
    }

    private func snapshot() -> RepoSnapshot {
        var snap = RepoSnapshot()
        snap.commits = [commit("a", parents: ["b"]), commit("b")]
        snap.activity = [20_260_728: 3, 20_260_729: 1]
        snap.localBranches = [
            Branch(name: "main", kind: .local, isCurrent: true, tipHash: "a", ahead: 1, behind: 2),
        ]
        snap.remoteBranches = [
            Branch(name: "origin/main", kind: .remote("origin"), isCurrent: false, tipHash: "b"),
        ]
        snap.worktrees = [Worktree(path: "/tmp/wt", branch: "main", head: "a", isMain: true)]
        snap.submodules = [Submodule(path: "vendor/lib", sha: "abc", state: "+")]
        snap.lfs = LFSStatus(
            patterns: ["*.psd"],
            files: [LFSFile(oid: "oid1", path: "art.psd", downloaded: false)]
        )
        snap.stashes = [Stash(
            ref: "stash@{0}", date: Date(timeIntervalSince1970: 1), message: "wip", baseHash: "b"
        )]
        snap.tags = [Tag(name: "v1.0", hash: "b")]
        snap.staged = [FileChange(path: "a.swift", status: "M", area: .staged)]
        snap.unstaged = [FileChange(path: "b.swift", status: "?", area: .unstaged)]
        snap.conflicted = [FileChange(path: "c.swift", status: "U", area: .unstaged)]
        snap.currentBranch = "main"
        snap.operation = .rebase
        snap.mergeMessage = "Merge branch 'x'"
        return snap
    }

    // MARK: - Encoding

    /// Every field the three panes are drawn from has to survive JSON,
    /// including the two that are `Character` in memory and have no JSON
    /// equivalent at all.
    func testSnapshotRoundTripsThroughJSON() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoSnapshot.self, from: data)

        XCTAssertEqual(decoded.commits, original.commits)
        XCTAssertEqual(decoded.activity, original.activity)
        XCTAssertEqual(decoded.localBranches, original.localBranches)
        XCTAssertEqual(decoded.remoteBranches, original.remoteBranches)
        XCTAssertEqual(decoded.remoteNames, ["origin"])
        XCTAssertEqual(decoded.worktrees, original.worktrees)
        XCTAssertEqual(decoded.lfs, original.lfs)
        XCTAssertEqual(decoded.stashes, original.stashes)
        XCTAssertEqual(decoded.tags, original.tags)
        XCTAssertEqual(decoded.currentBranch, "main")
        XCTAssertEqual(decoded.operation, .rebase)
        XCTAssertEqual(decoded.mergeMessage, "Merge branch 'x'")
    }

    /// git's one-letter status codes are the whole meaning of a changed
    /// file's row; a bridge that dropped or blanked them would show every
    /// file as unmodified.
    func testCharacterStatusesSurvive() throws {
        let data = try JSONEncoder().encode(snapshot())
        let decoded = try JSONDecoder().decode(RepoSnapshot.self, from: data)
        XCTAssertEqual(decoded.staged.first?.status, "M")
        XCTAssertEqual(decoded.unstaged.first?.status, "?")
        XCTAssertEqual(decoded.conflicted.first?.status, "U")
        XCTAssertEqual(decoded.submodules.first?.state, "+")
        // The id is built out of the status, so a lost character would also
        // silently break every list's identity.
        XCTAssertEqual(decoded.staged.first?.id, "a.swiftM+s")
    }

    /// The layout is recomputed on the way back in, so storing it would be
    /// bytes spent on something that is thrown away — and a second source of
    /// truth for how the graph looks.
    func testLayoutIsNotStored() throws {
        var original = snapshot()
        original.graphRows = RepoState.graph(
            commits: original.commits, headHash: "a", dirty: false,
            reachable: ["a", "b"], stashes: []
        ).rows
        original.reachableFromHead = ["a", "b"]
        original.brightColors = [0]

        let decoded = try JSONDecoder().decode(
            RepoSnapshot.self, from: JSONEncoder().encode(original)
        )
        XCTAssertTrue(decoded.graphRows.isEmpty)
        XCTAssertTrue(decoded.reachableFromHead.isEmpty)
        XCTAssertTrue(decoded.brightColors.isEmpty)
    }

    // MARK: - Disk

    func testSnapshotSurvivesTheRoundTripToDisk() throws {
        RepoCache.saveSnapshot(snapshot(), path: path)
        let loaded = try XCTUnwrap(RepoCache.loadSnapshot(path: path))
        XCTAssertEqual(loaded.commits.map(\.hash), ["a", "b"])
        XCTAssertEqual(loaded.headBranch?.name, "main")
        XCTAssertEqual(loaded.staged.first?.path, "a.swift")
    }

    /// A refresh that failed leaves an empty snapshot behind for an instant.
    /// Writing it would replace a good cache with nothing to restore.
    func testEmptySnapshotIsNeverWritten() {
        RepoCache.saveSnapshot(snapshot(), path: path)
        RepoCache.saveSnapshot(RepoSnapshot(), path: path)
        XCTAssertEqual(RepoCache.loadSnapshot(path: path)?.commits.count, 2)
    }

    /// Scrolling for more history grows the log window without bound; the
    /// cache keeps a screenful's worth and lets the refresh re-read the rest.
    func testCommitsAreCappedOnTheWayOut() throws {
        var snap = snapshot()
        snap.commits = (0..<(RepoCache.commitLimit + 120)).map { commit("c\($0)") }
        RepoCache.saveSnapshot(snap, path: path)
        let loaded = try XCTUnwrap(RepoCache.loadSnapshot(path: path))
        XCTAssertEqual(loaded.commits.count, RepoCache.commitLimit)
        // The head of the log, not the tail — the newest commits are the
        // ones the graph opens on.
        XCTAssertEqual(loaded.commits.first?.hash, "c0")
    }

    func testSummaryCarriesTheForgeAndItsTTL() throws {
        let loadedAt = Date(timeIntervalSince1970: 1_700_000_000)
        RepoCache.saveSummary(RepoCache.Summary(
            savedAt: Date(),
            card: RepoState.Card(branch: "main", head: "a", ahead: 1, behind: 0, changed: 2),
            cardLoadedAt: loadedAt,
            yearActivity: [20_260_728: 4],
            yearActivityAt: loadedAt,
            forge: .github,
            missingForgeCLI: nil,
            pullRequests: [PullRequest(
                number: 27, title: "Cache", branch: "feat", author: "tao",
                isDraft: false, url: "https://example.com/27"
            )],
            issues: [Issue(
                number: 3, title: "Bug", author: "tao", body: "b",
                url: "https://example.com/3", createdAt: loadedAt,
                labels: [IssueLabel(name: "enhancement", colorHex: "a2eeef")]
            )],
            prsLoadedAt: loadedAt
        ), path: path)

        let loaded = try XCTUnwrap(RepoCache.loadSummary(path: path))
        XCTAssertEqual(loaded.card?.branch, "main")
        XCTAssertEqual(loaded.card?.changed, 2)
        XCTAssertEqual(loaded.yearActivity, [20_260_728: 4])
        XCTAssertEqual(loaded.forge, .github)
        XCTAssertEqual(loaded.pullRequests.first?.number, 27)
        XCTAssertEqual(loaded.issues?.first?.labels.first?.name, "enhancement")
        XCTAssertEqual(loaded.prsLoadedAt, loadedAt)
    }

    /// A fortnight-old graph is not "stale data being revalidated", it's a
    /// picture of a repo that has moved on. Better to show nothing.
    func testAFileOlderThanMaxAgeIsDroppedAndDeleted() throws {
        let dir = try XCTUnwrap(RepoCache.dir)
        let url = dir.appendingPathComponent(RepoCache.name(path, .snapshot))
        let aged = RepoCache.SnapshotFile(
            savedAt: Date(timeIntervalSinceNow: -RepoCache.maxAge - 60),
            snapshot: snapshot()
        )
        try JSONEncoder().encode(aged).write(to: url)

        XCTAssertNil(RepoCache.loadSnapshot(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The file the app writes today has to be unreadable-to-nil rather than
    /// crash whatever shape a future version leaves behind.
    func testGarbageIsDroppedRatherThanTrusted() throws {
        let dir = try XCTUnwrap(RepoCache.dir)
        let url = dir.appendingPathComponent(RepoCache.name(path, .snapshot))
        try Data("{\"not\":\"a snapshot\"}".utf8).write(to: url)
        XCTAssertNil(RepoCache.loadSnapshot(path: path))
    }

    /// Removing a repo from the library removes the copy of its working
    /// tree we were keeping.
    func testForgetRemovesBothFiles() {
        RepoCache.saveSnapshot(snapshot(), path: path)
        RepoCache.saveSummary(RepoCache.Summary(savedAt: Date()), path: path)
        RepoCache.forget(path: path)
        XCTAssertNil(RepoCache.loadSnapshot(path: path))
        XCTAssertNil(RepoCache.loadSummary(path: path))
    }

    /// Two repos with the same folder name are two caches — the path is what
    /// identifies a repo everywhere else in the app, and it has to here too.
    func testSameNameDifferentPathsDoNotCollide() {
        let other = path + "/nested/" + (path as NSString).lastPathComponent
        defer { RepoCache.forget(path: other) }
        var mine = snapshot()
        mine.currentBranch = "mine"
        var theirs = snapshot()
        theirs.currentBranch = "theirs"

        RepoCache.saveSnapshot(mine, path: path)
        RepoCache.saveSnapshot(theirs, path: other)
        XCTAssertEqual(RepoCache.loadSnapshot(path: path)?.currentBranch, "mine")
        XCTAssertEqual(RepoCache.loadSnapshot(path: other)?.currentBranch, "theirs")
    }

    /// A cache that only ever grows is a leak; pruning keeps it to the
    /// repos the library actually lists.
    func testPruneKeepsOnlyTheLibrary() {
        let stranger = path + "-stranger"
        defer { RepoCache.forget(path: stranger) }
        RepoCache.saveSnapshot(snapshot(), path: path)
        RepoCache.saveSnapshot(snapshot(), path: stranger)

        RepoCache.prune(keeping: [path])
        XCTAssertNotNil(RepoCache.loadSnapshot(path: path))
        XCTAssertNil(RepoCache.loadSnapshot(path: stranger))
    }
}
