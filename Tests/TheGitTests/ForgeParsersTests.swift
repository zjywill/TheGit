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
}
