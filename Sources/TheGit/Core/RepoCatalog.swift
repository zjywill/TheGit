import Foundation

/// Every repository this app has been pointed at, remembered so that closing
/// a tab isn't the same as losing the folder. Tabs are what you're working on
/// now; this is the list you pick from.
///
/// It groups by **project**, not by folder, because the same project on this
/// machine is routinely three folders: dim-agent, dim-agent-second,
/// dim-agent-thrid. Directory position can't tell those apart from three
/// unrelated repos that happen to share a parent, and it splits the same
/// project when one clone lives somewhere else. The remote can: two clones of
/// one project answer `git remote get-url origin` with the same URL in three
/// spellings, and normalising that spelling away is a dozen lines. A repo with
/// no remote at all is its own project, keyed by path — which is the only
/// thing that identifies it.
///
/// Nothing here spawns git. A closed repo's branch and remotes are two small
/// files inside `.git`, and a list of thirty folders must not cost sixty
/// subprocesses to draw.
enum RepoCatalog {
    /// One remembered folder. Being in this list is not the same as having a
    /// tab: a scan of `~/Git` adds forty folders the user has never opened
    /// here, and those are exactly the ones the list is worth having for.
    struct Entry: Codable, Identifiable, Hashable {
        let path: String
        /// When it entered the list. A scan stamps a whole folder at once,
        /// which is why this can't double as "when did I last work on it".
        var addedAt: Date
        /// Nil until a tab has actually been opened on it.
        var lastOpened: Date?
        var id: String { path }

        init(path: String, addedAt: Date, lastOpened: Date? = nil) {
            self.path = path
            self.addedAt = addedAt
            self.lastOpened = lastOpened
        }

        /// Tolerant of the shape this had before scanning existed — one
        /// non-optional `lastOpened` and no `addedAt`. A decode failure here
        /// would silently empty the whole list on upgrade.
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            path = try box.decode(String.self, forKey: .path)
            lastOpened = try box.decodeIfPresent(Date.self, forKey: .lastOpened)
            addedAt = try box.decodeIfPresent(Date.self, forKey: .addedAt)
                ?? lastOpened
                ?? Date(timeIntervalSince1970: 0)
        }
    }

    /// A user-made group of projects — "work", "side", "clients". Purely a
    /// view onto the same library: a project in no section is still in the
    /// list, and deleting a section deletes no repositories.
    struct Section: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        /// Project ids (`Project.id`), so a section survives a folder being
        /// moved on disk and holds every clone of the project at once.
        var projectIDs: [String]

        init(id: String = UUID().uuidString, name: String, projectIDs: [String] = []) {
            self.id = id
            self.name = name
            self.projectIDs = projectIDs
        }
    }

    /// One band of the list: a user section with its projects, or the
    /// trailing bucket of everything not in one.
    struct Shelf: Identifiable, Hashable {
        /// The section's id, or `""` for the unsectioned bucket.
        let id: String
        /// Nil for the unsectioned bucket, which is only labelled at all when
        /// there are sections above it to distinguish it from.
        let name: String?
        var projects: [Project]
        var isSection: Bool { name != nil }
    }

    /// What `.git` was willing to say without git.
    struct Facts: Equatable {
        /// Branch name, or a short sha for a detached HEAD, or nil when the
        /// folder is gone or HEAD is unreadable.
        var branch: String?
        /// Whether HEAD is detached, so the row can say so rather than show a
        /// sha where a branch name belongs.
        var detached = false
        /// Remote name -> URL, straight out of `.git/config`.
        var remotes: [String: String] = [:]
        /// The folder is still there and still a repository.
        var exists = false

        /// The remote that decides identity: `origin` when there is one,
        /// otherwise the first by name so the choice is stable across reads.
        /// Most repos have exactly one; the few with several are nearly always
        /// origin plus a fork or a mirror, and origin is the one they were
        /// cloned from.
        var originURL: String? {
            if let origin = remotes["origin"] { return origin }
            return remotes.keys.sorted().first.flatMap { remotes[$0] }
        }
    }

    /// A project: one upstream, however many folders of it are on this disk.
    struct Project: Identifiable, Hashable {
        /// The normalised remote identity, or `path:<folder>` for a repo with
        /// no remote.
        let id: String
        /// The project's name — from the remote when there is one, so three
        /// folders called dim-agent-second and -thrid still group under
        /// "dim-agent".
        let name: String
        /// "nextim", when the remote has one.
        let owner: String?
        /// "github.com", when the remote has one.
        let host: String?
        var clones: [Clone]
        /// The most recently opened clone, or nil for a project that has only
        /// ever been scanned in. Not what the list is sorted by — see `group`.
        var lastOpened: Date?
        /// Sort key: the name, case-folded, so "TheGit" files with "thegit"
        /// and not before every lowercase name in the list.
        var sortKey: String { name.lowercased() }
    }

    /// One folder of a project.
    struct Clone: Identifiable, Hashable {
        let path: String
        let addedAt: Date
        let lastOpened: Date?
        let branch: String?
        let detached: Bool
        let exists: Bool
        var id: String { path }
        /// The folder's own name, which is what distinguishes clones of one
        /// project from each other.
        var name: String { (path as NSString).lastPathComponent }
        var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: - Identity

    /// What a remote URL says about the project behind it.
    struct Origin: Equatable {
        /// The grouping key, case-folded: `github.com/nextim/dim-agent`.
        let key: String
        /// The repository's name as its owner spelled it — "TheGit", not
        /// "thegit". The key can't be used for this: it's lowercased so that
        /// two spellings of one URL land on one group, and a name is the one
        /// thing on the row a user reads as their own.
        let name: String
        let owner: String?
        let host: String?
    }

    /// A remote URL reduced to the thing two clones of one project share:
    /// `github.com/nextim/dim-agent`. The same repository is written at least
    /// four ways — scp-style, https, ssh:// with a port, with and without the
    /// `.git` suffix, in any case — and all four have to land on one key or
    /// the grouping silently splits.
    ///
    /// Returns nil for a URL with nothing recognisable in it; the caller then
    /// falls back to the path.
    static func origin(remoteURL: String) -> Origin? {
        var rest = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        // A plain filesystem remote (a local mirror, or a clone of a clone)
        // has no host to key on, so the path is the identity.
        if rest.hasPrefix("/") || rest.hasPrefix("file://") || rest.hasPrefix("~") {
            let path = rest.hasPrefix("file://") ? String(rest.dropFirst(7)) : rest
            let clean = trimGitSuffix((path as NSString).expandingTildeInPath)
            guard !clean.isEmpty else { return nil }
            return Origin(
                key: "file:" + clean.lowercased(),
                name: (clean as NSString).lastPathComponent,
                owner: nil,
                host: nil
            )
        }

        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        // Credentials in the URL are not part of the repository's identity —
        // the same repo cloned by two accounts is one project.
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }

        // The host ends at the first `/` (URL form) or `:` (scp form).
        guard let split = rest.firstIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
        let host = String(rest[..<split]).lowercased()
        var tail = String(rest[rest.index(after: split)...])
        // `ssh://git@host:22/owner/repo` — a port is transport, not identity.
        if rest[split] == ":", let slash = tail.firstIndex(of: "/"),
           tail[..<slash].allSatisfy(\.isNumber), slash != tail.startIndex {
            tail = String(tail[tail.index(after: slash)...])
        }
        let slug = trimGitSuffix(tail.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !host.isEmpty, !slug.isEmpty else { return nil }
        let parts = slug.split(separator: "/").map(String.init)
        return Origin(
            key: (host + "/" + slug).lowercased(),
            name: parts.last ?? slug,
            // The group, not the whole path: `team/sub/app` is owned by `sub`
            // as far as a row that has 110pt for it is concerned.
            owner: parts.count >= 2 ? parts[parts.count - 2] : nil,
            host: host
        )
    }

    /// Just the grouping key — see `origin`.
    static func identity(remoteURL: String) -> String? { origin(remoteURL: remoteURL)?.key }

    private static func trimGitSuffix(_ value: String) -> String {
        var out = value
        while out.hasSuffix("/") { out.removeLast() }
        if out.hasSuffix(".git") { out.removeLast(4) }
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    // MARK: - Reading .git without git

    /// HEAD and the remotes of a repository, from the two files that hold
    /// them. `.git` is usually a directory and occasionally a `gitdir:` file
    /// (worktrees, submodules), which is one extra line to follow.
    static func facts(ofRepoAt path: String) -> Facts {
        var facts = Facts()
        guard let gitDir = gitDirectory(ofRepoAt: path) else { return facts }
        facts.exists = true

        if let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) {
            let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref = line.range(of: "ref: refs/heads/") {
                facts.branch = String(line[ref.upperBound...])
            } else if !line.isEmpty {
                facts.detached = true
                facts.branch = String(line.prefix(7))
            }
        }
        // A worktree's remotes live in the main repository's config, which is
        // what `commondir` points at; a normal repo's commondir is itself.
        let configDir = commonDirectory(of: gitDir) ?? gitDir
        if let config = try? String(contentsOfFile: configDir + "/config", encoding: .utf8) {
            facts.remotes = remotes(inConfig: config)
        }
        return facts
    }

    /// The real `.git` directory: the folder itself, or wherever a `gitdir:`
    /// file points. Nil when the path isn't a repository any more — a folder
    /// the user moved or deleted, which the list has to show as missing rather
    /// than quietly drop.
    private static func gitDirectory(ofRepoAt path: String) -> String? {
        let dot = path + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dot, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dot }
        guard let text = try? String(contentsOfFile: dot, encoding: .utf8),
              let range = text.range(of: "gitdir:") else { return nil }
        let target = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return target }
        return (path as NSString).appendingPathComponent(target)
    }

    private static func commonDirectory(of gitDir: String) -> String? {
        guard let text = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8)
        else { return nil }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return target }
        return (gitDir as NSString).appendingPathComponent(target)
    }

    /// `[remote "origin"] url = …` out of a config file. Deliberately a
    /// three-line parser rather than a git-config implementation: the only
    /// question asked of this file is which URLs it names.
    static func remotes(inConfig config: String) -> [String: String] {
        var found: [String: String] = [:]
        var current: String?
        for raw in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                // `[remote "origin"]`, and also the `[remote.origin]` spelling
                // git writes for subsections in some tools.
                if line.hasPrefix("[remote "), let open = line.firstIndex(of: "\""),
                   let close = line.lastIndex(of: "\""), open < close {
                    current = String(line[line.index(after: open)..<close])
                }
                continue
            }
            guard let name = current, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !url.isEmpty { found[name] = url }
        }
        return found
    }

    // MARK: - Grouping

    /// Remembered folders into projects, in the order they're shown: by name,
    /// case-folded. Pure, so the shape of the list is a test and not a
    /// screenshot — `read` is the only part that touches the disk.
    ///
    /// Alphabetical rather than most-recent, and that changed once the list
    /// stopped being "repos you have open" and became "every repo on this
    /// Mac". At forty rows, a name is something you can aim at before the
    /// list has even finished drawing; a recency order is one that has
    /// rearranged itself since the last time you looked.
    static func group(
        _ entries: [Entry],
        read: (String) -> Facts = RepoCatalog.facts(ofRepoAt:)
    ) -> [Project] {
        var byKey: [String: Project] = [:]
        var order: [String] = []

        for entry in entries {
            let facts = read(entry.path)
            let origin = facts.originURL.flatMap(origin(remoteURL:))
            let key = origin?.key ?? "path:" + entry.path
            let clone = Clone(
                path: entry.path,
                addedAt: entry.addedAt,
                lastOpened: entry.lastOpened,
                branch: facts.branch,
                detached: facts.detached,
                exists: facts.exists
            )
            if var project = byKey[key] {
                project.clones.append(clone)
                project.lastOpened = later(project.lastOpened, entry.lastOpened)
                byKey[key] = project
            } else {
                order.append(key)
                byKey[key] = Project(
                    id: key,
                    // The remote's own name, so folders named -second and
                    // -thrid still group under what the project is called.
                    name: origin?.name ?? (entry.path as NSString).lastPathComponent,
                    owner: origin?.owner,
                    host: origin?.host,
                    clones: [clone],
                    lastOpened: entry.lastOpened
                )
            }
        }

        let projects = order.compactMap { byKey[$0] }.map { project -> Project in
            var project = project
            // Inside a project, recency: which of your three dim-agent copies
            // you touched last is the question a group of clones asks.
            project.clones.sort(by: recency(\Clone.lastOpened, tie: \Clone.path))
            return project
        }
        // Ties broken by something total, never left to `sorted` — it isn't
        // stable, and a list that reshuffles equal rows on every refresh reads
        // as data changing when nothing has.
        return projects.sorted {
            $0.sortKey == $1.sortKey ? $0.id < $1.id : $0.sortKey < $1.sortKey
        }
    }

    /// Projects laid out under the user's sections, in the user's order, with
    /// everything unassigned in a trailing bucket. A project listed by two
    /// sections belongs to the first — the list has to be a partition, or a
    /// repo appears twice and dragging one copy moves both.
    static func arrange(_ projects: [Project], sections: [Section]) -> [Shelf] {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var taken: Set<String> = []
        var shelves: [Shelf] = []

        for section in sections {
            var members: [Project] = []
            for id in section.projectIDs where !taken.contains(id) {
                guard let project = byID[id] else { continue }
                taken.insert(id)
                members.append(project)
            }
            // Kept even when empty: an empty section is the thing you just
            // made and are about to drag repos into, and one that vanished
            // between the making and the dragging would be a bug.
            shelves.append(Shelf(
                id: section.id,
                name: section.name,
                projects: members.sorted {
                    $0.sortKey == $1.sortKey ? $0.id < $1.id : $0.sortKey < $1.sortKey
                }
            ))
        }

        let rest = projects.filter { !taken.contains($0.id) }
        // No sections at all means no bands: the list looks exactly as it did
        // before anyone made one, which is the point — the feature stays
        // invisible until it's used.
        if !rest.isEmpty || sections.isEmpty {
            shelves.append(Shelf(id: "", name: nil, projects: rest))
        }
        return shelves
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    // MARK: - Scanning

    /// Directory names never worth walking into: package caches and build
    /// output, which hold thousands of folders and occasionally a vendored
    /// `.git` that is nobody's project.
    private static let skipped: Set<String> = [
        "node_modules", "Pods", "Carthage", "vendor", "target", "build", "Build",
        "DerivedData", "Library", "Applications", ".build", "dist", "venv",
        "__pycache__", "Pictures", "Music", "Movies",
    ]

    /// Every git repository under a folder, the folder itself included.
    ///
    /// Stops at each repository rather than walking through it — a repo's own
    /// subfolders are its working tree, and submodules are the repo's business
    /// and not a row in this list. Depth-limited because the natural thing to
    /// point this at is `~`, and an unbounded walk of a home directory is a
    /// minute of disk for a list nobody asked to be that long.
    static func scan(root: String, maxDepth: Int = 4, limit: Int = 2000) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        var queue: [(path: String, depth: Int)] = [(root, 0)]

        while !queue.isEmpty, found.count < limit {
            let (path, depth) = queue.removeFirst()
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if gitDirectory(ofRepoAt: path) != nil {
                found.append(path)
                continue
            }
            guard depth < maxDepth else { continue }
            let children = (try? manager.contentsOfDirectory(atPath: path)) ?? []
            for name in children.sorted() where !name.hasPrefix(".") && !skipped.contains(name) {
                queue.append(((path as NSString).appendingPathComponent(name), depth + 1))
            }
        }
        return found
    }

    /// Newest first, never-opened last, ties by a key that can't repeat.
    private static func recency<T>(
        _ date: KeyPath<T, Date?>,
        tie: KeyPath<T, String>
    ) -> (T, T) -> Bool {
        { lhs, rhs in
            let left = lhs[keyPath: date]
            let right = rhs[keyPath: date]
            if left != right {
                guard let left else { return false }
                guard let right else { return true }
                return left > right
            }
            return lhs[keyPath: tie] < rhs[keyPath: tie]
        }
    }
}
