import AppKit
import Foundation

/// A coding agent the app can hand a piece of work to.
///
/// Not the same thing as Settings › AI: that talks to a model over HTTP to
/// write a commit message. These are the interactive CLIs the user already
/// keeps a terminal open for, and a handoff is literally that — a terminal,
/// in this repo, with the agent already running on a prompt about the pull
/// request or issue you right-clicked. The app writes the brief; the agent
/// does the work where the user can watch it and answer it.
enum AgentTool: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var binary: String { rawValue }

    /// What the user calls it — the menu section title.
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The same binary in Toolchain terms, so Settings › Tools can say
    /// where it was found or how to get it.
    var tool: DevTool {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}

/// The jobs worth handing over, one per line of the menu.
///
/// Deliberately few, and deliberately whole pieces of work rather than
/// prompts-with-a-blank: "review this" and "fix this" are what people
/// actually want from an open issue or an open pull request, and each one
/// carries its own guardrails (what to read first, what not to push).
enum HandoffTask: String, CaseIterable, Identifiable {
    // Pull requests / merge requests.
    case review
    case conflicts
    case sideEffects
    // Issues.
    case cause
    case fix
    case reproduce

    var id: String { rawValue }

    static let forPullRequests: [HandoffTask] = [.review, .conflicts, .sideEffects]
    static let forIssues: [HandoffTask] = [.cause, .fix, .reproduce]

    /// The menu line. Verb first, and where the agent will touch the
    /// working tree the label says so — a context menu shows no tooltips,
    /// so the label is the only warning there is.
    var title: String {
        switch self {
        case .review: return "Review the Changes"
        case .conflicts: return "Resolve the Conflicts"
        case .sideEffects: return "Trace the Side Effects"
        case .cause: return "Find the Cause"
        case .fix: return "Fix It on a New Branch"
        case .reproduce: return "Reproduce It in a Test"
        }
    }

    /// Two words for the terminal window's title bar, which is the script's
    /// file name — so a screen with four handoffs open says which is which.
    var slug: String {
        switch self {
        case .review: return "review"
        case .conflicts: return "conflicts"
        case .sideEffects: return "side effects"
        case .cause: return "cause"
        case .fix: return "fix"
        case .reproduce: return "repro"
        }
    }
}

/// What a prompt needs to know about the thing being handed over. Flat and
/// value-typed on purpose: prompt building is pure, and therefore tested.
struct HandoffSubject {
    enum Kind { case pullRequest, issue }

    let kind: Kind
    let number: Int
    let title: String
    let url: String
    /// Pull requests only.
    var branch: String = ""
    var author: String = ""

    init(_ pr: PullRequest) {
        kind = .pullRequest
        number = pr.number
        title = pr.title
        url = pr.url
        branch = pr.branch
        author = pr.author
    }

    init(_ issue: Issue) {
        kind = .issue
        number = issue.number
        title = issue.title
        url = issue.url
    }
}

enum HandoffError: LocalizedError {
    case notInstalled(AgentTool)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let agent):
            return "\(agent.name) isn't installed — `\(agent.binary)` isn't on the PATH this app can see."
        }
    }
}

/// Which agents are on the box, as something a view can watch.
///
/// Observable rather than a cached static, because the answer arrives late:
/// a bundled .app can only find `claude` after `Shell.resolveLoginPath()`
/// has asked the user's shell where it is, and a menu item that appears
/// only after the next unrelated redraw is a menu item that isn't there.
@MainActor final class AgentTools: ObservableObject {
    static let shared = AgentTools()

    @Published private(set) var available: [AgentTool] = []

    private init() { recheck() }

    func recheck() {
        available = AgentTool.allCases.filter { Shell.which($0.binary) != nil }
    }
}

enum Handoff {
    // MARK: - The brief

    /// The prompt the agent wakes up on. One shape throughout: what the
    /// thing is, how to read it with the forge's own CLI, what to come back
    /// with, and what not to do — an agent that posts a review to GitHub
    /// because nobody said otherwise is a bug in this string.
    static func prompt(
        _ task: HandoffTask,
        subject: HandoffSubject,
        forge: Forge,
        base: String
    ) -> String {
        let cli = forge.binary
        let noun = forge.itemNoun.lowercased()
        let label = forge.label(subject.number)
        let place = forge == .github ? "GitHub" : "GitLab"
        // `gh pr` / `glab mr`, `gh issue` / `glab issue`.
        let object = subject.kind == .pullRequest ? (forge == .github ? "pr" : "mr") : "issue"
        let view = "\(cli) \(object) view \(subject.number) --comments"
        let diff = "\(cli) \(object) diff \(subject.number)"
        let checkout = "\(cli) \(object) checkout \(subject.number)"

        var header = subject.kind == .pullRequest
            ? "\(forge.itemNoun) \(label) — “\(subject.title)”"
            : "Issue \(label) — “\(subject.title)”"
        if !subject.branch.isEmpty { header += "\nBranch: \(subject.branch)" }
        if !subject.author.isEmpty { header += "\nOpened by: \(subject.author)" }
        header += "\n\(subject.url)"

        switch task {
        case .review:
            return """
            Review this \(noun) and tell me what you find.

            \(header)

            Read it first — \(view) for the description and the discussion, \
            then \(diff) for the change itself.

            What I want back:
            - one sentence on what it actually does
            - correctness problems, edge cases, and anything that breaks existing callers
            - the two or three changes worth making before it merges, most important first

            Read the surrounding code before you judge the diff; the diff on \
            its own lies about intent. Don't post a review or a comment on \
            \(place), and don't edit any files — report here.
            """

        case .conflicts:
            return """
            This \(noun) conflicts with \(base). Resolve it.

            \(header)

            Before you touch anything: check whether my working tree is clean \
            here — I may have uncommitted work — and tell me the plan.

            Then check the branch out (\(checkout)), bring \(base) in, and \
            resolve every conflict by understanding both sides rather than by \
            picking one. Build it and run the tests before you call it done.

            Don't push, don't force-push, and don't merge the \(noun) itself.
            """

        case .sideEffects:
            return """
            Work out the blast radius of this \(noun) before it lands.

            \(header)

            Read the change (\(diff)), then go looking through the repository \
            for everything that depends on what it touched: callers, tests, \
            docs, config, persisted formats, anything relying on the old \
            behaviour.

            Tell me what would break, and what this \(noun) is still missing — \
            a test, a migration, a doc update. Don't edit any files.
            """

        case .cause:
            return """
            Find the cause of this issue in this repository.

            \(header)

            Read it first, comments included: \(view)

            Then find where it actually goes wrong — file and line — and why. \
            Explain the mechanism, not the symptom, and say what you would \
            change. Don't change it yet.
            """

        case .fix:
            return """
            Fix this issue.

            \(header)

            Read it first, comments included: \(view)

            Work on a new branch off \(base) — fix/issue-\(subject.number) is \
            fine. Reproduce it before you fix it, make the smallest change \
            that addresses the cause rather than the symptom, and run the tests.

            Show me the diff when you're done. Don't push, don't open a \
            \(noun), and don't close the issue.
            """

        case .reproduce:
            return """
            Turn this issue into a failing test.

            \(header)

            Read it first, comments included: \(view)

            Write the smallest test that fails for the reason described here, \
            in the style of the tests already in this repository. Run it and \
            show me the failure. Don't fix the bug — the failing test is the \
            whole deliverable.
            """
        }
    }

    // MARK: - The terminal

    /// Opens a terminal in the repo with the agent already running on the
    /// prompt.
    ///
    /// A `.command` file, not AppleScript into Terminal: scripting another
    /// app needs Automation permission and pops a TCC dialog the first
    /// time, and this needs neither. LaunchServices hands the file to
    /// whatever the user opens `.command` files with, so someone who lives
    /// in iTerm gets iTerm.
    static func launch(
        _ agent: AgentTool,
        prompt: String,
        cwd: String,
        label: String
    ) throws {
        guard let binary = Shell.which(agent.binary) else {
            throw HandoffError.notInstalled(agent)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheGit-handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The file name is the terminal window's title, so it's written to
        // be read: "Claude #12 review".
        let file = dir.appendingPathComponent(scriptName(agent: agent, label: label))
        try script(binary: binary, prompt: prompt, cwd: cwd)
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path
        )
        NSWorkspace.shared.open(file)
    }

    /// The whole script. It deletes itself first: the shell has already read
    /// it by then, and a handoff is a one-off — nothing should accumulate in
    /// the temp directory waiting to be double-clicked a week later.
    static func script(binary: String, prompt: String, cwd: String) -> String {
        """
        #!/bin/sh
        # Written by TheGit for one handoff, and gone by the time you read it.
        rm -f "$0"
        cd \(quoted(cwd)) || exit 1
        exec \(quoted(binary)) \(quoted(prompt))
        """
    }

    /// Single-quoted for `sh`: everything is literal inside, and the only
    /// character needing care is the quote itself.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Readable, and safe as a file name: no slashes, no colons (which the
    /// Finder shows back as slashes), nothing that needs escaping.
    static func scriptName(agent: AgentTool, label: String) -> String {
        let cleaned = String(label.map { "/:".contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces)
        return "\(agent.name) \(cleaned).command"
    }
}
