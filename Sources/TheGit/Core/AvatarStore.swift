import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// File scope, so it is not main-actor isolated: the download path needs
/// the directory from a background task, and it's an immutable URL.
private enum AvatarCacheDir {
    static let url: URL? = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        // Versioned: the GitLab lookup used to cache a generated identicon
        // for every author it couldn't resolve, and those files would
        // otherwise outlive the fix forever.
        let root = caches.appendingPathComponent("TheGit/avatars", isDirectory: true)
        let dir = root.appendingPathComponent("v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for stale in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? [] where stale.lastPathComponent != "v2" {
            try? FileManager.default.removeItem(at: stale)
        }
        return dir
    }()
}

/// The project's GitLab members, fetched once per repo per run and reused
/// by every author in its graph. Without this, a graph with thirty authors
/// meant thirty `glab` processes at 200ms each; with it, one call usually
/// answers all of them.
///
/// An actor, not a dictionary on the store: the lookups run six at a time
/// off the main actor, and the `Task` handle is what makes the losers of
/// that race wait for the winner's answer instead of each fetching a copy.
private actor GitLabMembers {
    static let shared = GitLabMembers()

    private var cached: [String: [String: URL]] = [:]
    private var loading: [String: Task<[String: URL], Never>] = [:]

    func directory(repoPath: String, glab: String) async -> [String: URL] {
        if let done = cached[repoPath] { return done }
        if let task = loading[repoPath] { return await task.value }

        let task = Task {
            // `:id` is glab's placeholder for the repo in the working
            // directory. One page: past a hundred members the long tail
            // falls back to a lookup of its own, which is cheaper than
            // paging through a company-wide group on every launch.
            guard let out = await AvatarStore.glabAPI(
                glab, "projects/:id/members/all?per_page=100", repoPath
            ) else { return [String: URL]() }
            return AvatarStore.gitlabDirectory(out)
        }
        loading[repoPath] = task
        let directory = await task.value
        cached[repoPath] = directory
        loading[repoPath] = nil
        return directory
    }
}

/// Author avatars for the graph nodes. Off by default: this is the only
/// thing in the app that talks to a server other than the user's own git
/// remote, and a git client shouldn't phone home unless it's asked to.
///
/// Every failure path ends at the initials node. Nothing reaches the
/// renderer unless it decoded to a real bitmap first — a broken-image
/// placeholder inside a 16pt circle is worse than no avatar at all.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    static let defaultsKey = "TheGit.avatars"

    /// The single source of truth for the feature, persisted to
    /// UserDefaults. It lives here rather than in an `@AppStorage` on the
    /// App struct because a Toggle in `.commands` binds to a copy of that
    /// struct and its writes go nowhere; a shared object resolves to the
    /// real thing from any menu.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey) }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// Bumped when freshly loaded avatars are ready. Views observing the
    /// store redraw on the change; the bump is coalesced so a screenful of
    /// arrivals costs one redraw instead of thirty.
    @Published private(set) var version = 0

    /// A plain dictionary, deliberately not NSCache: NSCache dumps its
    /// entire contents on memory pressure — a swift build in a terminal is
    /// enough — and every dump made visible rows fall back to initials,
    /// reload from disk, swap back, and repeat on the next refresh. In an
    /// active repo (FSEvents firing constantly) that alternation reads as
    /// the whole graph's avatars flickering. 64px images are ~16KB each;
    /// even a thousand authors is a few MB, cheap insurance against that.
    private var memory: [String: NSImage] = [:]
    /// Soft cap for pathological repos (unique bot emails per commit).
    /// Trimming re-flashes the trimmed rows once, so it triggers rarely
    /// and drops a batch, not one-by-one at the boundary.
    private static let memoryLimit = 1200

    /// Keys with no usable avatar. 404s are also written to disk so the
    /// miss survives a restart; network failures stay in memory only, or
    /// going back online would never recover.
    private var missing: Set<String> = []
    private var inFlight: Set<String> = []
    private var bump: Task<Void, Never>?

    // MARK: - Lookup

    /// What the caller knows about its repo's forge. Detection shells out to
    /// `git remote` and has to find the CLI, so the graph is already on
    /// screen asking for avatars before the answer arrives — "not known
    /// yet" is a real state, and one that must not be mistaken for "this
    /// repo has no GitLab to ask", or the lookup that owns every
    /// self-hosted avatar would silently never run.
    enum ForgeContext {
        case unknown
        case none
        case gitlab(repoPath: String)

        var repoPath: String? {
            if case .gitlab(let path) = self { return path }
            return nil
        }

        var isResolved: Bool {
            if case .unknown = self { return false }
            return true
        }
    }

    /// The avatar for an author, or nil while it loads — and nil forever if
    /// it can't be loaded. Callers draw initials whenever this is nil, so
    /// there is no state in which a failure is visible as a failure.
    ///
    /// A self-hosted GitLab instance is the only place its users' uploaded
    /// avatars exist — Gravatar has never heard of them — so a GitLab repo
    /// gets asked first, through `glab`, exactly like the PR list does.
    /// `name` is the commit's author name, which is what that lookup
    /// matches on.
    func avatar(
        for email: String, name: String = "", forge: ForgeContext = .unknown
    ) -> Image? {
        guard let key = Self.key(for: email) else { return nil }
        if let cached = memory[key] {
            return Image(nsImage: cached)
        }
        // Detection is still running. Nothing is fetched and nothing is
        // recorded: a miss taken now would be a miss taken without the one
        // source that holds this repo's uploaded avatars, and it would
        // outlive the answer. The view redraws when `forge` lands.
        guard forge.isResolved else { return nil }
        guard !missing.contains(key), !inFlight.contains(key),
              !waiting.contains(where: { $0.key == key })
        else { return nil }
        load(key: key, email: Self.normalize(email), name: name, forge: forge)
        return nil
    }

    /// Scrolling fast through a repo with many authors would otherwise
    /// spawn a `glab` process per visible row; six at a time is plenty to
    /// fill a screen without a process storm.
    private static let maxConcurrent = 6
    private var waiting: [(key: String, email: String, name: String, forge: ForgeContext)] = []

    private func load(key: String, email: String, name: String, forge: ForgeContext) {
        guard inFlight.count < Self.maxConcurrent else {
            waiting.append((key, email, name, forge))
            return
        }
        inFlight.insert(key)
        Task {
            let data = await Self.fetch(
                key: key, email: email, name: name, forge: forge
            )
            inFlight.remove(key)
            // Decode on the main actor, and only trust it if AppKit agrees
            // with the earlier check — two independent decodes is cheap
            // insurance against ever drawing a torn image.
            if let data, let image = NSImage(data: data), image.size.width > 0 {
                if memory.count >= Self.memoryLimit {
                    for key in memory.keys.prefix(Self.memoryLimit / 4) {
                        memory.removeValue(forKey: key)
                    }
                }
                memory[key] = image
                scheduleBump()
            } else {
                missing.insert(key)
            }
            if !waiting.isEmpty {
                let next = waiting.removeFirst()
                load(
                    key: next.key, email: next.email,
                    name: next.name, forge: next.forge
                )
            }
        }
    }

    private func scheduleBump() {
        guard bump == nil else { return }
        bump = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.bump = nil
            self?.version &+= 1
        }
    }

    // MARK: - Fetching (off the main actor)

    /// Disk, then the repo's own GitLab, then Gravatar, then GitHub for
    /// noreply addresses. Returns the image bytes only when they decode.
    private nonisolated static func fetch(
        key: String, email: String, name: String, forge: ForgeContext
    ) async -> Data? {
        if let cached = diskRead(key) { return cached }
        if diskHasMiss(key) { return nil }

        var candidates: [URL] = []
        if let repoPath = forge.repoPath {
            candidates += await gitlabAvatarURLs(
                name: name, email: email, repoPath: repoPath
            )
        }
        candidates += sources(key: key, email: email)

        var permanentMiss = false
        for url in candidates {
            switch await download(url) {
            case .image(let data):
                diskWrite(key, data)
                return data
            case .notFound:
                // The server answered and said no. Worth remembering.
                permanentMiss = true
            case .failed:
                // Offline or a bad response — don't record anything, so a
                // later run can still succeed.
                break
            }
        }
        if permanentMiss { diskWriteMiss(key) }
        return nil
    }

    private enum Outcome {
        case image(Data)
        case notFound
        case failed
    }

    private nonisolated static func download(_ url: URL) async -> Outcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }
        if http.statusCode == 404 || http.statusCode == 403 { return .notFound }
        guard http.statusCode == 200, isDecodableImage(data) else { return .failed }
        return .image(data)
    }

    /// A real decode attempt, not a content-type check: servers lie, and a
    /// truncated or HTML-error body must never reach the renderer.
    /// CGImageSource so this stays safe off the main thread.
    nonisolated static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }
        return true
    }

    // MARK: - GitLab

    /// `glab` owns the host and the token, same as the PR list — we only
    /// read avatar URLs out of its replies.
    ///
    /// The obvious endpoint, `/avatar?email=`, turns out to be a trap: it
    /// matches only a user's *public* email, which on a company instance
    /// almost nobody sets, so it answers with a Gravatar identicon URL for
    /// everyone. That URL decodes to a real image, which is worse than
    /// failing — the graph fills with generated patterns while the actual
    /// uploaded faces sit one call away.
    ///
    /// So the author is resolved to a GitLab *user* instead. The project's
    /// member list already carries every colleague's uploaded avatar, so
    /// one call answers a whole graph; only an author who isn't a member —
    /// someone who has left, or committed through a fork — costs a lookup
    /// of their own.
    private nonisolated static func gitlabAvatarURLs(
        name: String, email: String, repoPath: String
    ) async -> [URL] {
        guard let glab = Shell.which("glab") else { return [] }
        let terms = gitlabSearchTerms(name: name, email: email)

        let members = await GitLabMembers.shared.directory(repoPath: repoPath, glab: glab)
        for term in terms {
            if let url = members[term.lowercased()] { return [url] }
        }

        for term in terms {
            guard let escaped = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let out = await glabAPI(glab, "users?search=\(escaped)", repoPath),
                  let url = gitlabUserAvatar(out, name: name, email: email)
            else { continue }
            return [url]
        }
        return []
    }

    fileprivate nonisolated static func glabAPI(
        _ glab: String, _ endpoint: String, _ repoPath: String
    ) async -> String? {
        try? await Shell.run(
            glab,
            ["api", endpoint],
            cwd: repoPath,
            env: ["NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
        )
    }

    /// Username and full name, both lower-cased, to the member's avatar. A
    /// name two members share is dropped rather than guessed at — the same
    /// rule the per-author lookup follows.
    nonisolated static func gitlabDirectory(_ output: String) -> [String: URL] {
        guard let data = output.data(using: .utf8),
              let users = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }

        var directory: [String: URL] = [:]
        var ambiguous: Set<String> = []
        for user in users {
            guard let raw = user["avatar_url"] as? String, !raw.isEmpty,
                  let url = normalizedAvatarURL(raw)
            else { continue }
            for field in ["username", "name"] {
                guard let value = (user[field] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !value.isEmpty, !ambiguous.contains(value)
                else { continue }
                if let existing = directory[value], existing != url {
                    directory[value] = nil
                    ambiguous.insert(value)
                } else {
                    directory[value] = url
                }
            }
        }
        return directory
    }

    /// What to search the user list for: the commit's author name, then the
    /// local part of its address. Between them they cover both conventions
    /// a git config picks up — a display name ("Simon He") and a login
    /// ("zhangjunyi@acme.com" for the user `zhangjunyi`).
    nonisolated static func gitlabSearchTerms(name: String, email: String) -> [String] {
        var terms: [String] = []
        for candidate in [name, String(email.prefix(while: { $0 != "@" }))] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { continue }
            terms.append(trimmed)
        }
        return terms
    }

    /// GitLab's search is a substring match, so a short name comes back
    /// with strangers attached. Only an exact hit on a username or a full
    /// name counts, and only when exactly one user has it — showing the
    /// wrong person's face is a worse failure than showing initials.
    nonisolated static func gitlabUserAvatar(
        _ output: String, name: String, email: String
    ) -> URL? {
        guard let data = output.data(using: .utf8),
              let users = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for term in gitlabSearchTerms(name: name, email: email) {
            let matches = users.filter { user in
                [user["username"] as? String, user["name"] as? String]
                    .contains { $0?.caseInsensitiveCompare(term) == .orderedSame }
            }
            guard matches.count == 1,
                  let raw = matches[0]["avatar_url"] as? String, !raw.isEmpty
            else { continue }
            return normalizedAvatarURL(raw)
        }
        return nil
    }

    /// Used verbatim. When the forge answers, it is the authority on what
    /// that person looks like — including the identicon it picks for users
    /// who never uploaded anything, which is exactly what GitLab's own web
    /// UI shows. We only insist on a *real* avatar further down, where we
    /// are guessing at Gravatar from an email rather than being told.
    ///
    /// Only the size is nudged: GitLab defaults to 128 and the node is 16.
    nonisolated static func normalizedAvatarURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        guard components.host?.contains("gravatar.com") == true else {
            return components.url
        }
        var items = (components.queryItems ?? []).filter { $0.name != "s" && $0.name != "size" }
        items.append(URLQueryItem(name: "s", value: "64"))
        components.queryItems = items
        return components.url
    }

    // MARK: - URLs

    /// `d=404` makes Gravatar answer with a status instead of a generated
    /// silhouette, so "no avatar" is distinguishable from "here's a
    /// placeholder" — otherwise every author would get a stranger's face.
    nonisolated static func sources(key: String, email: String) -> [URL] {
        var urls: [URL] = []
        if let gravatar = URL(string: "https://www.gravatar.com/avatar/\(key)?d=404&s=64") {
            urls.append(gravatar)
        }
        if let user = githubUsername(from: email),
           let escaped = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let github = URL(string: "https://avatars.githubusercontent.com/\(escaped)?s=64") {
            urls.append(github)
        }
        return urls
    }

    /// "1234567+octocat@users.noreply.github.com" -> "octocat".
    nonisolated static func githubUsername(from email: String) -> String? {
        let suffix = "@users.noreply.github.com"
        guard email.hasSuffix(suffix) else { return nil }
        var local = String(email.dropLast(suffix.count))
        if let plus = local.firstIndex(of: "+") {
            local = String(local[local.index(after: plus)...])
        }
        return local.isEmpty ? nil : local
    }

    nonisolated static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Gravatar's key: md5 of the trimmed, lower-cased address.
    nonisolated static func key(for email: String) -> String? {
        let normalized = normalize(email)
        guard normalized.contains("@") else { return nil }
        return Insecure.MD5.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Disk

    private nonisolated static func diskRead(_ key: String) -> Data? {
        guard let url = AvatarCacheDir.url?.appendingPathComponent("\(key).png"),
              let data = try? Data(contentsOf: url),
              isDecodableImage(data)
        else { return nil }
        return data
    }

    private nonisolated static func diskWrite(_ key: String, _ data: Data) {
        guard let url = AvatarCacheDir.url?.appendingPathComponent("\(key).png") else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Zero-byte marker: this address has no avatar, don't ask again.
    private nonisolated static func diskHasMiss(_ key: String) -> Bool {
        guard let url = AvatarCacheDir.url?.appendingPathComponent("\(key).404") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private nonisolated static func diskWriteMiss(_ key: String) {
        guard let url = AvatarCacheDir.url?.appendingPathComponent("\(key).404") else { return }
        try? Data().write(to: url, options: .atomic)
    }
}
