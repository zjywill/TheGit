import Foundation

struct DiffLine: Identifiable {
    enum Kind {
        case hunk, add, del, context
    }

    let id: Int
    let kind: Kind
    let oldNum: Int?
    let newNum: Int?
    let text: String
    /// Index into ParsedDiff.hunks for `.hunk` lines (nil for binary notes
    /// and synthesized diffs) — drives the per-hunk stage button.
    var hunkIndex: Int?
}

/// A parsed single-file unified diff, keeping enough raw structure to
/// build `git apply`-able patches for individual hunks.
struct ParsedDiff {
    var lines: [DiffLine] = []
    /// Raw file header ("diff --git … +++ b/x\n"), empty for synthesized diffs.
    var header: String = ""
    /// Raw hunk bodies including their @@ line, each ending with \n.
    var hunks: [String] = []

    /// A patch containing just one hunk, suitable for `git apply --cached`.
    func patch(forHunk index: Int) -> String? {
        guard !header.isEmpty, hunks.indices.contains(index) else { return nil }
        return header + hunks[index]
    }
}

enum DiffParser {
    /// Parse unified `git diff` output into renderable lines plus the raw
    /// header/hunk text needed for hunk-level staging.
    static func parse(_ diff: String) -> ParsedDiff {
        var result = ParsedDiff()
        var old = 0
        var new = 0
        var id = 0
        var inHunk = false

        func append(_ kind: DiffLine.Kind, old: Int?, new: Int?, _ text: String, hunkIndex: Int? = nil) {
            result.lines.append(DiffLine(id: id, kind: kind, oldNum: old, newNum: new, text: text, hunkIndex: hunkIndex))
            id += 1
        }

        let rawLines = diff.components(separatedBy: "\n")
        for (i, raw) in rawLines.enumerated() {
            if raw.hasPrefix("@@") {
                inHunk = true
                (old, new) = hunkStarts(raw)
                result.hunks.append(raw + "\n")
                append(.hunk, old: nil, new: nil, raw, hunkIndex: result.hunks.count - 1)
            } else if raw.hasPrefix("Binary files") {
                append(.hunk, old: nil, new: nil, raw)
            } else if !inHunk {
                // diff --git / index / --- / +++ / mode headers
                if !raw.isEmpty { result.header += raw + "\n" }
            } else if raw.isEmpty && i == rawLines.count - 1 {
                continue // trailing newline from the split
            } else {
                if !result.hunks.isEmpty {
                    result.hunks[result.hunks.count - 1] += raw + "\n"
                }
                if raw.hasPrefix("+") {
                    append(.add, old: nil, new: new, String(raw.dropFirst()))
                    new += 1
                } else if raw.hasPrefix("-") {
                    append(.del, old: old, new: nil, String(raw.dropFirst()))
                    old += 1
                } else if raw.hasPrefix("\\") {
                    continue // "\ No newline at end of file" (kept in raw hunk)
                } else {
                    append(.context, old: old, new: new, String(raw.dropFirst(min(1, raw.count))))
                    old += 1
                    new += 1
                }
            }
        }
        return result
    }

    /// Whole-file "+ every line" diff for untracked files (not stageable
    /// per hunk — the whole file is one addition).
    static func synthesizeAdded(_ content: String) -> ParsedDiff {
        var raw = content.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var result = ParsedDiff()
        result.lines = [DiffLine(id: 0, kind: .hunk, oldNum: nil, newNum: nil, text: "@@ -0,0 +1,\(raw.count) @@ (new file)")]
        for (i, line) in raw.enumerated() {
            result.lines.append(DiffLine(id: i + 1, kind: .add, oldNum: nil, newNum: i + 1, text: line))
        }
        return result
    }

    /// Extract starting line numbers from "@@ -a,b +c,d @@ …".
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        var old = 1
        var new = 1
        for token in header.split(separator: " ") {
            if token.hasPrefix("-") {
                old = Int(token.dropFirst().split(separator: ",").first ?? "1") ?? 1
            } else if token.hasPrefix("+") {
                new = Int(token.dropFirst().split(separator: ",").first ?? "1") ?? 1
            }
        }
        return (old, new)
    }
}
