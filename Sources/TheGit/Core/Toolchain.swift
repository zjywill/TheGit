import Foundation

/// The external tools the app drives, whether each is on the box, and —
/// when one isn't — the least-friction way for the user to get it. All
/// probes are file checks: nothing here spawns the missing tool to find
/// out it's missing.
enum DevTool: String, CaseIterable, Identifiable {
    case git
    case gh
    case glab
    case gitLFS = "git-lfs"
    case claude
    case codex

    var id: String { rawValue }
    var binary: String { rawValue }

    /// Settings-row title: the human name, with the binary in brackets
    /// where they differ enough that the brew command needs explaining.
    var title: String {
        switch self {
        case .git: return "Git"
        case .gh: return "GitHub CLI (gh)"
        case .glab: return "GitLab CLI (glab)"
        case .gitLFS: return "Git LFS"
        case .claude: return "Claude Code (claude)"
        case .codex: return "Codex CLI (codex)"
        }
    }

    /// One line for the settings row: what the app uses it for, so a user
    /// who has never heard of `glab` can tell whether they care.
    var purpose: String {
        switch self {
        case .git: return "Every repository operation — nothing works without it."
        case .gh: return "Pull requests on GitHub: the sidebar list, checkout, and Create Pull Request."
        case .glab: return "Merge requests on GitLab: the sidebar list, checkout, and Create Merge Request."
        case .gitLFS: return "Large File Storage — shows LFS-tracked files and keeps their smudge/clean filters working."
        case .claude, .codex: return "Hand Off: opens this agent in the repo — in the terminal you pick under Hand Off — already reviewing, fixing, or unpicking the conflicts of what you right-clicked."
        }
    }

    /// The Homebrew formula, when there is one worth suggesting. nil sends
    /// the user to the tool's own page instead of guessing at a tap or a
    /// cask name that may not be there.
    var brewFormula: String? {
        switch self {
        case .git, .gh, .glab, .gitLFS: return rawValue
        case .claude, .codex: return nil
        }
    }

    /// Where to get it without Homebrew. Each page carries the tool's own
    /// installer or instructions.
    var website: String {
        switch self {
        case .git: return "https://git-scm.com/download/mac"
        case .gh: return "https://cli.github.com"
        case .glab: return "https://gitlab.com/gitlab-org/cli#installation"
        case .gitLFS: return "https://git-lfs.com"
        case .claude: return "https://claude.com/claude-code"
        case .codex: return "https://github.com/openai/codex"
        }
    }
}

/// What to tell the user when a tool is missing. Pure choice, so it's
/// testable: the caller supplies whether Homebrew exists.
enum InstallHint: Equatable {
    /// Homebrew is on the box: one line to copy into a terminal.
    case command(String)
    /// No Homebrew: send them to the tool's own installer page instead of
    /// asking them to install a package manager first.
    case website(String)

    static func hint(for tool: DevTool, brewInstalled: Bool) -> InstallHint {
        guard brewInstalled, let formula = tool.brewFormula else {
            return .website(tool.website)
        }
        return .command("brew install " + formula)
    }

    /// The text a sidebar row or settings row shows.
    var display: String {
        switch self {
        case .command(let line): return line
        case .website(let url): return url
        }
    }

    /// Decides the verb the UI promises: copy a command vs open a page.
    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}

enum Toolchain {
    /// A git the app's `/usr/bin/env git` would actually run, or nil.
    ///
    /// Never answered by executing `/usr/bin/git`: that binary exists on
    /// every Mac — it's Apple's xcrun shim — and *running* it on a box
    /// without the Command Line Tools pops the system install dialog,
    /// which is not a probe's call to make. File checks only.
    static func installedGit() -> String? {
        // A real git on PATH beats the shim. /usr/bin is skipped: its git
        // is the shim itself, telling us nothing.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs where dir != "/usr/bin" {
            let candidate = dir + "/git"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // What the shim would resolve to: the Command Line Tools, then
        // whatever xcode-select points at, then Xcode's default home.
        let developerGits = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: "/var/db/xcode_select_link"
            )).map { $0 + "/usr/bin/git" },
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        for candidate in developerGits.compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static var brewInstalled: Bool { Shell.which("brew") != nil }

    static func hint(for tool: DevTool) -> InstallHint {
        InstallHint.hint(for: tool, brewInstalled: brewInstalled)
    }

    /// Pops Apple's own Command Line Tools installer dialog — the shortest
    /// path to a working git on a fresh Mac: no password prompt from us,
    /// no Homebrew prerequisite. Errors (already installed, dialog
    /// dismissed) are irrelevant: the caller polls `installedGit()` to
    /// learn the outcome either way.
    static func installCommandLineTools() async {
        _ = try? await Shell.run("/usr/bin/xcode-select", ["--install"])
    }

    /// First line of `<tool> --version`, or nil when the tool is missing
    /// or won't run. The first line is the only part every CLI agrees on;
    /// `gh` follows it with a build hash and an upgrade nag.
    static func version(of tool: DevTool) async -> String? {
        let path: String? = tool == .git ? installedGit() : Shell.which(tool.binary)
        guard let path else { return nil }
        guard let out = try? await Shell.run(path, ["--version"]) else { return nil }
        let line = out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line
    }
}
