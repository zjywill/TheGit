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

    // MARK: - Issue count

    /// The count is the array's length and nothing else — gh's shape and
    /// glab's shape count the same, and a stray banner line before the
    /// JSON is skipped like `pullRequests` skips it.
    func testListCountAcrossCLIShapes() {
        XCTAssertEqual(ForgeParsers.listCount(#"[{"number":1},{"number":7}]"#), 2)
        XCTAssertEqual(
            ForgeParsers.listCount(#"Showing 1 of 1\n[{"iid":3,"title":"t","web_url":"u"}]"#),
            1
        )
        XCTAssertEqual(ForgeParsers.listCount("[]"), 0)
        // No JSON at all — a CLI that printed only chatter — is zero, not
        // a crash: the badge simply stays off.
        XCTAssertEqual(ForgeParsers.listCount("no issues match"), 0)
        XCTAssertEqual(ForgeParsers.listCount(""), 0)
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
