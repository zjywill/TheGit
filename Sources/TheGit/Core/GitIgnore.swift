import Foundation

/// Builds `.gitignore` patterns and appends them to an ignore file's text.
/// Pure string work, kept out of RepoState so the escaping rules can be
/// tested without a repo on disk.
enum GitIgnore {

    /// Escapes what git reads as glob syntax, so a path that happens to
    /// contain `[`, `*` or `?` still matches only itself. `#` and `!` are
    /// escaped at the front of the pattern (comment / negation markers)
    /// and a trailing space is escaped too — git strips unescaped ones.
    static func escape(_ literal: String) -> String {
        var out = ""
        for char in literal {
            if char == "\\" || char == "*" || char == "?" || char == "[" {
                out.append("\\")
            }
            out.append(char)
        }
        if out.hasPrefix("#") || out.hasPrefix("!") { out = "\\" + out }
        if out.hasSuffix(" ") { out = String(out.dropLast()) + "\\ " }
        return out
    }

    /// One file, anchored to the repo root so a same-named file elsewhere
    /// keeps showing up: `src/a.log` -> `/src/a.log`.
    static func filePattern(_ path: String) -> String {
        "/" + escape(path)
    }

    /// Everything under one directory: `src/gen/` -> `/src/gen/`.
    static func directoryPattern(_ directory: String) -> String {
        var dir = directory
        while dir.hasSuffix("/") { dir.removeLast() }
        return "/" + escape(dir) + "/"
    }

    /// Every file with this extension, anywhere: `log` -> `*.log`.
    static func extensionPattern(_ ext: String) -> String {
        "*." + escape(ext)
    }

    /// The ignore file's new text, or nil when the pattern is already
    /// listed — re-ignoring from the menu should be a no-op, not a
    /// duplicate line.
    static func append(_ pattern: String, to content: String) -> String? {
        // Split on `isNewline`, not on "\n": in Swift a CRLF pair is one
        // Character, so a file written on Windows has no "\n" to split on
        // at all and every line would read as one long pattern.
        let existing = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !existing.contains(pattern) else { return nil }
        var updated = content
        if let last = updated.last, !last.isNewline { updated += "\n" }
        return updated + pattern + "\n"
    }
}
