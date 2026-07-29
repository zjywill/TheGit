import AppKit
import Foundation

/// A release version, compared the way releases are compared rather than the
/// way strings are: "0.10.0" is newer than "0.9.0", which `<` on String gets
/// backwards. Only MAJOR.MINOR.PATCH is understood — the tags this project
/// cuts are exactly that shape, and a tag that isn't parses to nil so an
/// unexpected one is ignored instead of triggering a bogus "update".
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Accepts an optional leading "v" so a git tag and a
    /// CFBundleShortVersionString can both be fed in unchanged.
    init?(_ raw: String?) {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Checks GitHub Releases for a newer TheGit and, when there is one, hands
/// the window a banner to show.
///
/// Deliberately not Sparkle: that wants a signed, notarised bundle and an
/// appcast to swap it in place. This app is ad-hoc signed, so it can only
/// ever *tell* you a release exists and open its page — an in-place download
/// would install something Gatekeeper then refuses, which is a worse outcome
/// than a browser tab. The whole update path is therefore read-only.
///
/// On by default and with no preference to turn it off: unlike author
/// avatars, which reach a server per commit author, this is one request to
/// the project's own repo at launch, and a Git client that silently rots is
/// the failure this exists to prevent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update: Equatable {
        let version: SemanticVersion
        /// The release page, not the .dmg. The page carries the release
        /// notes *and* the first-launch instructions the DMG needs.
        let page: URL
    }

    /// The outcome of a check the user explicitly asked for. A background
    /// check leaves this nil — nobody wants an "up to date" dialog they
    /// didn't ask for.
    enum ManualResult {
        case upToDate(SemanticVersion)
        case failed(String)

        var title: String {
            switch self {
            case .upToDate: "You're up to date"
            case .failed: "Couldn't check for updates"
            }
        }

        var message: String {
            switch self {
            case .upToDate(let version): "TheGit \(version) is the latest release."
            case .failed(let message): message
            }
        }
    }

    /// Non-nil only when a newer release exists and the user hasn't waved
    /// this particular version away.
    @Published private(set) var update: Update?
    @Published var manualResult: ManualResult?
    @Published private(set) var isChecking = false

    private static let latestEndpoint =
        URL(string: "https://api.github.com/repos/zjywill/TheGit/releases/latest")!
    private static let skippedKey = "TheGit.skippedUpdate"
    private static let lastCheckKey = "TheGit.lastUpdateCheck"
    /// Long enough that launching the app ten times in a morning is one
    /// request, short enough that a day-old release still surfaces.
    private static let backgroundInterval: TimeInterval = 6 * 60 * 60

    /// The running app's version, or nil under `swift run`, where there is
    /// no bundle and therefore no version to compare against. Dev builds
    /// never check — being told to "upgrade" to the release you are
    /// currently editing is pure noise.
    static var current: SemanticVersion? {
        SemanticVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// Launch-time check: silent about everything except an actual update,
    /// and throttled so it isn't a request per launch.
    func checkInBackground() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > Self.backgroundInterval else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        Task { await check(manual: false) }
    }

    /// The menu item. Reports either way, and ignores a previous "skip" —
    /// asking for the check *is* taking back the dismissal.
    func checkNow() {
        UserDefaults.standard.removeObject(forKey: Self.skippedKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task { await check(manual: true) }
    }

    /// Hide this version's banner for good. The next release brings its own
    /// version string and so gets a fresh banner.
    func skipCurrentUpdate() {
        if let update {
            UserDefaults.standard.set(update.version.description, forKey: Self.skippedKey)
        }
        update = nil
    }

    func openReleasePage() {
        guard let update else { return }
        NSWorkspace.shared.open(update.page)
        // The banner has done its job; leaving it up nags someone who is
        // already looking at the download page.
        skipCurrentUpdate()
    }

    private func check(manual: Bool) async {
        guard let current = Self.current else {
            if manual {
                manualResult = .failed(
                    "This build has no version number — it was run from source, not installed."
                )
            }
            return
        }
        isChecking = true
        defer { isChecking = false }

        switch await Self.fetchLatest() {
        case .failure(let message):
            if manual { manualResult = .failed(message) }
        case .success(let latest):
            guard latest.version > current else {
                if manual { manualResult = .upToDate(current) }
                return
            }
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if !manual, skipped == latest.version.description { return }
            update = latest
        }
    }

    private enum FetchResult {
        case success(Update)
        case failure(String)
    }

    private nonisolated static func fetchLatest() async -> FetchResult {
        var request = URLRequest(url: latestEndpoint)
        request.timeoutInterval = 10
        // GitHub rejects API requests without a User-Agent, and the version
        // header pins the response shape against a future API change.
        request.setValue("TheGit", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure("Couldn't reach GitHub — check your network.") }

        // 404 is the answer when the repo has no published release yet, not
        // an error worth a dialog: there is simply nothing newer.
        if http.statusCode == 404 { return .failure("No releases published yet.") }
        if http.statusCode == 403 || http.statusCode == 429 {
            return .failure("GitHub is rate-limiting this network. Try again later.")
        }
        guard http.statusCode == 200 else {
            return .failure("GitHub answered with HTTP \(http.statusCode).")
        }
        guard let latest = parseLatest(data) else {
            return .failure("Couldn't read GitHub's answer.")
        }
        return .success(latest)
    }

    /// Split out from the request so the parsing is testable without a
    /// network: `tag_name` is what the release script pushes, `html_url` is
    /// the page a human should land on.
    nonisolated static func parseLatest(_ data: Data) -> Update? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = SemanticVersion(json["tag_name"] as? String),
              // A draft release is visible to the author's token and to
              // nobody else; treating one as shipped points every user at a
              // page they'd get a 404 from.
              (json["draft"] as? Bool) != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return Update(version: version, page: page)
    }
}
