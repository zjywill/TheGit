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
    /// The command behind it, when there was one.
    let command: String?
    /// Everything, verbatim.
    let detail: String

    /// Failures we word ourselves ("Nothing is staged to describe.") — no
    /// command, and already the one line.
    init(text: String) {
        summary = Self.firstLine(text)
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
        detail = error.localizedDescription
    }

    /// First line with anything in it, minus the CLI's own shout, clipped to
    /// something one line of a strip can hold.
    static func firstLine(_ text: String, limit: Int = 140) -> String {
        var line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
        for shout in shouts where line.hasPrefix(shout) {
            line = String(line.dropFirst(shout.count))
            break
        }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Every prefix a command-line tool uses to announce that this is the
    /// error. Wherever this text lands — a toast, a sidebar row — something
    /// already says that, with an icon.
    private static let shouts = [
        "ERROR: ", "error: ", "ERROR ", "FATAL: ", "fatal: ", "warning: ",
    ]
}
