import Foundation

/// One file `git lfs ls-files` reports.
struct LFSFile: Identifiable, Hashable {
    let oid: String
    let path: String
    /// git prints `*` when the object is in the local cache and `-` when
    /// only the pointer is there — the file has not been downloaded.
    let downloaded: Bool

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// What this repo's LFS setup looks like. Empty means "not an LFS repo",
/// which is also what we report when the `git-lfs` binary is missing.
struct LFSStatus: Equatable {
    /// Patterns from `.gitattributes` routed through the lfs filter.
    var patterns: [String] = []
    var files: [LFSFile] = []

    var isEnabled: Bool { !patterns.isEmpty || !files.isEmpty }
    /// Files whose object is not in the local store. Careful: a file with
    /// uncommitted changes lands here too — git has not cleaned its new
    /// content into the store yet, and nothing is actually missing. Use
    /// `RepoSnapshot.lfsMissing` for anything the user reads.
    var notInLocalStore: [LFSFile] { files.filter { !$0.downloaded } }
}

/// The three fields of an LFS pointer file. What git stores in place of
/// the real bytes, and what a diff of an LFS-tracked file shows.
struct LFSPointer: Equatable {
    let oid: String
    let size: Int64

    /// "sha256:a1b2c3…" is noise at full length; the first 12 hex digits
    /// identify the object well enough to compare two of them by eye.
    var shortOID: String {
        let hex = oid.contains(":") ? String(oid.split(separator: ":").last ?? "") : oid
        return String(hex.prefix(12))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Both sides of a pointer diff. A modified LFS file has both, an added
/// one only `new`, a deleted one only `old`.
struct LFSPointerDiff: Equatable {
    var old: LFSPointer?
    var new: LFSPointer?

    /// How much bigger (or smaller) the file got, when both sides exist.
    var sizeDelta: Int64? {
        guard let old, let new else { return nil }
        return new.size - old.size
    }
}

enum LFSParsers {

    /// `git lfs ls-files`: "<oid> <*|-> <path>", path last because it can
    /// contain spaces.
    static func lsFiles(_ output: String) -> [LFSFile] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3 else { return nil }
            return LFSFile(
                oid: String(fields[0]),
                path: String(fields[2]),
                downloaded: fields[1] == "*"
            )
        }
    }

    /// Patterns in a `.gitattributes` that go through the lfs filter:
    /// "*.psd filter=lfs diff=lfs merge=lfs -text" -> "*.psd".
    static func trackedPatterns(gitattributes: String) -> [String] {
        gitattributes.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 1, fields.dropFirst().contains("filter=lfs") else { return nil }
            // git escapes a space in a pattern as "[[:space:]]".
            return String(fields[0]).replacingOccurrences(of: "[[:space:]]", with: " ")
        }
    }

    /// Reads a unified diff as a pointer diff, or nil when it isn't one.
    /// Context lines count for both sides: an LFS file whose content
    /// changed keeps `version` as context and only moves oid and size.
    static func pointerDiff(_ diff: String) -> LFSPointerDiff? {
        var old: [String: String] = [:]
        var new: [String: String] = [:]
        for line in diff.split(whereSeparator: \.isNewline) {
            // Headers first: "--- a/x" and "+++ b/x" start with -/+ too.
            if line.hasPrefix("diff --git") || line.hasPrefix("index ")
                || line.hasPrefix("---") || line.hasPrefix("+++")
                || line.hasPrefix("@@") || line.hasPrefix("new file")
                || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                || line.hasPrefix("rename ") || line.hasPrefix("old mode")
                || line.hasPrefix("new mode") {
                continue
            }
            guard let marker = line.first else { continue }
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let space = body.firstIndex(of: " ") else { continue }
            let key = String(body[..<space])
            let value = String(body[body.index(after: space)...])
            guard ["version", "oid", "size"].contains(key) else { continue }
            switch marker {
            case "-": old[key] = value
            case "+": new[key] = value
            case " ": old[key] = value; new[key] = value
            default: continue
            }
        }
        /// All three fields have to be there — a text file with a line
        /// that happens to start with "size " is not a pointer.
        func pointer(_ fields: [String: String]) -> LFSPointer? {
            guard let version = fields["version"], version.contains("git-lfs"),
                  let oid = fields["oid"],
                  let size = fields["size"].flatMap(Int64.init)
            else { return nil }
            return LFSPointer(oid: oid, size: size)
        }
        let diffed = LFSPointerDiff(old: pointer(old), new: pointer(new))
        return diffed.old == nil && diffed.new == nil ? nil : diffed
    }
}
