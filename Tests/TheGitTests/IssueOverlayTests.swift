import XCTest
@testable import TheGit

/// The centre pane has one overlay slot: an issue, a diff, or a file
/// history — never two stacked, where the lower one looks open but is
/// unreachable behind the other.
final class IssueOverlayTests: XCTestCase {
    private func makeIssue(_ number: Int) -> Issue {
        Issue(number: number, title: "t", author: "a", body: "", url: "", createdAt: nil)
    }

    @MainActor
    func testOpeningIssueClosesDiff() {
        let repo = RepoState(path: "/nonexistent/for-state-test")
        // Untracked file: the diff is synthesized from disk, no git run.
        repo.selectFile(FileChange(path: "a.txt", status: "?", area: .unstaged))
        XCTAssertNotNil(repo.selectedFile)

        repo.viewIssue(makeIssue(7))
        XCTAssertEqual(repo.issueToView?.number, 7)
        XCTAssertNil(repo.selectedFile)
        XCTAssertNil(repo.fileHistory)
    }

    @MainActor
    func testOpeningDiffClosesIssue() {
        let repo = RepoState(path: "/nonexistent/for-state-test")
        repo.viewIssue(makeIssue(7))
        XCTAssertNotNil(repo.issueToView)

        repo.selectFile(FileChange(path: "a.txt", status: "?", area: .unstaged))
        XCTAssertNil(repo.issueToView)
        XCTAssertNotNil(repo.selectedFile)
    }

    @MainActor
    func testOpeningIssueClosesPullRequestReview() {
        let repo = RepoState(path: "/nonexistent/for-state-test")
        repo.viewPullRequest(PullRequest(
            number: 3, title: "t", branch: "b", author: "a", isDraft: false, url: ""))
        XCTAssertNotNil(repo.prToView)

        repo.viewIssue(makeIssue(7))
        XCTAssertEqual(repo.issueToView?.number, 7)
        // Both set means both drawn, one on top of the other — the panel
        // the user asked for is the one behind.
        XCTAssertNil(repo.prToView)
    }

    @MainActor
    func testSwitchingIssuesKeepsSlotOnIssues() {
        let repo = RepoState(path: "/nonexistent/for-state-test")
        repo.viewIssue(makeIssue(1))
        repo.viewIssue(makeIssue(2))
        XCTAssertEqual(repo.issueToView?.number, 2)
    }
}
