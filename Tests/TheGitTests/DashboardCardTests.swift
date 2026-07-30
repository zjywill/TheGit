import XCTest
@testable import TheGit

/// The Dashboard's card, against a real repository. Every line on a card is
/// a claim about a repo the user hasn't opened yet — clean vs dirty, ahead
/// vs level, which branch they're standing on — so each one is checked here
/// rather than by looking at a wall of cards and believing it.
@MainActor
final class DashboardCardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-card-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    private func makeRepo(_ name: String, commits: Int = 1) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        for index in 1...max(1, commits) {
            try "line \(index)\n".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
            try await git(path, ["add", "-A"])
            try await git(path, ["commit", "-qm", "commit \(index)"])
        }
        return path
    }

    /// A clean repo the user has never opened: one branch name, no changes,
    /// and its history newest-first.
    func testCleanRepoCard() async throws {
        let path = try await makeRepo("clean", commits: 3)
        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertEqual(card.branch, "main")
        XCTAssertTrue(card.isClean)
        XCTAssertEqual(card.changed, 0)
        XCTAssertEqual(card.commits.map(\.subject), ["commit 3", "commit 2", "commit 1"])
    }

    /// Staged and unstaged edits to one file are one changed file, not two —
    /// the card counts paths, because "2 changed files" for a single file
    /// staged then edited again is a lie the user acts on.
    func testChangedFilesAreCountedByPath() async throws {
        let path = try await makeRepo("dirty")
        try "staged\n".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
        try await git(path, ["add", "-A"])
        try "staged then edited again\n".write(
            toFile: path + "/file.txt", atomically: true, encoding: .utf8
        )
        try "untracked\n".write(toFile: path + "/new.txt", atomically: true, encoding: .utf8)

        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertFalse(card.isClean)
        XCTAssertEqual(card.changed, 2) // file.txt + new.txt
        XCTAssertEqual(card.conflicted, 0)
    }

    /// Ahead of the upstream, read off `git status`'s own branch header —
    /// this is what puts the ↑ on a card without a third subprocess.
    func testAheadAndBehindComeFromStatus() async throws {
        let origin = try await makeRepo("origin", commits: 1)
        let clonePath = root.appendingPathComponent("clone").path
        try await Shell.run(
            "/usr/bin/env",
            ["git", "clone", "-q", origin, clonePath],
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
        try "local work\n".write(toFile: clonePath + "/local.txt", atomically: true, encoding: .utf8)
        try await git(clonePath, ["add", "-A"])
        try await git(clonePath, ["commit", "-qm", "local"])

        let repo = RepoState(path: clonePath)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertEqual(card.ahead, 1)
        XCTAssertEqual(card.behind, 0)
        XCTAssertTrue(card.isClean)
    }

    /// Detached HEAD has no branch to name, so the card falls back to the
    /// sha — the one state where "no branch" must not read as "unknown".
    func testDetachedHeadCard() async throws {
        let path = try await makeRepo("detached", commits: 2)
        let head = try await git(path, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(path, ["checkout", "-q", "--detach", head])

        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertNil(card.branch)
        XCTAssertEqual(card.head, head)
    }

    /// A repo with no commits at all: a card, not a failure, and not a
    /// plausible-looking empty history either.
    func testFreshRepoHasNoCommitsButStillHasACard() async throws {
        let path = root.appendingPathComponent("fresh").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])

        let repo = RepoState(path: path)
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertEqual(card.branch, "main")
        XCTAssertTrue(card.commits.isEmpty)
        XCTAssertNil(card.head)
    }

    /// A repo whose tab is already open answers from the snapshot it has,
    /// with no git calls of its own — and must answer the same thing.
    func testVisitedRepoCardMatchesTheSnapshot() async throws {
        let path = try await makeRepo("visited", commits: 2)
        let repo = RepoState(path: path)
        await repo.refresh()
        await repo.loadCard()

        let card = try XCTUnwrap(repo.card)
        XCTAssertEqual(card.branch, "main")
        XCTAssertEqual(card.commits.map(\.subject), ["commit 2", "commit 1"])
        XCTAssertTrue(card.isClean)
    }
}
