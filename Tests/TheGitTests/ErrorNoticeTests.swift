import XCTest
@testable import TheGit

/// What a toast may show and what it must keep. The strip has one line, so
/// everything these tests are about is which line that is.
final class ErrorNoticeTests: XCTestCase {
    /// The command is context, not the message — it goes in its own field, so
    /// the sentence gets the width.
    func testGitFailureSplitsTheCommandOffTheSentence() {
        let notice = ErrorNotice(GitError(
            command: "log --date-order --branches --remotes --tags HEAD -n 500",
            message: "fatal: cannot change to '/Users/x/gone': No such file or directory\n"
        ))
        XCTAssertEqual(
            notice.summary,
            "cannot change to '/Users/x/gone': No such file or directory"
        )
        XCTAssertEqual(notice.command, "git log --date-order --branches --remotes --tags HEAD -n 500")
        // Copy hands over the whole thing, command included: that is what
        // gets pasted into an issue.
        XCTAssertEqual(
            notice.detail,
            "git log --date-order --branches --remotes --tags HEAD -n 500: "
                + "fatal: cannot change to '/Users/x/gone': No such file or directory\n"
        )
    }

    /// Only the first line survives on screen — git's hints ("use --force")
    /// are several lines long and the strip is not where they get read.
    func testOnlyTheFirstMeaningfulLineReachesTheSummary() {
        let notice = ErrorNotice(GitError(
            command: "push origin main",
            message: "\nerror: failed to push some refs\nhint: Updates were rejected\n"
        ))
        XCTAssertEqual(notice.summary, "failed to push some refs")
        XCTAssertTrue(notice.detail.contains("hint: Updates were rejected"))
    }

    /// A failed push opens with "To github.com:…" and doesn't say `error:`
    /// until line three — the strip shows the error, not the address label.
    func testPushFailureSurfacesTheErrorLineNotTheRemoteHeader() {
        let notice = ErrorNotice(GitError(
            command: "push",
            message: """
            To github.com:zjywill/TheGit.git
             ! [rejected]        main -> main (fetch first)
            error: failed to push some refs to 'github.com:zjywill/TheGit.git'
            hint: Updates were rejected because the remote contains work that you do
            hint: not have locally.
            """
        ))
        XCTAssertEqual(
            notice.summary,
            "failed to push some refs to 'github.com:zjywill/TheGit.git'"
        )
        // The verdict says what git refused; the status line says why.
        XCTAssertEqual(notice.reason, "! [rejected] main -> main (fetch first)")
        // The narration still matters to a bug report — Copy keeps it all.
        XCTAssertTrue(notice.detail.contains("hint: Updates were rejected"))
    }

    /// SSH failures put the cause ABOVE the verdict: "Permission denied"
    /// arrives before the `fatal:` line. The verdict still leads, but the
    /// cause comes along.
    func testAuthFailureCarriesThePermissionLineAsTheReason() {
        let notice = ErrorNotice(GitError(
            command: "push",
            message: """
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.
            """
        ))
        XCTAssertEqual(notice.summary, "Could not read from remote repository.")
        XCTAssertEqual(notice.reason, "git@github.com: Permission denied (publickey).")
    }

    /// A failure that was one line stays one line — no reason row inventing
    /// context that isn't there.
    func testOneLineFailureHasNoReason() {
        let notice = ErrorNotice(GitError(
            command: "checkout nope",
            message: "error: pathspec 'nope' did not match any file(s) known to git\n"
        ))
        XCTAssertNil(notice.reason)
    }

    /// Our own sentences arrive whole and stay whole.
    func testPlainTextNoticeHasNoCommand() {
        let notice = ErrorNotice(text: "Nothing is staged to describe.")
        XCTAssertEqual(notice.summary, "Nothing is staged to describe.")
        XCTAssertNil(notice.command)
        XCTAssertEqual(notice.detail, "Nothing is staged to describe.")
    }

    /// Two reports of the same failure are two pieces of news: the toast has
    /// to re-enter and its timer has to restart, and both are keyed on this.
    func testEachReportIsItsOwnNotice() {
        let first = ErrorNotice(text: "same words")
        let second = ErrorNotice(text: "same words")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)
    }

    /// A wall of text can't widen the strip.
    func testSummaryIsClipped() {
        let notice = ErrorNotice(text: String(repeating: "x", count: 400))
        XCTAssertLessThanOrEqual(notice.summary.count, 140)
        XCTAssertTrue(notice.summary.hasSuffix("…"))
        XCTAssertEqual(notice.detail.count, 400)
    }

    /// The string way in stays a drop-in for the old `errorMessage`: assigning
    /// raises a notice, and reading back still answers "did anything fail".
    @MainActor
    func testErrorMessageShimRoundTrips() {
        let repo = RepoState(path: "/tmp/does-not-matter")
        XCTAssertNil(repo.errorMessage)
        repo.errorMessage = "fatal: bad revision"
        XCTAssertEqual(repo.errorMessage, "fatal: bad revision")
        XCTAssertEqual(repo.errorNotice?.summary, "bad revision")
        repo.errorMessage = nil
        XCTAssertNil(repo.errorNotice)
    }
}
