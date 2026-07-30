import XCTest

@testable import TheGit

/// The prompt is the product here — it's the only thing the app actually
/// says to the agent, and nobody sees it before it runs.
final class HandoffTests: XCTestCase {
    private let pr = PullRequest(
        number: 12,
        title: "Cache the repo summary",
        branch: "feature/cache",
        author: "tao",
        isDraft: false,
        url: "https://github.com/o/r/pull/12"
    )

    private let issue = Issue(
        number: 11,
        title: "Sidebar loses its scroll position",
        author: "tao",
        body: "Scroll down, switch tabs, come back.",
        url: "https://github.com/o/r/issues/11",
        createdAt: nil
    )

    // MARK: - Prompts

    func testPullRequestPromptsNameTheItemAndItsCLI() {
        for task in HandoffTask.forPullRequests {
            let prompt = Handoff.prompt(task, subject: .init(pr), forge: .github, base: "main")
            XCTAssertTrue(prompt.contains("#12"), "\(task) should say which PR")
            XCTAssertTrue(prompt.contains(pr.title), "\(task) should quote the title")
            XCTAssertTrue(prompt.contains(pr.url), "\(task) should carry the URL")
            XCTAssertTrue(prompt.contains("gh pr"), "\(task) should tell it how to read the PR")
        }
    }

    func testIssuePromptsNameTheItemAndItsCLI() {
        for task in HandoffTask.forIssues {
            let prompt = Handoff.prompt(task, subject: .init(issue), forge: .github, base: "main")
            XCTAssertTrue(prompt.contains("#11"), "\(task) should say which issue")
            XCTAssertTrue(prompt.contains(issue.title), "\(task) should quote the title")
            XCTAssertTrue(prompt.contains("gh issue view 11 --comments"), "\(task) should read the thread")
        }
    }

    /// GitLab's CLI is a different binary with different subcommands and a
    /// different number prefix — a prompt telling `glab` to run `gh pr` is
    /// a handoff that dies on its first command.
    func testGitLabPromptsSpeakGlab() {
        let prompt = Handoff.prompt(.review, subject: .init(pr), forge: .gitlab, base: "main")
        XCTAssertTrue(prompt.contains("glab mr view 12 --comments"))
        XCTAssertTrue(prompt.contains("glab mr diff 12"))
        XCTAssertTrue(prompt.contains("!12"))
        XCTAssertTrue(prompt.contains("merge request"))
        XCTAssertFalse(prompt.contains("gh pr"))
        XCTAssertFalse(prompt.contains("GitHub"))
    }

    /// The read-only jobs must say so. An agent that "reviews" a PR by
    /// editing the files, or posts its findings to the forge, has done
    /// something the user didn't ask for and can't easily undo.
    func testReadOnlyTasksForbidWritingAndPosting() {
        let review = Handoff.prompt(.review, subject: .init(pr), forge: .github, base: "main")
        XCTAssertTrue(review.contains("Don't post a review"))
        XCTAssertTrue(review.contains("don't edit any files"))

        let sideEffects = Handoff.prompt(.sideEffects, subject: .init(pr), forge: .github, base: "main")
        XCTAssertTrue(sideEffects.contains("Don't edit any files"))

        let cause = Handoff.prompt(.cause, subject: .init(issue), forge: .github, base: "main")
        XCTAssertTrue(cause.contains("Don't change it yet"))
    }

    /// The writing jobs are allowed to touch the working tree — but not to
    /// publish anything.
    func testWritingTasksStayLocal() {
        let base = "trunk"
        let conflicts = Handoff.prompt(.conflicts, subject: .init(pr), forge: .github, base: base)
        XCTAssertTrue(conflicts.contains(base), "the base branch is the whole point of a conflict resolution")
        XCTAssertTrue(conflicts.contains("gh pr checkout 12"))
        XCTAssertTrue(conflicts.contains("Don't push"))

        let fix = Handoff.prompt(.fix, subject: .init(issue), forge: .github, base: base)
        XCTAssertTrue(fix.contains("branch off \(base)"))
        XCTAssertTrue(fix.contains("fix/issue-11"))
        XCTAssertTrue(fix.contains("Don't push"))
        XCTAssertTrue(fix.contains("don't close the issue"))
    }

    func testEveryTaskHasAMenuTitleAndAWindowSlug() {
        for task in HandoffTask.allCases {
            XCTAssertFalse(task.title.isEmpty)
            XCTAssertFalse(task.slug.isEmpty)
        }
        // Both menus, and no task stranded off both of them.
        XCTAssertEqual(
            Set(HandoffTask.forPullRequests).union(HandoffTask.forIssues),
            Set(HandoffTask.allCases)
        )
        XCTAssertTrue(Set(HandoffTask.forPullRequests).isDisjoint(with: HandoffTask.forIssues))
    }

    // MARK: - The script

    /// The prompt is one `sh` argument. Apostrophes are ordinary in English
    /// prose and would otherwise end the quoting and hand the rest of the
    /// sentence to the shell as commands.
    func testQuotingSurvivesApostrophesAndShellMetacharacters() {
        XCTAssertEqual(Handoff.quoted("don't"), #"'don'\''t'"#)
        let hostile = "rm -rf $HOME; `whoami` && echo 'x' | cat > /tmp/y"
        let script = Handoff.script(binary: "/bin/claude", prompt: hostile, cwd: "/tmp/a b")
        // Everything after the binary is inside one quoted argument: the
        // only unquoted `;` or `&&` in the file would be ours.
        XCTAssertTrue(script.contains("exec '/bin/claude' 'rm -rf $HOME; `whoami` && echo '\\''x'\\'' | cat > /tmp/y'"))
        XCTAssertTrue(script.contains("cd '/tmp/a b' || exit 1"))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        // One handoff, one run: the script takes itself with it.
        XCTAssertTrue(script.contains(#"rm -f "$0""#))
    }

    func testScriptNameIsReadableAndPathSafe() {
        XCTAssertEqual(
            Handoff.scriptName(agent: .claude, label: "#12 review"),
            "Claude #12 review.command"
        )
        // A GitLab label brings a `!`, which is fine in a file name; slashes
        // and colons are not.
        XCTAssertEqual(
            Handoff.scriptName(agent: .codex, label: "!7 side/effects:now"),
            "Codex !7 side-effects-now.command"
        )
    }

    // MARK: - Finding the agent at all

    /// The binaries live wherever their installer put them — ~/.local/bin,
    /// an nvm version directory — so the app asks the user's own shell. An
    /// interactive shell also prints a motd and a prompt preamble, which is
    /// why the answer is fenced instead of being all of stdout.
    func testLoginPathIsReadOutOfShellChatter() {
        let noisy = """
        Last login: Wed Jul 30
        [p10k] instant prompt
        <TheGitPATH>/Users/t/.local/bin:/opt/homebrew/bin:/usr/bin</TheGitPATH>
        """
        XCTAssertEqual(
            Shell.loginPath(from: noisy),
            ["/Users/t/.local/bin", "/opt/homebrew/bin", "/usr/bin"]
        )
    }

    /// A shell that never answered and a shell with an empty PATH are
    /// different things: the first must leave the old answer alone.
    func testLoginPathIsNilWithoutTheFence() {
        XCTAssertNil(Shell.loginPath(from: ""))
        XCTAssertNil(Shell.loginPath(from: "/usr/bin:/bin"))
        XCTAssertEqual(Shell.loginPath(from: "<TheGitPATH></TheGitPATH>"), [])
    }

    func testAgentsMapToInstallableTools() {
        for agent in AgentTool.allCases {
            XCTAssertEqual(agent.tool.binary, agent.binary)
            // No brew formula to promise for either — the hint has to be
            // the tool's own page, with or without Homebrew.
            XCTAssertEqual(
                InstallHint.hint(for: agent.tool, brewInstalled: true),
                .website(agent.tool.website)
            )
        }
    }
}
