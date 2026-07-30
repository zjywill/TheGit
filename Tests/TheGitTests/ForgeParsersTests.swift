import XCTest
@testable import TheGit

final class ForgeParsersTests: XCTestCase {

    // MARK: - Remote URL → host → forge

    func testHostFromEveryRemoteURLForm() {
        XCTAssertEqual(ForgeParsers.host(of: "git@github.com:zjywill/TheGit.git"), "github.com")
        XCTAssertEqual(ForgeParsers.host(of: "https://github.com/zjywill/TheGit.git"), "github.com")
        XCTAssertEqual(ForgeParsers.host(of: "ssh://git@gitlab.com/group/app"), "gitlab.com")
        XCTAssertEqual(ForgeParsers.host(of: "https://user@gitlab.example.com/g/a"), "gitlab.example.com")
        // Trailing newline: `git remote get-url` output pasted verbatim.
        XCTAssertEqual(ForgeParsers.host(of: "git@github.com:o/r.git\n"), "github.com")
    }

    func testForgeSelection() {
        XCTAssertEqual(ForgeParsers.forge(forHost: "github.com"), .github)
        XCTAssertEqual(ForgeParsers.forge(forHost: "GitHub.MyCorp.com"), .github)
        XCTAssertEqual(ForgeParsers.forge(forHost: "gitlab.internal.net"), .gitlab)
        // Unknown host: no CLI can be assumed, so the feature stays off.
        XCTAssertNil(ForgeParsers.forge(forHost: "bitbucket.org"))
        XCTAssertNil(ForgeParsers.forge(forHost: "git.sr.ht"))
    }

    // MARK: - Created PR/MR URL

    func testWebURLOutOfCreateOutput() {
        // gh: chatter on stderr, the URL alone on stdout's last line.
        XCTAssertEqual(
            ForgeParsers.webURL(in: "\nhttps://github.com/o/r/pull/12\n"),
            "https://github.com/o/r/pull/12"
        )
        // glab: a human summary first, then the URL.
        XCTAssertEqual(
            ForgeParsers.webURL(in: "!42 Fix crash (feature/x)\nhttps://gitlab.com/g/a/-/merge_requests/42"),
            "https://gitlab.com/g/a/-/merge_requests/42"
        )
        // A URL mentioned mid-sentence is not the created page.
        XCTAssertNil(ForgeParsers.webURL(in: "Creating merge request for feature/x into main"))
        XCTAssertNil(ForgeParsers.webURL(in: ""))
    }

    // MARK: - gh

    /// Verbatim shape of `gh pr list --json number,title,headRefName,author,isDraft,url`.
    func testParseGitHubList() throws {
        let json = """
        [{"author":{"id":"MDQ6","is_bot":false,"login":"offbyone","name":"Chris Rose"},\
        "headRefName":"o1/add-flags","isDraft":false,"number":13969,"state":"OPEN",\
        "title":"Add --latest-pre-release","url":"https://github.com/cli/cli/pull/13969"},\
        {"author":{"id":"MDQ6","is_bot":false,"login":"tommaso","name":"T M"},\
        "headRefName":"fix-wrap","isDraft":true,"number":13967,"state":"OPEN",\
        "title":"Fix skill picker label wrapping","url":"https://github.com/cli/cli/pull/13967"}]
        """
        let prs = try ForgeParsers.pullRequests(json, forge: .github)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].number, 13969)
        XCTAssertEqual(prs[0].branch, "o1/add-flags")
        XCTAssertEqual(prs[0].author, "offbyone")
        XCTAssertFalse(prs[0].isDraft)
        XCTAssertEqual(prs[0].url, "https://github.com/cli/cli/pull/13969")
        XCTAssertTrue(prs[1].isDraft)
    }

    func testEmptyListsAndNoOutput() throws {
        XCTAssertEqual(try ForgeParsers.pullRequests("[]", forge: .github).count, 0)
        // A CLI that prints nothing at all is an empty list, not an error.
        XCTAssertEqual(try ForgeParsers.pullRequests("", forge: .gitlab).count, 0)
        XCTAssertEqual(try ForgeParsers.pullRequests("\n", forge: .github).count, 0)
    }

    func testBannerBeforeJSONIsSkipped() throws {
        let out = "Showing 1 open pull request\n\n[{\"number\":7,\"title\":\"t\"," +
            "\"headRefName\":\"b\",\"isDraft\":false,\"url\":\"u\",\"author\":{\"login\":\"me\"}}]"
        let prs = try ForgeParsers.pullRequests(out, forge: .github)
        XCTAssertEqual(prs.map(\.number), [7])
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try ForgeParsers.pullRequests("[{\"number\":", forge: .github))
    }

    // MARK: - glab

    /// GitLab's REST shape: `iid` is the user-visible !number, and the
    /// draft flag has been spelled two different ways across versions.
    func testParseGitLabList() throws {
        let json = """
        [{"iid":42,"id":99001,"title":"Add search","source_branch":"feature/search",\
        "author":{"username":"junyi"},"draft":false,\
        "web_url":"https://gitlab.com/g/a/-/merge_requests/42"},\
        {"iid":43,"id":99002,"title":"WIP thing","source_branch":"wip",\
        "author":{"username":"other"},"work_in_progress":true,\
        "web_url":"https://gitlab.com/g/a/-/merge_requests/43"}]
        """
        let mrs = try ForgeParsers.pullRequests(json, forge: .gitlab)
        XCTAssertEqual(mrs.map(\.number), [42, 43])
        XCTAssertEqual(mrs[0].branch, "feature/search")
        XCTAssertEqual(mrs[0].author, "junyi")
        XCTAssertFalse(mrs[0].isDraft)
        // Older glab: only work_in_progress is present.
        XCTAssertTrue(mrs[1].isDraft)
    }

    /// Missing optional fields degrade the row instead of failing the list.
    func testGitLabToleratesMissingFields() throws {
        let mrs = try ForgeParsers.pullRequests("[{\"iid\":1,\"title\":\"bare\"}]", forge: .gitlab)
        XCTAssertEqual(mrs.count, 1)
        XCTAssertEqual(mrs[0].branch, "")
        XCTAssertEqual(mrs[0].author, "")
        XCTAssertFalse(mrs[0].isDraft)
    }

    // MARK: - Failures

    private func summary(_ stderr: String, forge: Forge = .gitlab, host: String? = "gitlab.acme.com") -> String {
        ForgeFailure.describe(
            ShellError(command: "glab mr list", message: stderr),
            forge: forge,
            host: host
        ).summary
    }

    /// The VPN-is-off case: glab hands back a Go networking sentence, and
    /// the row has to say the one thing the user can act on.
    func testOfflineFailuresNameTheHost() {
        let offline = [
            "ERROR: Get \"https://gitlab.acme.com/api/v4/projects\": dial tcp: lookup gitlab.acme.com: no such host\n",
            "Get \"https://gitlab.acme.com/api/v4/user\": net/http: TLS handshake timeout",
            "ERROR: Get \"https://gitlab.acme.com\": dial tcp 10.0.0.1:443: i/o timeout",
            "error: connection refused",
        ]
        for stderr in offline {
            XCTAssertEqual(
                summary(stderr),
                "Can't reach gitlab.acme.com — check your network or VPN.",
                stderr
            )
        }
    }

    func testAuthFailureNamesTheLoginCommand() {
        XCTAssertEqual(
            summary("ERROR: 401 Unauthorized"),
            "Not signed in to gitlab.acme.com — run `glab auth login`."
        )
        XCTAssertEqual(
            summary("gh: Not authenticated. Run gh auth login", forge: .github, host: "github.com"),
            "Not signed in to github.com — run `gh auth login`."
        )
    }

    /// Anything we don't recognise keeps the CLI's own first line rather
    /// than being guessed at — minus the shouting, and minus the rest of
    /// the stack trace no sidebar row can hold.
    func testUnknownFailureQuotesTheFirstLine() {
        XCTAssertEqual(
            summary("ERROR: project not found\nrun `glab repo view` for details\n"),
            "project not found"
        )
        XCTAssertEqual(summary("glab is not installed."), "glab is not installed.")
        XCTAssertLessThanOrEqual(summary(String(repeating: "x", count: 400)).count, 140)
    }

    // MARK: - Issues

    /// Verbatim shape of `gh issue list --json number,title,author,url,body,createdAt`.
    func testParseGitHubIssueList() throws {
        let json = """
        [{"author":{"id":"MDQ6","is_bot":false,"login":"zjywill","name":"Junyi"},\
        "body":"## 现状\\n只有内置的 FileDiffView","createdAt":"2026-07-27T06:11:28Z",\
        "number":16,"title":"外部 diff / merge tool 集成",\
        "url":"https://github.com/zjywill/TheGit/issues/16"}]
        """
        let issues = try ForgeParsers.issues(json, forge: .github)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].number, 16)
        XCTAssertEqual(issues[0].author, "zjywill")
        XCTAssertTrue(issues[0].body.hasPrefix("## 现状"))
        XCTAssertNotNil(issues[0].createdAt)
        // No JSON at all — a CLI that printed only chatter — is an empty
        // list, not a crash: the section just shows nothing.
        XCTAssertEqual(try ForgeParsers.issues("no issues match", forge: .github), [])
    }

    /// GitLab's REST shape through `glab issue list --output json` —
    /// fractional-second timestamps included, which its API writes and
    /// plain ISO 8601 parsing rejects.
    func testParseGitLabIssueList() throws {
        let json = """
        [{"iid":7,"id":991,"title":"Crash on open","description":"steps to reproduce",\
        "author":{"username":"tao"},"web_url":"https://gitlab.com/g/a/-/issues/7",\
        "created_at":"2026-07-01T10:30:00.123Z"}]
        """
        let issues = try ForgeParsers.issues(json, forge: .gitlab)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].number, 7)
        XCTAssertEqual(issues[0].body, "steps to reproduce")
        XCTAssertEqual(issues[0].url, "https://gitlab.com/g/a/-/issues/7")
        XCTAssertNotNil(issues[0].createdAt)
    }

    /// `gh issue view N --json comments` keeps the envelope even for one
    /// field; the comments inside it are the thread, oldest first.
    func testParseGitHubIssueComments() throws {
        let json = """
        {"comments":[{"id":"IC_kwDO","author":{"login":"zjywill"},\
        "authorAssociation":"OWNER","body":"对着代码核了一遍","createdAt":"2026-07-27T06:19:35Z",\
        "isMinimized":false,"reactionGroups":[],"viewerDidAuthor":false}]}
        """
        let comments = try ForgeParsers.issueComments(json, forge: .github)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].author, "zjywill")
        XCTAssertEqual(comments[0].body, "对着代码核了一遍")
    }

    /// GitLab notes arrive as a flat array with system events mixed in —
    /// "changed the description" is history, not conversation, and must
    /// not render as a comment card.
    func testGitLabNotesFilterSystemEvents() throws {
        let json = """
        [{"id":1,"body":"changed the description","system":true,\
        "author":{"username":"tao"},"created_at":"2026-07-01T10:30:00.000Z"},\
        {"id":2,"body":"I can reproduce this","system":false,\
        "author":{"username":"alice"},"created_at":"2026-07-02T11:00:00.000Z"}]
        """
        let comments = try ForgeParsers.issueComments(json, forge: .gitlab)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].author, "alice")
        XCTAssertEqual(comments[0].body, "I can reproduce this")
    }

    /// Both timestamp spellings parse; garbage is nil, not a thrown list.
    func testForgeDateSpellings() {
        XCTAssertNotNil(ForgeParsers.date("2026-07-27T06:11:28Z"))
        XCTAssertNotNil(ForgeParsers.date("2026-07-27T06:11:28.123Z"))
        XCTAssertNil(ForgeParsers.date("yesterday"))
        XCTAssertNil(ForgeParsers.date(nil))
    }

    /// The tooltip keeps the command that failed; the summary never does.
    func testDetailKeepsTheCommandContext() {
        let failure = ForgeFailure.describe(
            ShellError(command: "glab mr list", message: "ERROR: 401 Unauthorized"),
            forge: .gitlab,
            host: "gitlab.acme.com"
        )
        XCTAssertTrue(failure.detail.hasPrefix("glab mr list: "))
        XCTAssertFalse(failure.summary.contains("glab mr list"))
        XCTAssertTrue(failure.alertText.contains(failure.summary))
        XCTAssertTrue(failure.alertText.contains(failure.detail))
    }
}
