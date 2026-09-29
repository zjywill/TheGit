import Foundation

/// Making a repository, as opposed to working in one. Everything else here
/// hangs off a `GitClient`, which is bound to a repo that already exists;
/// these are the two moments before that.
enum Clone {
    // MARK: - The URL

    /// What `git clone` would call the folder: the last piece of the address,
    /// without `.git`. Splits on `:` as well as `/` because the scp-like
    /// spelling — `git@host:owner/repo.git`, or `git@host:repo.git` — has a
    /// colon where a path would have a slash.
    static func folderName(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last
        else { return nil }
        var name = String(last)
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty || name == "." || name == ".." ? nil : name
    }

    /// Whether it can be handed to `git clone` as an address. Not whether it
    /// exists — only git and the network can say that. A leading dash is the
    /// one thing refused outright: `--upload-pack=…` as an "address" is a
    /// command line, and `clone` passes it on to run.
    static func isUsable(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("-")
            && !trimmed.contains(where: \.isWhitespace)
    }

    /// Text that is plainly a repository address, for offering it as the
    /// default when the sheet opens: whoever copied a URL from a browser and
    /// then chose Clone shouldn't have to paste it.
    static func looksLikeRemote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsable(trimmed), trimmed.count < 500 else { return false }
        if ["https://", "http://", "ssh://", "git://"].contains(where: trimmed.hasPrefix) {
            return true
        }
        // user@host:path — the scp-like form, which has no scheme to go by.
        let scp = try? NSRegularExpression(pattern: #"^[\w.\-]+@[\w.\-]+:[^\s]+$"#)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return scp?.firstMatch(in: trimmed, range: range) != nil
    }

    // MARK: - Progress

    /// Where a clone is: git's name for the phase and how far through it is.
    /// Each phase counts from zero again — git reports them that way.
    struct Progress: Equatable {
        var phase: String
        var percent: Int
    }

    private static let progressLine = try? NSRegularExpression(
        pattern: #"^(?:remote:\s*)?([A-Za-z][A-Za-z ]*?):\s+(\d{1,3})%"#
    )

    /// The newest progress in a piece of stderr. git redraws its progress in
    /// place with `\r`, so one read can hold a dozen of them and the last is
    /// the truth; a piece with none in it (the "Cloning into…" line, a
    /// warning) says nothing about how far along it is.
    static func progress(in chunk: String) -> Progress? {
        for segment in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).reversed() {
            let line = segment.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = progressLine?.firstMatch(in: line, range: range),
                  let phase = Range(match.range(at: 1), in: line),
                  let percent = Range(match.range(at: 2), in: line),
                  let value = Int(line[percent])
            else { continue }
            return Progress(phase: String(line[phase]), percent: min(value, 100))
        }
        return nil
    }

    // MARK: - Cloning

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `git clone <url>` into `parent/name`, reporting progress as it goes.
    /// Returns the folder. A failure — or a cancel, which kills git — takes
    /// whatever was half-made with it: the folder is only ever removed after
    /// this function has seen that it did not exist a moment earlier.
    static func run(
        url: String,
        into parent: String,
        name: String,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> String {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsable(address) else { throw Failure(message: "That doesn’t look like a repository address.") }
        let destination = (parent as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination) else {
            throw Failure(message: "“\(name)” already exists in that folder.")
        }
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        do {
            try await Shell.run(
                "/usr/bin/env",
                // `--`: what follows is an address and a folder, never an option.
                ["git", "clone", "--progress", "--", address, destination],
                env: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"],
                label: "git clone",
                onStderr: { chunk in
                    if let progress = progress(in: chunk) { onProgress(progress) }
                }
            )
        } catch {
            try? fm.removeItem(atPath: destination)
            if error is CancellationError { throw error }
            let message = (error as? ShellError)?.message ?? error.localizedDescription
            throw Failure(message: explain(message))
        }
        return destination
    }

    /// git's own words, plus the one thing that would have got them past it.
    /// Authentication is where a first clone stops, and git's message for it
    /// — "terminal prompts disabled" — names a mechanism the user never saw.
    static func explain(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("terminal prompts disabled")
            || lower.contains("authentication failed")
            || lower.contains("could not read username") {
            return text + "\n\nThis repository needs you to sign in. For an HTTPS address, run "
                + "`gh auth login` once in Terminal; or use the SSH address instead."
        }
        if lower.contains("host key verification failed") {
            return text + "\n\nThis Mac hasn’t connected to that host over SSH before. Run "
                + "`ssh -T git@<host>` once in Terminal and accept its key, then try again."
        }
        if lower.contains("permission denied (publickey") {
            return text + "\n\nNo SSH key on this Mac is accepted there. Add one to ssh-agent, "
                + "or use the HTTPS address."
        }
        return text
    }

    // MARK: - Init

    /// Not the home folder or the root of the disk: a `.git` there quietly
    /// makes every file a Mac user owns "untracked", and the folder picker is
    /// exactly where a wrong click lands.
    @MainActor
    static func canInitialize(_ path: String) -> Bool {
        let canonical = AppState.canonical(path: path)
        let home = AppState.canonical(path: NSHomeDirectory())
        return canonical != "/" && canonical != home
    }

    /// `git init` in an existing folder. On the branch the user's own
    /// `init.defaultBranch` names, and on `main` when they have none — git's
    /// fallback of `master` is a leftover, and warns about itself.
    static func initialize(at path: String) async throws {
        let configured = (try? await Shell.run(
            "/usr/bin/env", ["git", "config", "--get", "init.defaultBranch"]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var args = ["git", "init", "-q"]
        if configured.isEmpty { args += ["-b", "main"] }
        args += ["--", path]
        do {
            try await Shell.run("/usr/bin/env", args, env: ["GIT_TERMINAL_PROMPT": "0"])
        } catch let error as ShellError {
            throw Failure(message: error.message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
