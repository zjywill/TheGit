import Foundation

/// Prompts for a pull/merge request title and description, and the parsing
/// of the model's answer back into the two fields. Pure string functions,
/// like `CommitMessageGenerator`, so tests can drive the whole path.
enum PullRequestGenerator {
    // MARK: - Prompt

    static func systemPrompt(
        forge: Forge,
        language: AISettings.Language,
        extra: String
    ) -> String {
        let noun = forge.itemNoun.lowercased()
        var rules = [
            "You write \(noun) titles and descriptions for code review. Reply with the \(noun) text and nothing else — no preamble, no explanation, no code fences around the whole answer.",
            """
            First line: the title — a short imperative summary of the whole branch, no trailing period, 72 characters at most. Then a blank line, then the description in Markdown: what the change does, why, and anything a reviewer should look at first. Use short sections or bullets only when the branch really is several things. Keep it honest and compact — a reviewer reads this before the diff.
            """,
            "Describe the net effect of the branch, not a commit-by-commit replay. Never invent a ticket number, a reviewer, or behaviour the diff does not support.",
        ]

        switch language {
        case .auto:
            rules.append("Write in the language the branch's commit messages use; if that is unclear, write in English.")
        case .english:
            rules.append("Write in English.")
        case .chinese:
            rules.append("用简体中文书写；代码标识符与文件名保持原文。")
        }

        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { rules.append(extra) }

        return rules.joined(separator: "\n\n")
    }

    static func userPrompt(
        source: String,
        target: String,
        commits: [String],
        summary: String
    ) -> String {
        var parts = [
            "Branch `\(source)` is being merged into `\(target)`. Write its title and description.",
        ]
        if !commits.isEmpty {
            parts.append("""
            The branch's commit messages, newest first:
            \(commits.map { "---\n" + $0 }.joined(separator: "\n"))
            """)
        }
        parts.append("""
        The combined diff against \(target):

        \(summary)
        """)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Answer

    /// First line is the title, the rest the body. Models also like to
    /// label the parts or promote the title to a heading; both would end
    /// up verbatim in the form fields.
    static func parse(_ raw: String) -> (title: String, body: String) {
        let text = CommitMessageGenerator.clean(raw)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var title = ""
        while !lines.isEmpty, title.isEmpty {
            title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        }
        for label in ["Title:", "title:", "# ", "## "] where title.hasPrefix(label) {
            title = String(title.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        var body = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Description:", "description:", "Body:"] where body.hasPrefix(label) {
            body = String(body.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return (title, body)
    }
}
