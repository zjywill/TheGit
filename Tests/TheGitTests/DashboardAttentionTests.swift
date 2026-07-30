import XCTest
@testable import TheGit

/// The card's two new badges: the idle marker and the PR count. Each is a
/// claim the user acts on without opening the repo, so each is pinned
/// here — including the boundaries, because "a month idle" drifting to 29
/// or 31 days is invisible on a wall of cards until it flags the wrong
/// repo.
@MainActor
final class DashboardAttentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-attention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ dir: String, _ args: [String], env: [String: String] = [:]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"].merging(env) { _, new in new }
        )
    }

    private func makeRepo(_ name: String, commitDaysAgo: Int? = 0) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        if let days = commitDaysAgo {
            // The card reads %at, the author timestamp — so the author
            // date is the one to fake.
            let date = ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-Double(days) * 86_400)
            )
            try "content\n".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
            try await git(path, ["add", "-A"])
            try await git(
                path, ["commit", "-qm", "commit", "--date", date],
                env: ["GIT_COMMITTER_DATE": date]
            )
        }
        return path
    }

    // MARK: - Stale, pure

    private func card(daysAgo: Double?) -> RepoState.Card {
        var card = RepoState.Card()
        if let daysAgo {
            card.commits = [Commit(
                hash: "a", parents: [], author: "t",
                date: Date().addingTimeInterval(-daysAgo * 86_400),
                refs: [], subject: "s"
            )]
        }
        return card
    }

    /// The boundary itself: 29 days is quiet, 31 is stale. Checked as pure
    /// arithmetic so the cutoff can't drift with a refactor.
    func testStaleBoundary() {
        XCTAssertFalse(card(daysAgo: 29).isStale())
        XCTAssertTrue(card(daysAgo: 31).isStale())
    }

    /// No commits is a brand-new repo, which is the opposite of abandoned.
    func testEmptyHistoryIsNotStale() {
        XCTAssertFalse(card(daysAgo: nil).isStale())
    }

    // MARK: - Stale, against a real repo

    /// The card built by `loadCard` carries a date old enough to flag —
    /// i.e. the %at the log format reads is the date the test faked.
    func testMonthOldRepoCardIsStale() async throws {
        let path = try await makeRepo("old", commitDaysAgo: 40)
        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertTrue(card.isStale())
    }

    /// A clean repo committed to today: no idle badge.
    func testFreshRepoCardIsNotStale() async throws {
        let path = try await makeRepo("fresh")
        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertFalse(card.isStale())
    }

    // MARK: - PR count

    /// Before anyone has asked a forge anything, the count must be nil —
    /// unknown — never a confident 0 the badge would then suppress as
    /// "none open".
    func testPRCountIsUnknownUntilLoaded() async throws {
        let repo = RepoState(path: try await makeRepo("noforge"))
        await repo.loadCard()
        XCTAssertNil(repo.knownOpenPRCount)
        XCTAssertNil(repo.openIssueCount)
    }

    /// The Dashboard's forge path for a repo whose tab was never opened:
    /// no snapshot, so the remotes come from git itself.
    func testRemotesComeFromGitWithoutASnapshot() async throws {
        let path = try await makeRepo("remotes")
        try await git(path, ["remote", "add", "upstream", "https://example.com/o/r.git"])
        try await git(path, ["remote", "add", "origin", "https://example.com/o/r.git"])

        let repo = RepoState(path: path)
        let names = try await repo.git.remotes()
        XCTAssertEqual(Set(names), ["origin", "upstream"])
    }
}
