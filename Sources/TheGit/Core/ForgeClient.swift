import Foundation

/// A pull request (GitHub) or merge request (GitLab), as the CLI reports it.
struct PullRequest: Identifiable, Hashable {
    let number: Int
    let title: String
    let branch: String
    let author: String
    let isDraft: Bool
    let url: String

    var id: Int { number }
}

/// Which CLI drives a repo's pull requests. We never speak to an API
/// ourselves: hosts, tokens and OAuth stay the CLI's problem, exactly like
/// the git engine stays the git binary's problem.
enum Forge: String {
    case github
    case gitlab

    var binary: String { self == .github ? "gh" : "glab" }
    /// Sidebar section title.
    var sectionTitle: String { self == .github ? "Pull Requests" : "Merge Requests" }
    var itemNoun: String { self == .github ? "Pull Request" : "Merge Request" }
    /// Prefix users recognise: #12 on GitHub, !12 on GitLab.
    var numberPrefix: String { self == .github ? "#" : "!" }

    /// Always build the label with String(), never by interpolating the
    /// Int into a Text(): SwiftUI localises numbers there and !1001
    /// renders as "!1,001".
    func label(_ number: Int) -> String { numberPrefix + String(number) }
    var loginHint: String { self == .github ? "gh auth login" : "glab auth login" }
}

/// A forge CLI failure, split in two: one plain line the sidebar can show
/// on a narrow row, and the CLI's own words for the tooltip and alerts.
/// Raw `glab` stderr is a Go networking sentence — useless at 10pt, wrapped
/// to three lines, and it buries the one thing the user can act on.
struct ForgeFailure: Equatable {
    let summary: String
    let detail: String

    /// The two failures worth naming. Everything else keeps the CLI's own
    /// first line: guessing at an unknown error reads worse than quoting it.
    static func describe(_ error: Error, forge: Forge, host: String?) -> ForgeFailure {
        let detail = error.localizedDescription
        // The command prefix ("glab mr list: ") is context for the tooltip,
        // noise in a one-line summary.
        let raw = (error as? ShellError)?.message ?? detail
        let lowered = raw.lowercased()
        let place = host ?? (forge == .github ? "GitHub" : "GitLab")

        // Offline first: a box that can't route to the host also can't
        // authenticate, and "check the VPN" is the useful half of that.
        if offlineMarkers.contains(where: lowered.contains) {
            return ForgeFailure(
                summary: "Can't reach \(place) — check your network or VPN.",
                detail: detail
            )
        }
        if authMarkers.contains(where: lowered.contains) {
            return ForgeFailure(
                summary: "Not signed in to \(place) — run `\(forge.loginHint)`.",
                detail: detail
            )
        }
        return ForgeFailure(summary: firstLine(raw), detail: detail)
    }

    /// What an alert shows: the plain line, then the CLI's own text under it.
    var alertText: String { summary == detail ? detail : summary + "\n\n" + detail }

    private static let offlineMarkers = [
        "dial tcp", "no such host", "i/o timeout", "connection refused",
        "network is unreachable", "no route to host", "connection reset",
        "tls handshake", "x509", "proxyconnect", "server misbehaving",
        "context deadline exceeded", "timeout", "unexpected eof",
        "temporary failure in name resolution", "could not resolve host",
    ]

    private static let authMarkers = [
        "401", "403", "unauthorized", "forbidden", "authenticat",
        "log in", "token", "credential",
    ]

    /// First line with anything in it, minus the CLI's own "ERROR:" shout,
    /// clipped to something a sidebar row can hold.
    private static func firstLine(_ text: String) -> String {
        var line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
        for shout in ["ERROR: ", "error: ", "ERROR ", "FATAL: "] where line.hasPrefix(shout) {
            line = String(line.dropFirst(shout.count))
            break
        }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}

// MARK: - CLI JSON shapes

/// Turns `gh` / `glab` JSON into `PullRequest`, mirroring `GitParsers`.
enum ForgeParsers {
    /// Host out of any remote URL form: `git@host:o/r.git`,
    /// `ssh://git@host/o/r`, `https://user@host/o/r`.
    static func host(of url: String) -> String {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        let end = rest.firstIndex { $0 == "/" || $0 == ":" } ?? rest.endIndex
        return String(rest[..<end])
    }

    static func forge(forHost host: String) -> Forge? {
        let host = host.lowercased()
        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        return nil
    }

    static func pullRequests(_ output: String, forge: Forge) throws -> [PullRequest] {
        // Some CLI versions print a human line before the JSON; start at the
        // first bracket so a stray banner doesn't kill the whole list. No
        // bracket at all means an empty list, not a failure.
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = output[start...].data(using: .utf8)
        else { return [] }
        do {
            switch forge {
            case .github:
                return try JSONDecoder().decode([GHPullRequest].self, from: data).map {
                    PullRequest(
                        number: $0.number,
                        title: $0.title,
                        branch: $0.headRefName,
                        author: $0.author?.login ?? "",
                        isDraft: $0.isDraft,
                        url: $0.url
                    )
                }
            case .gitlab:
                return try JSONDecoder().decode([GLMergeRequest].self, from: data)
                    .compactMap { mr in
                        guard let number = mr.iid ?? mr.id else { return nil }
                        let draft = mr.draft ?? mr.workInProgress ?? false
                        return PullRequest(
                            number: number,
                            // GitLab encodes draft status in the title too;
                            // with a draft badge on the row that prefix is
                            // pure noise eating into a narrow column.
                            title: draft ? ForgeParsers.stripDraftPrefix(mr.title) : mr.title,
                            branch: mr.sourceBranch ?? "",
                            author: mr.author?.username ?? "",
                            isDraft: draft,
                            url: mr.webURL ?? ""
                        )
                    }
            }
        } catch {
            throw ShellError(
                command: forge.binary,
                message: "Could not read the \(forge.itemNoun.lowercased()) list: \(error)"
            )
        }
    }

    /// The created PR's address out of the CLI's chatter: both `gh` and
    /// `glab` print it on its own line, surrounded by human sentences that
    /// differ per version. No URL is not a failure — the caller just has
    /// nothing to open.
    static func webURL(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
                return trimmed
            }
        }
        return nil
    }

    /// "Draft: fix things" -> "fix things". WIP: is the older spelling.
    static func stripDraftPrefix(_ title: String) -> String {
        for prefix in ["Draft: ", "draft: ", "WIP: ", "wip: "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }
}

private struct GHPullRequest: Decodable {
    struct Author: Decodable { let login: String? }
    let number: Int
    let title: String
    let headRefName: String
    let author: Author?
    let isDraft: Bool
    let url: String
}

/// GitLab's REST shape, straight through `glab mr list --output json`.
/// Everything but the title is optional: glab has changed field names
/// across versions (draft / work_in_progress), and a missing field should
/// degrade the row, not fail the whole list.
private struct GLMergeRequest: Decodable {
    struct Author: Decodable { let username: String? }
    let iid: Int?
    let id: Int?
    let title: String
    let sourceBranch: String?
    let author: Author?
    let draft: Bool?
    let workInProgress: Bool?
    let webURL: String?

    enum CodingKeys: String, CodingKey {
        case iid, id, title, author, draft
        case sourceBranch = "source_branch"
        case workInProgress = "work_in_progress"
        case webURL = "web_url"
    }
}

/// Shells out to `gh` / `glab`. Serialized by the actor like GitClient, so
/// a checkout can't race a list refresh.
actor ForgeClient {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    /// The forge for a repo, or nil when the host isn't one we know or its
    /// CLI isn't installed — in which case the whole feature stays invisible.
    static func detect(remoteURL: String) -> Forge? {
        guard let forge = ForgeParsers.forge(forHost: ForgeParsers.host(of: remoteURL)) else {
            return nil
        }
        return Shell.which(forge.binary) == nil ? nil : forge
    }

    // MARK: - Queries

    func pullRequests(_ forge: Forge, limit: Int = 30) async throws -> [PullRequest] {
        let args: [String]
        switch forge {
        case .github:
            args = [
                "pr", "list",
                "--json", "number,title,headRefName,author,isDraft,url",
                "--limit", String(limit),
            ]
        case .gitlab:
            args = ["mr", "list", "--output", "json", "--per-page", String(limit)]
        }
        return try ForgeParsers.pullRequests(try await run(forge, args), forge: forge)
    }

    /// Head branch → merged PR number. The forge is the only source that
    /// *knows* a squash merge happened rather than inferring it, so this is
    /// the strongest cleanup signal we can get.
    func mergedBranches(_ forge: Forge, limit: Int = 50) async throws -> [String: Int] {
        let args: [String]
        switch forge {
        case .github:
            args = [
                "pr", "list", "--state", "merged",
                "--json", "number,title,headRefName,author,isDraft,url",
                "--limit", String(limit),
            ]
        case .gitlab:
            args = ["mr", "list", "--merged", "--output", "json", "--per-page", String(limit)]
        }
        let merged = try ForgeParsers.pullRequests(try await run(forge, args), forge: forge)
        return Dictionary(
            merged.filter { !$0.branch.isEmpty }.map { ($0.branch, $0.number) },
            // Same branch reused across PRs: keep the newest, which the
            // CLI lists first.
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Actions

    func checkout(_ pr: PullRequest, forge: Forge) async throws {
        try await run(forge, [forge == .github ? "pr" : "mr", "checkout", String(pr.number)])
    }

    func openInBrowser(_ pr: PullRequest, forge: Forge) async throws {
        try await run(forge, [forge == .github ? "pr" : "mr", "view", String(pr.number), "--web"])
    }

    /// Creates the PR/MR outright and returns its URL when the CLI printed
    /// one. The compose form lives in our sheet now, so the CLI runs fully
    /// non-interactive — every flag it might otherwise prompt for is given.
    func createPullRequest(
        source: String,
        target: String,
        title: String,
        body: String,
        draft: Bool,
        forge: Forge
    ) async throws -> String? {
        var args: [String]
        switch forge {
        case .github:
            args = [
                "pr", "create",
                "--head", source, "--base", target,
                "--title", title, "--body", body,
            ]
        case .gitlab:
            args = [
                "mr", "create",
                "--source-branch", source, "--target-branch", target,
                "--title", title, "--description", body,
                // glab asks "create this MR?" even with every field given.
                "--yes",
            ]
        }
        if draft { args.append("--draft") }
        return ForgeParsers.webURL(in: try await run(forge, args))
    }

    // MARK: - Plumbing

    @discardableResult
    private func run(_ forge: Forge, _ args: [String]) async throws -> String {
        guard let binary = Shell.which(forge.binary) else {
            throw ShellError(
                command: forge.binary,
                message: "\(forge.binary) is not installed."
            )
        }
        return try await Shell.run(
            binary,
            args,
            cwd: repoPath,
            env: [
                "GH_NO_UPDATE_NOTIFIER": "1",
                "GH_PAGER": "cat",
                "GLAMOUR_STYLE": "notty",
                "NO_COLOR": "1",
            ],
            label: "\(forge.binary) \(args.prefix(2).joined(separator: " "))"
        )
    }
}
