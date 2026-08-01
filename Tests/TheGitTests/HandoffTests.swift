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

    // MARK: - Where it opens

    /// The whole complaint this setting answers: `NSWorkspace.open` on a
    /// `.command` means Terminal.app on every Mac nobody has re-associated,
    /// so an unset preference has to stay meaningful and a set one has to
    /// survive the round trip through UserDefaults.
    func testTargetRoundTripsThroughItsStoredString() {
        let ghostty = TerminalApp.all.first { $0.name == "Ghostty" }!
        for target in [HandoffTarget.systemDefault, .terminal(ghostty)] {
            XCTAssertEqual(
                HandoffTarget.target(for: target.stored, installed: TerminalApp.all),
                target
            )
        }
        XCTAssertEqual(HandoffTarget.systemDefault.stored, "")
    }

    /// A terminal uninstalled since it was picked must not take the handoff
    /// down with it.
    func testAMissingTerminalFallsBackToTheSystemDefault() {
        XCTAssertEqual(HandoffTarget.target(for: "com.mitchellh.ghostty", installed: []), .systemDefault)
        XCTAssertEqual(HandoffTarget.target(for: "com.example.nothing", installed: TerminalApp.all), .systemDefault)
    }

    /// The terminals that don't answer for `.command` files get the script
    /// as their initial command instead — in each one's own dialect, which
    /// is exactly the kind of thing that is wrong for a year if only the
    /// user with Alacritty installed can see it.
    func testEachDialectHandsOverTheScriptItsOwnWay() {
        let flags = Dictionary(
            uniqueKeysWithValues: TerminalApp.all.map { ($0.name, $0.runFlags) }
        )
        XCTAssertEqual(flags["Alacritty"], ["-e"])
        XCTAssertEqual(flags["Kitty"], [])
        XCTAssertEqual(flags["WezTerm"], ["start", "--"])
        // Terminal and iTerm2 are document-openers and nothing else; a
        // stray `-e` handed to them would be a window running the wrong
        // thing rather than an error anyone sees.
        XCTAssertEqual(flags["Terminal"], .some(nil))
        XCTAssertEqual(flags["iTerm2"], .some(nil))

        XCTAssertEqual(
            Handoff.openArguments(app: "/Applications/kitty.app", flags: [], script: "/tmp/h.command"),
            ["-na", "/Applications/kitty.app", "--args", "/tmp/h.command"]
        )
        XCTAssertEqual(
            Handoff.openArguments(app: "/Applications/Alacritty.app", flags: ["-e"], script: "/tmp/h.command"),
            ["-na", "/Applications/Alacritty.app", "--args", "-e", "/tmp/h.command"]
        )
        XCTAssertEqual(
            Handoff.openArguments(app: "/Applications/WezTerm.app", flags: ["start", "--"], script: "/tmp/h.command"),
            ["-na", "/Applications/WezTerm.app", "--args", "start", "--", "/tmp/h.command"]
        )
    }

    /// Every terminal in the list has to be reachable from the picker,
    /// which means a bundle identifier that isn't a typo and a name that
    /// isn't a duplicate — a second "Ghostty" would be two rows that look
    /// the same and behave differently.
    func testTheTerminalListIsWellFormed() {
        XCTAssertEqual(Set(TerminalApp.all.map(\.id)).count, TerminalApp.all.count)
        XCTAssertEqual(Set(TerminalApp.all.map(\.name)).count, TerminalApp.all.count)
        for terminal in TerminalApp.all {
            XCTAssertTrue(terminal.id.contains("."), "\(terminal.name) needs a bundle identifier")
            XCTAssertFalse(terminal.name.isEmpty)
        }
        // The mainstream ones, so nobody's terminal is missing from a list
        // whose whole job is to contain it.
        let names = Set(TerminalApp.all.map(\.name))
        for expected in ["Terminal", "iTerm2", "Ghostty", "Alacritty", "Kitty", "WezTerm", "Warp", "Hyper", "Tabby", "Rio"] {
            XCTAssertTrue(names.contains(expected), "\(expected) should be offered")
        }
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
