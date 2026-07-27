import XCTest
@testable import TheGit

final class CleanupTests: XCTestCase {

    // MARK: - worktree porcelain

    /// Verbatim `git worktree list --porcelain` with a stale entry —
    /// the reason text after "prunable" varies by git version.
    func testParsePrunableWorktree() {
        let output = """
        worktree /Users/me/repo
        HEAD 9c87ff5a9f5d516e8c4bc6c5569b1f86f06f7fa0
        branch refs/heads/main

        worktree /Users/me/wt-stale
        HEAD 9c87ff5a9f5d516e8c4bc6c5569b1f86f06f7fa0
        branch refs/heads/stale-wt
        prunable gitdir file points to non-existent location

        """
        let worktrees = GitParsers.parseWorktrees(output)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertFalse(worktrees[0].prunable)
        XCTAssertTrue(worktrees[1].prunable)
        XCTAssertEqual(worktrees[1].branch, "stale-wt")
        // The flag must not leak into the next entry.
        XCTAssertFalse(worktrees[0].locked)
    }

    func testParseLockedAndBareFlags() {
        let output = """
        worktree /Users/me/wt-a
        HEAD abc
        branch refs/heads/a
        locked

        worktree /Users/me/wt-b
        HEAD def
        branch refs/heads/b

        """
        let worktrees = GitParsers.parseWorktrees(output)
        XCTAssertTrue(worktrees[0].locked)
        XCTAssertFalse(worktrees[1].locked)
        XCTAssertFalse(worktrees[1].prunable)
    }

    // MARK: - candidate safety

    /// Merged work is provably elsewhere, so it cleans in one click.
    func testMergedBranchIsSafe() {
        let candidate = CleanupCandidate(
            target: .branch(name: "feature/x", tip: "abc1234"),
            reason: .squashMerged(into: "main")
        )
        XCTAssertTrue(candidate.isSafe)
        XCTAssertNil(candidate.riskText)
        XCTAssertEqual(candidate.reasonText, "squash-merged into main")
    }

    /// An orphaned branch with commits of its own must ask first.
    func testStrandedCommitsMakeItRisky() {
        var candidate = CleanupCandidate(
            target: .branch(name: "old/experiment", tip: "def5678"),
            reason: .upstreamGone("origin/old/experiment")
        )
        candidate.strandedCommits = 3
        XCTAssertFalse(candidate.isSafe)
        XCTAssertEqual(candidate.riskText, "3 commits only here")
        XCTAssertEqual(candidate.reasonText, "origin/old/experiment deleted")
    }

    func testSingleStrandedCommitIsSingular() {
        var candidate = CleanupCandidate(
            target: .branch(name: "b", tip: "a"),
            reason: .upstreamGone("origin/b")
        )
        candidate.strandedCommits = 1
        XCTAssertEqual(candidate.riskText, "1 commit only here")
    }

    /// An upstream that vanished while everything was already merged is
    /// still safe — the reason is weaker, but nothing is at stake.
    func testGoneUpstreamWithNothingStrandedIsSafe() {
        let candidate = CleanupCandidate(
            target: .branch(name: "b", tip: "a"),
            reason: .upstreamGone("origin/b")
        )
        XCTAssertTrue(candidate.isSafe)
        XCTAssertNil(candidate.riskText)
    }

    /// Pruning a vanished worktree touches metadata only; removing a real
    /// one deletes a folder, so only the first is one-click.
    func testWorktreeSafetySplit() {
        let gone = CleanupCandidate(
            target: .worktree(path: "/tmp/wt", prunable: true),
            reason: .worktreeGone
        )
        XCTAssertTrue(gone.isSafe)
        XCTAssertNil(gone.riskText)
        XCTAssertEqual(gone.name, "wt")
        XCTAssertTrue(gone.isWorktree)

        let onDisk = CleanupCandidate(
            target: .worktree(path: "/tmp/wt2", prunable: false),
            reason: .merged(into: "main")
        )
        XCTAssertFalse(onDisk.isSafe)
        XCTAssertEqual(onDisk.riskText, "deletes the folder on disk")
    }

    func testPullRequestReasonUsesForgePrefix() {
        let github = CleanupCandidate(
            target: .branch(name: "b", tip: "a"),
            reason: .mergedPullRequest(number: 42, prefix: "#")
        )
        XCTAssertEqual(github.reasonText, "#42 merged")
        let gitlab = CleanupCandidate(
            target: .branch(name: "b", tip: "a"),
            reason: .mergedPullRequest(number: 42, prefix: "!")
        )
        XCTAssertEqual(gitlab.reasonText, "!42 merged")
    }
}
