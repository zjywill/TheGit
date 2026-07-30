import CryptoKit
import Foundation

/// Last launch's answers, on disk, so this launch has something to draw
/// before git has been asked anything.
///
/// Every git client that feels instant is doing this: the window comes back
/// exactly as it was left, and the subprocesses that verify it run behind
/// what's already on screen. Without it the first second of the app is an
/// empty three-pane window and a spinner, no matter how fast the reads are —
/// nine subprocesses over a large repo is a few hundred milliseconds at
/// best, and `gh`'s network round trip is seconds.
///
/// Two files per repo, deliberately. A summary is what the Dashboard's wall
/// needs — one small file per card, and the wall reads every repo's at
/// launch — while a snapshot is the whole three-pane view of one repo and
/// only the tab that opens pays to read it.
///
/// Everything here is derivable from the repository, so it lives in
/// `~/Library/Caches` and losing it costs a slower launch and nothing else.
/// Same shape as `AvatarStore`'s cache: a versioned directory, atomic
/// writes, and old versions swept on first use.
enum RepoCache {
    /// Bumped when the stored shape changes in a way an older file can't be
    /// read as. Cheaper than migrating a cache whose worst failure is one
    /// slow launch.
    private static let version = "v1"

    /// A file older than this is ignored and deleted. A repo untouched for a
    /// fortnight has almost certainly moved on, and showing a fortnight-old
    /// graph for the half second before the refresh lands is worse than
    /// showing nothing: it's wrong, and it looks authoritative.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    /// The log window a cached snapshot keeps. `RepoState.logLimit` starts
    /// at 500 and only grows when the user scrolls for it; storing the grown
    /// window would mean a multi-megabyte file to redraw a screen that shows
    /// forty rows.
    static let commitLimit = 500

    /// Where the files live. A `var` for exactly one reason: `prune` deletes
    /// everything it wasn't told to keep, and a test suite that ran it
    /// against the real directory would wipe the caches of the repos the
    /// person running the tests has open. The tests point this at a
    /// temporary directory; nothing in the app ever assigns to it.
    nonisolated(unsafe) static var dir: URL? = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let root = caches.appendingPathComponent("TheGit/repos", isDirectory: true)
        let dir = root.appendingPathComponent(version, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for stale in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? [] where stale.lastPathComponent != version {
            try? FileManager.default.removeItem(at: stale)
        }
        return dir
    }()

    // MARK: - Stored shapes

    /// The three-pane view of one repo. `savedAt` is the file's own, not the
    /// snapshot's: `RepoSnapshot` has no timestamp, and staleness is a
    /// property of the cache rather than of the data.
    struct SnapshotFile: Codable {
        var savedAt: Date
        var snapshot: RepoSnapshot
    }

    /// What the Dashboard and the sidebar's forge sections need, small
    /// enough that every known repo's copy is read at launch.
    ///
    /// The forge fields carry their own `prsLoadedAt` so the in-memory TTL
    /// that already guards `gh`/`glab` keeps working across a restart —
    /// quitting and reopening within the minute no longer costs a network
    /// round trip per repo.
    struct Summary: Codable {
        var savedAt: Date
        var card: RepoState.Card?
        /// When the card was read from git, so its own freshness window
        /// survives too.
        var cardLoadedAt: Date?
        /// A year of commits per day — the Dashboard's summed heatmap, which
        /// otherwise says "Reading…" on every launch.
        var yearActivity: [Int: Int]?
        var yearActivityAt: Date?
        /// The remote's forge, and the case where its CLI is missing.
        /// Detection is two `git remote` reads plus a `which`, and its
        /// answer changes about as often as the remote does.
        var forge: Forge?
        var missingForgeCLI: Forge?
        var pullRequests: [PullRequest] = []
        var issues: [Issue]?
        var prsLoadedAt: Date?
    }

    // MARK: - Reading

    /// Nonisolated on purpose: both loads decode JSON off the main actor,
    /// which is the point of doing this at all.
    static func loadSnapshot(path: String) -> RepoSnapshot? {
        guard let file: SnapshotFile = read(path: path, kind: .snapshot),
              !file.snapshot.commits.isEmpty
        else { return nil }
        return file.snapshot
    }

    static func loadSummary(path: String) -> Summary? {
        read(path: path, kind: .summary)
    }

    // MARK: - Writing

    static func saveSnapshot(_ snapshot: RepoSnapshot, path: String) {
        // A repo with no commits has nothing worth restoring, and writing an
        // empty snapshot would overwrite a good one during the moment a
        // refresh has failed.
        guard !snapshot.commits.isEmpty else { return }
        var trimmed = snapshot
        if trimmed.commits.count > commitLimit {
            trimmed.commits = Array(trimmed.commits.prefix(commitLimit))
        }
        write(SnapshotFile(savedAt: Date(), snapshot: trimmed), path: path, kind: .snapshot)
    }

    static func saveSummary(_ summary: Summary, path: String) {
        write(summary, path: path, kind: .summary)
    }

    // MARK: - Eviction

    /// Forget a repo the user removed from the library. Nothing here is
    /// precious, but a cache that only ever grows is a cache that leaks.
    static func forget(path: String) {
        guard let dir else { return }
        for kind in Kind.allCases {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name(path, kind)))
        }
    }

    /// Drop files for repos the library no longer lists. Removal goes
    /// through `forget`, so this only ever collects what an older build,
    /// a crash, or a hand-edited preference left behind.
    static func prune(keeping paths: [String]) {
        guard let dir else { return }
        let live = Set(paths.flatMap { path in Kind.allCases.map { name(path, $0) } })
        for file in (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? [] where !live.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Files

    enum Kind: String, CaseIterable {
        case snapshot
        case summary
    }

    /// The repo's path, hashed, plus its folder name in the clear — the hash
    /// is what keeps two repos called "app" apart, the name is what makes
    /// the directory readable when something needs debugging.
    static func name(_ path: String, _ kind: Kind) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let folder = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return "\(folder.prefix(40))-\(digest).\(kind.rawValue).json"
    }

    private static func read<T: Decodable>(path: String, kind: Kind) -> T? {
        guard let dir else { return nil }
        let url = dir.appendingPathComponent(name(path, kind))
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Decoded before the age check because the timestamp is inside the
        // file; a file we can't read at all is also one to drop.
        guard let value = try? JSONDecoder().decode(T.self, from: data),
              let savedAt = (value as? Aged)?.savedAt,
              Date().timeIntervalSince(savedAt) < maxAge
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return value
    }

    private static func write<T: Encodable>(_ value: T, path: String, kind: Kind) {
        guard let dir, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name(path, kind)), options: .atomic)
    }
}

/// How `read` gets at a stored file's timestamp without knowing which shape
/// it decoded.
protocol Aged {
    var savedAt: Date { get }
}

extension RepoCache.SnapshotFile: Aged {}
extension RepoCache.Summary: Aged {}
