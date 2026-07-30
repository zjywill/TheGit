import Foundation

/// A pull request (GitHub) or merge request (GitLab), as the CLI reports it.
struct PullRequest: Identifiable, Hashable, Codable {
    let number: Int
    let title: String
    let branch: String
    let author: String
    let isDraft: Bool
    let url: String

    var id: Int { number }
}

/// An open issue, as the CLI reports it. The body comes with the list —
/// one fetch, and the viewer opens with everything but the thread.
struct Issue: Identifiable, Hashable, Codable {
    let number: Int
    let title: String
    let author: String
    let body: String
    let url: String
    let createdAt: Date?
    // `var` with a default, not `let`: the memberwise init keeps working
    // for every existing call site that predates labels.
    var labels: [IssueLabel] = []

    var id: Int { number }
}

/// A forge label. GitHub and GitLab both pick a colour per label; GitLab's
/// issue listing sends only the names, so the colour is optional and a
/// chip without one draws grey.
struct IssueLabel: Hashable, Codable {
    let name: String
    /// "a2eeef" (GitHub) or "#428BCA" (GitLab) — normalised by Color init.
    var colorHex: String? = nil
}

/// One comment on an issue's thread. GitLab calls these notes and mixes
/// system events into them; those become `IssueEvent`s — "changed the
/// description" is history, not conversation.
struct IssueComment: Identifiable, Hashable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date?
}

/// A non-comment entry on an issue's timeline: a label change, a
/// cross-reference, a rename — the thin grey rows between the speech
/// bubbles on the forge's own page.
struct IssueEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case labeled
        case unlabeled
        case referenced   // "mentioned this in #10"
        case renamed
        case assigned
        case unassigned
        case closed
        case reopened
        case milestoned
        case demilestoned
        /// GitLab system notes arrive as prose ("assigned to @tao") with no
        /// machine kind; shown verbatim rather than guessed at.
        case system
    }

    let id: String
    let kind: Kind
    let actor: String
    /// What the kind acts on: the label or assignee name, the new title,
    /// the referencing "#10 title", or a system note's own sentence.
    let detail: String
    var label: IssueLabel? = nil
    let createdAt: Date?
}

/// The issue thread in order: comments and events interleaved, the way the
/// forge's own timeline shows them.
enum IssueTimelineItem: Identifiable, Hashable {
    case comment(IssueComment)
    case event(IssueEvent)

    var id: String {
        switch self {
        case .comment(let comment): return "c-\(comment.id)"
        case .event(let event): return "e-\(event.id)"
        }
    }

    var createdAt: Date? {
        switch self {
        case .comment(let comment): return comment.createdAt
        case .event(let event): return event.createdAt
        }
    }
}

/// Which CLI drives a repo's pull requests. We never speak to an API
/// ourselves: hosts, tokens and OAuth stay the CLI's problem, exactly like
/// the git engine stays the git binary's problem.
enum Forge: String, Codable {
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
    /// The same binary as `binary`, in Toolchain terms — for install hints.
    var cliTool: DevTool { self == .github ? .gh : .glab }
}

/// What `detect` learned about a repo's forge: the CLI is there and the
/// feature can run, or the host is a forge we know but its CLI isn't
/// installed — worth a sentence in the sidebar, since one `brew install`
/// unlocks a feature the user can't otherwise discover.
enum ForgeAvailability: Equatable {
    case ready(Forge)
    case missingCLI(Forge)
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
        return ForgeFailure(summary: ErrorNotice.firstLine(raw), detail: detail)
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

    static func issues(_ output: String, forge: Forge) throws -> [Issue] {
        // Same bracket-hunting as `pullRequests`, same reason.
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = output[start...].data(using: .utf8)
        else { return [] }
        do {
            switch forge {
            case .github:
                return try JSONDecoder().decode([GHIssue].self, from: data).map {
                    Issue(
                        number: $0.number,
                        title: $0.title,
                        author: $0.author?.login ?? "",
                        body: $0.body ?? "",
                        url: $0.url,
                        createdAt: date($0.createdAt),
                        labels: ($0.labels ?? []).compactMap { label in
                            label.name.map { IssueLabel(name: $0, colorHex: label.color) }
                        }
                    )
                }
            case .gitlab:
                return try JSONDecoder().decode([GLIssue].self, from: data).compactMap {
                    guard let number = $0.iid ?? $0.id else { return nil }
                    return Issue(
                        number: number,
                        title: $0.title,
                        author: $0.author?.username ?? "",
                        body: $0.description ?? "",
                        url: $0.webURL ?? "",
                        createdAt: date($0.createdAt),
                        labels: ($0.labels ?? []).map { IssueLabel(name: $0) }
                    )
                }
            }
        } catch {
            throw ShellError(
                command: forge.binary,
                message: "Could not read the issue list: \(error)"
            )
        }
    }

    /// GitHub's timeline endpoint, which is the issue page itself as data:
    /// comments and events interleaved, already in order. Event types we
    /// can't render (subscribed, mentioned, connected, …) are skipped, not
    /// errors — the endpoint grows new ones without asking us.
    static func githubTimeline(_ output: String) throws -> [IssueTimelineItem] {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = output[start...].data(using: .utf8)
        else { return [] }
        let events: [GHTimelineEvent]
        do {
            events = try JSONDecoder().decode([GHTimelineEvent].self, from: data)
        } catch {
            throw ShellError(
                command: Forge.github.binary,
                message: "Could not read the issue's timeline: \(error)"
            )
        }
        var items: [IssueTimelineItem] = []
        for (index, event) in events.enumerated() {
            let created = date(event.createdAt)
            let actor = event.actor?.login ?? event.user?.login ?? ""
            // cross-referenced events carry no id of their own.
            let id = event.id.map(String.init) ?? "t\(index)"
            switch event.event {
            case "commented":
                items.append(.comment(IssueComment(
                    id: id, author: actor, body: event.body ?? "", createdAt: created
                )))
            case "labeled", "unlabeled":
                guard let name = event.label?.name else { continue }
                items.append(.event(IssueEvent(
                    id: id,
                    kind: event.event == "labeled" ? .labeled : .unlabeled,
                    actor: actor,
                    detail: name,
                    label: IssueLabel(name: name, colorHex: event.label?.color),
                    createdAt: created
                )))
            case "cross-referenced":
                guard let number = event.source?.issue?.number else { continue }
                let title = event.source?.issue?.title ?? ""
                items.append(.event(IssueEvent(
                    id: id, kind: .referenced, actor: actor,
                    detail: "#\(number) \(title)", createdAt: created
                )))
            case "renamed":
                items.append(.event(IssueEvent(
                    id: id, kind: .renamed, actor: actor,
                    detail: event.rename?.to ?? "", createdAt: created
                )))
            case "assigned", "unassigned":
                items.append(.event(IssueEvent(
                    id: id,
                    kind: event.event == "assigned" ? .assigned : .unassigned,
                    actor: actor,
                    detail: event.assignee?.login ?? "",
                    createdAt: created
                )))
            case "closed":
                items.append(.event(IssueEvent(
                    id: id, kind: .closed, actor: actor, detail: "", createdAt: created
                )))
            case "reopened":
                items.append(.event(IssueEvent(
                    id: id, kind: .reopened, actor: actor, detail: "", createdAt: created
                )))
            case "milestoned", "demilestoned":
                guard let title = event.milestone?.title else { continue }
                items.append(.event(IssueEvent(
                    id: id,
                    kind: event.event == "milestoned" ? .milestoned : .demilestoned,
                    actor: actor,
                    detail: title,
                    createdAt: created
                )))
            default:
                continue
            }
        }
        return items
    }

    /// GitLab has no single timeline: the notes list holds comments and
    /// system events ("assigned to @tao"), and label changes live in a
    /// resource of their own. Both arrive as pages; merged here, sorted
    /// by time. The label events decode with `try?` — they are seasoning,
    /// and a thread must not fail because a side dish did.
    static func gitlabThread(
        notesPages: [String], labelEventPages: [String]
    ) throws -> [IssueTimelineItem] {
        var items: [IssueTimelineItem] = []
        for notes in notesPages {
            guard let start = notes.firstIndex(where: { $0 == "[" || $0 == "{" }),
                  let data = notes[start...].data(using: .utf8)
            else { continue }
            let decoded: [GLNote]
            do {
                decoded = try JSONDecoder().decode([GLNote].self, from: data)
            } catch {
                throw ShellError(
                    command: Forge.gitlab.binary,
                    message: "Could not read the issue's notes: \(error)"
                )
            }
            items += decoded.map { note -> IssueTimelineItem in
                let id = note.id.map(String.init) ?? UUID().uuidString
                let author = note.author?.username ?? ""
                let created = date(note.createdAt)
                if note.system == true {
                    return .event(IssueEvent(
                        id: id, kind: .system, actor: author,
                        detail: ErrorNotice.firstLine(note.body ?? ""),
                        createdAt: created
                    ))
                }
                return .comment(IssueComment(
                    id: id, author: author, body: note.body ?? "", createdAt: created
                ))
            }
        }

        for page in labelEventPages {
            guard let start = page.firstIndex(where: { $0 == "[" || $0 == "{" }),
                  let data = page[start...].data(using: .utf8),
                  let events = try? JSONDecoder().decode([GLLabelEvent].self, from: data)
            else { continue }
            for event in events {
                guard let name = event.label?.name else { continue }
                items.append(.event(IssueEvent(
                    id: event.id.map { "l\($0)" } ?? UUID().uuidString,
                    kind: event.action == "remove" ? .unlabeled : .labeled,
                    actor: event.user?.username ?? "",
                    detail: name,
                    label: IssueLabel(name: name, colorHex: event.label?.color),
                    createdAt: date(event.createdAt)
                )))
            }
        }

        // Notes are already chronological; label events splice in by date.
        // Sort is stable, so same-timestamp notes keep GitLab's order.
        return items.sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }

    /// How many elements the top-level JSON array holds — the "was this
    /// page full" check for pagination, deliberately independent of how
    /// many of them parsed into renderable items.
    static func jsonArrayCount(_ output: String) -> Int {
        guard let start = output.firstIndex(where: { $0 == "[" }),
              let data = output[start...].data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return 0 }
        return array.count
    }

    /// Forge timestamps, which come in both ISO 8601 spellings: gh writes
    /// "2026-07-27T06:11:28Z", GitLab's REST answers add fractional
    /// seconds. A date that fails both is nil, and the row shows no age —
    /// better than refusing the whole list over a timestamp.
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let plain = isoPlain.date(from: string) { return plain }
        return isoFractional.date(from: string)
    }

    private static let isoPlain = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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

/// Verbatim shape of
/// `gh issue list --json number,title,author,url,body,createdAt,labels`.
private struct GHIssue: Decodable {
    struct Author: Decodable { let login: String? }
    struct Label: Decodable {
        let name: String?
        let color: String?
    }
    let number: Int
    let title: String
    let author: Author?
    let body: String?
    let url: String
    let createdAt: String?
    let labels: [Label]?
}

/// One entry of `gh api repos/{owner}/{repo}/issues/N/timeline`. REST
/// casing (created_at), unlike the camelCase `gh --json` views. Every
/// field beyond `event` belongs to only some event types, so all are
/// optional and the parser picks what its case needs.
private struct GHTimelineEvent: Decodable {
    struct Login: Decodable { let login: String? }
    struct Label: Decodable {
        let name: String?
        let color: String?
    }
    struct Rename: Decodable {
        let from: String?
        let to: String?
    }
    struct Milestone: Decodable { let title: String? }
    struct Source: Decodable {
        struct SourceIssue: Decodable {
            let number: Int?
            let title: String?
        }
        let issue: SourceIssue?
    }
    let event: String?
    let id: Int?
    let actor: Login?
    /// `commented` entries name their author `user`, not `actor`.
    let user: Login?
    let body: String?
    let label: Label?
    let rename: Rename?
    let milestone: Milestone?
    let assignee: Login?
    let source: Source?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case event, id, actor, user, body, label, rename, milestone, assignee, source
        case createdAt = "created_at"
    }
}

/// One `resource_label_events` entry — GitLab's separate ledger of label
/// adds and removes.
private struct GLLabelEvent: Decodable {
    struct User: Decodable { let username: String? }
    struct Label: Decodable {
        let name: String?
        let color: String?
    }
    let id: Int?
    let user: User?
    let label: Label?
    let action: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, label, action
        case createdAt = "created_at"
    }
}

/// GitLab's REST issue, through `glab issue list --output json`. Optional
/// for the same reason as `GLMergeRequest`: a missing field should degrade
/// the row, not fail the list. Labels here are bare names — the listing
/// carries no colours.
private struct GLIssue: Decodable {
    struct Author: Decodable { let username: String? }
    let iid: Int?
    let id: Int?
    let title: String
    let description: String?
    let author: Author?
    let webURL: String?
    let createdAt: String?
    let labels: [String]?

    enum CodingKeys: String, CodingKey {
        case iid, id, title, description, author, labels
        case webURL = "web_url"
        case createdAt = "created_at"
    }
}

/// A note from GitLab's notes endpoint, via `glab api`. `system` notes are
/// state changes, not conversation.
private struct GLNote: Decodable {
    struct Author: Decodable { let username: String? }
    let id: Int?
    let body: String?
    let system: Bool?
    let author: Author?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, system, author
        case createdAt = "created_at"
    }
}

/// Shells out to `gh` / `glab`. Serialized by the actor like GitClient, so
/// a checkout can't race a list refresh.
actor ForgeClient {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    /// The forge for a repo, or nil when the host isn't one we know. A
    /// known host whose CLI is missing comes back `.missingCLI`, so the
    /// sidebar can say how to get it instead of the feature leaving no
    /// trace at all.
    static func detect(remoteURL: String) -> ForgeAvailability? {
        guard let forge = ForgeParsers.forge(forHost: ForgeParsers.host(of: remoteURL)) else {
            return nil
        }
        return Shell.which(forge.binary) == nil ? .missingCLI(forge) : .ready(forge)
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

    /// The most issues one fetch asks for — so also the most the card's
    /// badge can say ("100+") and the most rows the sidebar section holds.
    /// The exact size of a triage backlog isn't what either is for.
    static let issueCountLimit = 100

    /// The open issues, newest first, bodies included — a listing rather
    /// than a repo-metadata query because that's the one shape both CLIs
    /// share, and GitHub's own `open_issues_count` would count PRs into it
    /// anyway.
    func issues(_ forge: Forge, limit: Int = ForgeClient.issueCountLimit) async throws -> [Issue] {
        let args: [String]
        switch forge {
        case .github:
            args = [
                "issue", "list",
                "--json", "number,title,author,url,body,createdAt,labels",
                "--limit", String(limit),
            ]
        case .gitlab:
            args = ["issue", "list", "--output", "json", "--per-page", String(limit)]
        }
        return try ForgeParsers.issues(try await run(forge, args), forge: forge)
    }

    /// Both forges page their listings at 100; this many pages per
    /// resource is the ceiling — 500 entries, beyond which the panel says
    /// it's showing the head rather than silently ending.
    private static let threadPageSize = 100
    private static let threadPageCap = 5

    /// The timeline under one issue: comments and events, in order,
    /// paged until a page comes back short. Both forges answer through
    /// their CLI's `api` passthrough — `{owner}` / `{repo}` are gh's own
    /// placeholders and `:id` is glab's, each resolved by its CLI from
    /// the working directory, so hosts and tokens stay the CLI's problem
    /// like everywhere else here.
    func issueThread(
        _ issue: Issue, forge: Forge
    ) async throws -> (items: [IssueTimelineItem], truncated: Bool) {
        switch forge {
        case .github:
            var items: [IssueTimelineItem] = []
            for page in 1...Self.threadPageCap {
                let output = try await run(forge, [
                    "api",
                    "repos/{owner}/{repo}/issues/\(issue.number)/timeline"
                        + "?per_page=\(Self.threadPageSize)&page=\(page)",
                ])
                items += try ForgeParsers.githubTimeline(output)
                // Full-page check on the RAW element count: a page of 100
                // events can parse to fewer items (types we skip), and
                // stopping on that would drop the pages behind it.
                if ForgeParsers.jsonArrayCount(output) < Self.threadPageSize {
                    return (items, false)
                }
            }
            return (items, true)
        case .gitlab:
            var notePages: [String] = []
            var truncated = false
            for page in 1...Self.threadPageCap {
                let output = try await run(forge, [
                    "api",
                    "projects/:id/issues/\(issue.number)/notes"
                        + "?sort=asc&per_page=\(Self.threadPageSize)&page=\(page)",
                ])
                notePages.append(output)
                if ForgeParsers.jsonArrayCount(output) < Self.threadPageSize { break }
                truncated = page == Self.threadPageCap
            }
            // Label changes are a separate GitLab resource. try? — a
            // thread with comments but no label rows beats no thread.
            // One page only: an issue relabelled 100+ times has no head
            // worth completing.
            let labelEvents = (try? await run(forge, [
                "api",
                "projects/:id/issues/\(issue.number)/resource_label_events"
                    + "?per_page=\(Self.threadPageSize)",
            ])) ?? "[]"
            let items = try ForgeParsers.gitlabThread(
                notesPages: notePages, labelEventPages: [labelEvents]
            )
            return (items, truncated)
        }
    }

    func openIssueInBrowser(_ issue: Issue, forge: Forge) async throws {
        try await run(forge, ["issue", "view", String(issue.number), "--web"])
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
