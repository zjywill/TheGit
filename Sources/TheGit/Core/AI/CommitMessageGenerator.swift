import Foundation

/// Turning a staged diff into a prompt, and the model's answer back into a
/// commit message. Everything here is a pure function on strings so the
/// tests can drive the whole path without a network or a repository.
enum CommitMessageGenerator {
    // MARK: - Diff collection

    struct FileDiff: Equatable {
        let path: String
        let text: String
    }

    /// Splits a unified diff into its per-file chunks. Anything before the
    /// first `diff --git` (there is nothing, in practice) is dropped.
    static func files(in diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: [Substring] = []

        func flush() {
            guard let header = current.first else { return }
            files.append(FileDiff(path: path(fromHeader: String(header)),
                                  text: current.joined(separator: "\n")))
            current = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
            }
            if !current.isEmpty || line.hasPrefix("diff --git ") {
                current.append(line)
            }
        }
        flush()
        return files
    }

    /// `diff --git a/Sources/App.swift b/Sources/App.swift` — the b-side is
    /// the one that survives a rename, and it's what the stat lines show.
    static func path(fromHeader header: String) -> String {
        guard let range = header.range(of: " b/", options: .backwards) else {
            return header.replacingOccurrences(of: "diff --git ", with: "")
        }
        return String(header[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Files whose content tells a model nothing it can't read off the
    /// stat line, and which are large enough to eat the whole budget.
    static func isNoise(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let lockNames: Set<String> = [
            "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock",
            "bun.lockb", "Cargo.lock", "Package.resolved", "composer.lock",
            "poetry.lock", "Gemfile.lock", "go.sum", "flake.lock", "uv.lock",
        ]
        if lockNames.contains(name) { return true }
        if name.hasSuffix(".lock") || name.hasSuffix(".pbxproj") { return true }
        let dirs = ["/node_modules/", "/vendor/", "/.build/", "/dist/", "/Pods/"]
        return dirs.contains { path.contains($0) } || dirs.contains { ("/" + path).hasPrefix($0) }
    }

    /// A body worth sending, or the reason it isn't.
    private static func skipReason(_ file: FileDiff) -> String? {
        if isNoise(path: file.path) { return "generated or locked file" }
        if file.text.contains("GIT binary patch") || file.text.contains("Binary files ") {
            return "binary"
        }
        if LFSParsers.pointerDiff(file.text) != nil { return "Git LFS object" }
        return nil
    }

    /// The diff as the model sees it: the stat first — it is short and says
    /// what the change touches — then as many file bodies as the budget
    /// allows, and an honest note about what was left out.
    static func summarize(
        stat: String,
        diff: String,
        budget: Int,
        perFile: Int = 8_000
    ) -> String {
        var sections = [stat.trimmingCharacters(in: .whitespacesAndNewlines)]
        var spent = 0
        var omitted: [String] = []

        for file in files(in: diff) {
            if let reason = skipReason(file) {
                omitted.append("\(file.path) (\(reason))")
                continue
            }
            var text = file.text
            if text.count > perFile {
                text = truncate(text, to: perFile) + "\n… rest of \(file.path) truncated"
            }
            guard spent + text.count <= budget else {
                omitted.append("\(file.path) (over the size budget)")
                continue
            }
            spent += text.count
            sections.append(text)
        }

        if !omitted.isEmpty {
            sections.append("Not shown in full: " + omitted.joined(separator: ", "))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Cuts at the last line break before the limit, so a hunk never ends
    /// mid-line and reads as corrupt.
    private static func truncate(_ text: String, to limit: Int) -> String {
        let head = text.prefix(limit)
        guard let lastBreak = head.lastIndex(of: "\n") else { return String(head) }
        return String(head[..<lastBreak])
    }

    // MARK: - Prompt

    static func systemPrompt(
        style: AISettings.Style,
        language: AISettings.Language,
        extra: String
    ) -> String {
        var rules = [
            "You write git commit messages. Reply with the commit message and nothing else — no preamble, no explanation, no code fences.",
        ]

        switch style {
        case .conventional:
            rules.append("""
            Subject line: `type(scope): summary`, where type is one of feat, fix, refactor, perf, docs, test, build, ci, chore. Drop the scope when the change spans the repository. Imperative mood, no trailing period, 72 characters at most.
            """)
        case .plain:
            rules.append("""
            Subject line: a short imperative summary, no type prefix, no trailing period, 72 characters at most.
            """)
        }

        rules.append("""
        After the subject, add a blank line and a body explaining why the change was made and anything a reviewer would not guess from the diff. Wrap the body at 72 characters. Leave the body out entirely when the subject already says everything. Use a bullet list only when the change really is several unrelated things.
        """)
        rules.append("Describe what the change accomplishes, not which lines moved. Never invent a ticket number, a co-author, or a reason the diff does not support.")

        switch language {
        case .auto:
            rules.append("Write in the language the repository's recent commit messages use; if that is unclear, write in English.")
        case .english:
            rules.append("Write in English.")
        case .chinese:
            rules.append("正文用简体中文书写；Conventional Commits 的 type 前缀保持英文小写。")
        }

        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { rules.append(extra) }

        return rules.joined(separator: "\n\n")
    }

    static func userPrompt(
        summary: String,
        recentMessages: [String],
        draft: String
    ) -> String {
        var parts: [String] = []

        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            parts.append("""
            The author already started writing this. Treat it as a statement of intent, keep what it says, and finish the job:
            \(draft)
            """)
        }

        if !recentMessages.isEmpty {
            parts.append("""
            Recent commit messages from this repository — match their tone, language and level of detail:
            \(recentMessages.map { "---\n" + $0 }.joined(separator: "\n"))
            """)
        }

        parts.append("""
        Here is the staged change. Write its commit message.

        \(summary)
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Answer

    /// Models like to wrap the answer in a fence or announce it first. Both
    /// end up verbatim in the message box otherwise.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for lead in ["Commit message:", "commit message:", "Here is the commit message:"] {
            if text.hasPrefix(lead) {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }
}
