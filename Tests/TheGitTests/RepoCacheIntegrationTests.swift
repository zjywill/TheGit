import XCTest
@testable import TheGit

/// The whole point of the cache, end to end against a real repository: a
/// second launch draws the first launch's panes before git is asked
/// anything. Unit tests can prove the file round-trips; only this can prove
/// the app actually writes and reads it.
@MainActor
final class RepoCacheIntegrationTests: XCTestCase {

    private var root: URL!
    private var cacheDir: URL!
    private var realCacheDir: URL?

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-cache-it-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        realCacheDir = RepoCache.dir
        RepoCache.dir = cacheDir
    }

    override func tearDownWithError() throws {
        RepoCache.dir = realCacheDir
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ dir: String, _ args: [String]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    private func makeRepo(_ name: String) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        try "seed\n".write(toFile: path + "/seed.txt", atomically: true, encoding: .utf8)
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "init"])
        return path
    }

    private func waitForCacheFile(_ path: String) async throws {
        let url = try XCTUnwrap(RepoCache.dir)
            .appendingPathComponent(RepoCache.name(path, .snapshot))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for the snapshot to be written")
    }

    /// The round trip the user sees: work in a repo, quit, come back to the
    /// same graph — commits, branch, tags and all — without a git command
    /// having run yet.
    func testASecondLaunchDrawsTheFirstLaunchesPanes() async throws {
        let path = try await makeRepo("relaunch")
        try await git(path, ["tag", "v1.0"])

        let first = RepoState(path: path)
        await first.refresh()
        let commits = first.snapshot.commits.map(\.hash)
        XCTAssertFalse(commits.isEmpty)
        first.flushCache()
        try await waitForCacheFile(path)

        // A brand new object, exactly as a relaunch builds it.
        let second = RepoState(path: path)
        XCTAssertTrue(second.snapshot.commits.isEmpty)
        await second.appeared()

        XCTAssertEqual(second.snapshot.commits.map(\.hash), commits)
        XCTAssertEqual(second.snapshot.currentBranch, "main")
        XCTAssertEqual(second.snapshot.tags.map(\.name), ["v1.0"])
        // Rebuilt on the way in rather than stored — a restored graph has to
        // be a drawn graph, not an empty middle pane.
        XCTAssertEqual(second.snapshot.graphRows.count, second.snapshot.commits.count)
        XCTAssertEqual(second.snapshot.reachableFromHead, first.snapshot.reachableFromHead)
    }

    /// Stale-while-revalidate, not stale-and-leave-it: what the cache put on
    /// screen is replaced by whatever git says a moment later.
    func testTheRefreshBehindTheRestoredPanesWins() async throws {
        let path = try await makeRepo("revalidate")
        let first = RepoState(path: path)
        await first.refresh()
        first.flushCache()
        try await waitForCacheFile(path)

        // Something happened while the app was closed.
        try await git(path, ["checkout", "-qb", "feature"])
        try "more\n".write(toFile: path + "/next.txt", atomically: true, encoding: .utf8)
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "second"])

        let second = RepoState(path: path)
        await second.appeared()
        XCTAssertEqual(second.snapshot.currentBranch, "feature")
        XCTAssertEqual(second.snapshot.commits.count, 2)
    }

    /// The spinner is the thing being removed. A repo with nothing cached
    /// still gets one — an empty window with no indicator reads as broken.
    func testOnlyAnUncachedRepoGoesBusy() async throws {
        let path = try await makeRepo("busy")
        let cold = RepoState(path: path)
        var sawBusy = false
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                if cold.isBusy { sawBusy = true; return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await cold.appeared()
        watching.cancel()
        XCTAssertTrue(sawBusy, "a first-ever load has nothing to show and must say so")

        cold.flushCache()
        try await waitForCacheFile(path)

        let warm = RepoState(path: path)
        var warmWentBusy = false
        let watchingWarm = Task { @MainActor in
            while !Task.isCancelled {
                if warm.isBusy { warmWentBusy = true; return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await warm.appeared()
        watchingWarm.cancel()
        XCTAssertFalse(warmWentBusy, "a restored repo has content on screen the whole time")
    }

    /// The Dashboard's half: a card and a year of commits, so a wall of
    /// repos doesn't spend its first second saying "Reading…".
    func testTheWallIsDrawnFromTheSummary() async throws {
        let path = try await makeRepo("wall")
        let first = RepoState(path: path)
        await first.loadCard()
        _ = await first.yearActivity()
        first.flushCache()
        let summaryURL = try XCTUnwrap(RepoCache.dir)
            .appendingPathComponent(RepoCache.name(path, .summary))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: summaryURL.path) {
            try await Task.sleep(for: .milliseconds(100))
        }

        let second = RepoState(path: path)
        XCTAssertNil(second.card)
        await second.hydrateSummary()
        XCTAssertEqual(second.card?.branch, "main")
        XCTAssertEqual(second.card?.commits.count, 1)
        XCTAssertEqual(second.cachedYearActivity, first.cachedYearActivity)
    }
}
