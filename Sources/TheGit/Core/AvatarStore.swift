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
        let dir = caches.appendingPathComponent("TheGit/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
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

    /// The avatar for an author, or nil while it loads — and nil forever if
    /// it can't be loaded. Callers draw initials whenever this is nil, so
    /// there is no state in which a failure is visible as a failure.
    ///
    /// `gitlabRepo` is the path of a repo whose remote is GitLab. A
    /// self-hosted instance is the only place its users' uploaded avatars
    /// exist — Gravatar has never heard of them — so that instance gets
    /// asked first, through `glab`, exactly like the PR list does.
    func avatar(for email: String, gitlabRepo: String? = nil) -> Image? {
        guard let key = Self.key(for: email) else { return nil }
        if let cached = memory[key] {
            return Image(nsImage: cached)
        }
        guard !missing.contains(key), !inFlight.contains(key),
              !waiting.contains(where: { $0.key == key })
        else { return nil }
        load(key: key, email: Self.normalize(email), gitlabRepo: gitlabRepo)
        return nil
    }

    /// Scrolling fast through a repo with many authors would otherwise
    /// spawn a `glab` process per visible row; six at a time is plenty to
    /// fill a screen without a process storm.
    private static let maxConcurrent = 6
    private var waiting: [(key: String, email: String, gitlabRepo: String?)] = []

    private func load(key: String, email: String, gitlabRepo: String?) {
        guard inFlight.count < Self.maxConcurrent else {
            waiting.append((key, email, gitlabRepo))
            return
        }
        inFlight.insert(key)
        Task {
            let data = await Self.fetch(key: key, email: email, gitlabRepo: gitlabRepo)
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
                load(key: next.key, email: next.email, gitlabRepo: next.gitlabRepo)
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
        key: String, email: String, gitlabRepo: String?
    ) async -> Data? {
        if let cached = diskRead(key) { return cached }
        if diskHasMiss(key) { return nil }

        var candidates: [URL] = []
        if let gitlabRepo, let url = await gitlabAvatarURL(email: email, repoPath: gitlabRepo) {
            candidates.append(url)
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

    /// GitLab's `/avatar?email=` answers for any address it knows, which is
    /// how a self-hosted instance's uploaded avatars become reachable at
    /// all. `glab` owns the host and the token, same as the PR list — we
    /// only read the URL out of its reply.
    private nonisolated static func gitlabAvatarURL(email: String, repoPath: String) async -> URL? {
        guard let glab = Shell.which("glab"),
              let escaped = email.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        guard let out = try? await Shell.run(
            glab,
            ["api", "avatar?email=\(escaped)&size=64"],
            cwd: repoPath,
            env: ["NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
        ) else { return nil }
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["avatar_url"] as? String, !raw.isEmpty
        else { return nil }
        return normalizedAvatarURL(raw)
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
