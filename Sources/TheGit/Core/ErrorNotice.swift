import Foundation

/// One failure on its way to the user, cut into the part a single line can
/// hold and the part only a bug report needs.
///
/// A failed command is news, not a question: there is nothing to decide and
/// no button but OK, so it doesn't get a dialog. What it gets is one line —
/// and one line has to open with what went wrong. `git log --date-order
/// --branches --remotes --tags HEAD --format=… -n 500` spends the whole
/// width before saying anything, so the command is kept apart from the
/// sentence git actually wrote about it, and the verbatim text is kept apart
/// from both, for the pasteboard.
struct ErrorNotice: Identifiable, Equatable {
    /// Fresh per report. Two identical failures are two pieces of news: the
    /// toast has to re-enter for the second one, and its dismissal timer has
    /// to start over.
    let id = UUID()
    /// The thing that went wrong, in the tool's own words, minus its shout.
    let summary: String
    /// The line that says why, when the summary alone doesn't — see
    /// `reason(in:)`. Nil when the failure was already one line.
    let reason: String?
    /// The command behind it, when there was one.
    let command: String?
    /// Everything, verbatim.
    let detail: String

    /// Failures we word ourselves ("Nothing is staged to describe.") — no
    /// command, and already the one line.
    init(text: String) {
        summary = Self.firstLine(text)
        reason = nil
        command = nil
        detail = text
    }

    init(_ error: Error) {
        let message: String
        switch error {
        case let error as GitError:
            message = error.message
            command = "git " + error.command
        case let error as ShellError:
            message = error.message
            command = error.command
        default:
            message = error.localizedDescription
            command = nil
        }
        summary = Self.firstLine(message)
        reason = Self.reason(in: message)
        detail = error.localizedDescription
    }

    /// The line that names the failure, minus the CLI's own shout, clipped to
    /// something one line of a strip can hold. Usually the first line — but
    /// git narrates: a failed push opens with "To github.com:…" and doesn't
    /// say `error:` until two lines later, so a line that announces itself
    /// as the error outranks everything before it.
    static func firstLine(_ text: String, limit: Int = 140) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var line = lines.first { line in
            announcements.contains { line.hasPrefix($0) }
        } ?? lines.first ?? text
        for shout in shouts where line.hasPrefix(shout) {
            line = String(line.dropFirst(shout.count))
            break
        }
        return clip(line, limit: limit)
    }

    /// The line that says why, when the summary alone doesn't. The summary
    /// is git's verdict — "failed to push some refs to '…'" — and the cause
    /// is usually a line printed around it: the `! [rejected]` status of the
    /// push that wasn't a fast-forward, the server's `remote:` line, the
    /// "Permission denied (publickey)" the SSH layer wrote above the
    /// `fatal:`. Nil when no such line exists — a one-line failure has
    /// already said everything.
    static func reason(in text: String, limit: Int = 140) -> String? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A rejected push names the branch and the why in its status line —
        // whose column-aligning run of spaces means nothing off the terminal
        // grid it was printed for.
        if let status = lines.first(where: { $0.hasPrefix("! [") }) {
            return clip(
                status.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                limit: limit
            )
        }
        // Only when the summary is a real announcement is another line a
        // cause; without one, the summary is just the first line, and the
        // rest is its continuation, not its explanation.
        guard lines.contains(where: { line in
            announcements.contains { line.hasPrefix($0) }
        }) else { return nil }
        // The first line that is neither the verdict itself nor scaffolding
        // around it: "To <remote>" is an address label, hint lines are
        // multi-line advice, and both read wrong as a cause.
        let cause = lines.first { line in
            !line.hasPrefix("To ") && !line.hasPrefix("hint:")
                && !shouts.contains(where: { line.hasPrefix($0) })
        }
        return cause.map { clip($0, limit: limit) }
    }

    private static func clip(_ line: String, limit: Int) -> String {
        line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Prefixes that mark a line as the error itself, not narration around
    /// it. `warning:` is deliberately absent: a warning above the message is
    /// still not the message.
    private static let announcements = [
        "ERROR: ", "error: ", "ERROR ", "FATAL: ", "fatal: ",
    ]

    /// Every prefix a command-line tool uses to announce that this is the
    /// error. Wherever this text lands — a toast, a sidebar row — something
    /// already says that, with an icon.
    private static let shouts = announcements + ["warning: "]
}
