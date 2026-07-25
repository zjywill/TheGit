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
}

enum DiffParser {
    /// Parse unified `git diff` output into renderable lines.
    /// File headers (diff --git / index / --- / +++) are dropped.
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0
        var new = 0
        var id = 0
        var inHunk = false

        func append(_ kind: DiffLine.Kind, old: Int?, new: Int?, _ text: String) {
            lines.append(DiffLine(id: id, kind: kind, oldNum: old, newNum: new, text: text))
            id += 1
        }

        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                inHunk = true
                (old, new) = hunkStarts(raw)
                append(.hunk, old: nil, new: nil, raw)
            } else if raw.hasPrefix("Binary files") {
                append(.hunk, old: nil, new: nil, raw)
            } else if !inHunk {
                continue // diff --git / index / --- / +++ headers
            } else if raw.hasPrefix("+") {
                append(.add, old: nil, new: new, String(raw.dropFirst()))
                new += 1
            } else if raw.hasPrefix("-") {
                append(.del, old: old, new: nil, String(raw.dropFirst()))
                old += 1
            } else if raw.hasPrefix("\\") {
                continue // "\ No newline at end of file"
            } else if raw.isEmpty && raw == diff.components(separatedBy: "\n").last {
                continue
            } else {
                append(.context, old: old, new: new, String(raw.dropFirst(min(1, raw.count))))
                old += 1
                new += 1
            }
        }
        return lines
    }

    /// Whole-file "+ every line" diff for untracked files.
    static func synthesizeAdded(_ content: String) -> [DiffLine] {
        var raw = content.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var lines: [DiffLine] = [DiffLine(id: 0, kind: .hunk, oldNum: nil, newNum: nil, text: "@@ -0,0 +1,\(raw.count) @@ (new file)")]
        for (i, line) in raw.enumerated() {
            lines.append(DiffLine(id: i + 1, kind: .add, oldNum: nil, newNum: i + 1, text: line))
        }
        return lines
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
