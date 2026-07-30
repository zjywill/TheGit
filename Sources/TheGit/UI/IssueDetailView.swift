import MarkdownUI
import SwiftUI

/// The issue, readable where you already are: title, body, and the thread
/// under it, shown over the graph like a file diff is — not in a modal.
/// Read-only on purpose — triage happens on the forge, with labels and
/// assignees and everything else this panel would only imitate badly;
/// what the sidebar needs is to answer "what is this one about" without
/// a context switch.
struct IssueDetailView: View {
    @ObservedObject var repo: RepoState
    let issue: Issue
    @Environment(\.uiZoom) private var zoom

    private var forge: Forge { repo.forge ?? .github }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            thread
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "smallcircle.filled.circle")
                .zoomFont(11)
                .foregroundStyle(.green)
            Text(forge.label(issue.number))
                .zoomFont(12, weight: .semibold, design: .monospaced)
            Text(issue.title)
                .zoomFont(12, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button("Open in Browser") { repo.openIssueInBrowser(issue) }
                .controlSize(.regular)

            Button {
                repo.issueToView = nil
            } label: {
                // Same 24pt hit area as the diff header's close button —
                // the glyph alone is a 10pt target.
                Image(systemName: "xmark")
                    .zoomFont(10, weight: .bold)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close issue (esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: - Body + comments

    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(issue.title)
                    .zoomFont(18, weight: .bold)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    // The list is open issues only, so the pill is static —
                    // it earns its place by making the page read like the
                    // forge's, not by carrying information.
                    HStack(spacing: 3) {
                        Image(systemName: "smallcircle.filled.circle")
                            .zoomFont(9, weight: .semibold)
                        Text("Open")
                            .zoomFont(10, weight: .semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.green))
                    HStack(spacing: 4) {
                        Text(forge.label(issue.number))
                            .zoomFont(11, weight: .semibold, design: .monospaced)
                        if !issue.author.isEmpty {
                            Text("opened by \(issue.author)")
                                .zoomFont(11)
                        }
                        if let created = issue.createdAt {
                            Text("· \(AgeBreaks.compact(date: created))")
                                .zoomFont(11)
                        }
                    }
                    .foregroundStyle(.secondary)
                    if !issue.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(issue.labels, id: \.self) { label in
                                LabelChip(label: label)
                            }
                        }
                        .padding(.leading, 2)
                    }
                }

                Divider()

                if issue.body.isEmpty {
                    Text("No description.")
                        .zoomFont(12)
                        .foregroundStyle(.tertiary)
                } else {
                    Markdown(issue.body)
                        .markdownTheme(Self.theme(zoom: zoom))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                comments
            }
            .padding(20)
            // A reading column, not a full-bleed sprawl: the pane can be
            // arbitrarily wide, prose shouldn't be.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var comments: some View {
        if let error = repo.issueThreadError {
            Label(error, systemImage: "exclamationmark.triangle")
                .zoomFont(11)
                .foregroundStyle(.secondary)
        } else if let thread = repo.issueThread {
            if !thread.isEmpty {
                // No count line, no headers: the entries string themselves
                // into a timeline, held together by the rail on the left —
                // a line down the gutter, behind the avatars and icon
                // discs (which are opaque so it passes *behind* them).
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(thread) { item in
                        switch item {
                        case .comment(let comment):
                            commentCard(comment)
                        case .event(let event):
                            eventRow(event)
                        }
                    }
                    if repo.issueThreadTruncated {
                        Text("Showing the first \(thread.count) entries — open in browser for the rest.")
                            .zoomFont(11)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 32 * zoom)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 2 * zoom)
                        .padding(.leading, 11 * zoom)
                }
                .padding(.top, 4)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading activity…")
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    /// A timeline event, GitHub-style: an icon on a solid disc in the
    /// avatar gutter (solid, so the rail runs behind it, not through it),
    /// then one grey sentence with the actor in front.
    private func eventRow(_ event: IssueEvent) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: Self.icon(for: event.kind))
                .zoomFont(10, weight: .medium)
                .foregroundStyle(Self.iconForeground(for: event.kind))
                .frame(width: 20 * zoom, height: 20 * zoom)
                .background(
                    Circle().fill(Color(nsColor: .textBackgroundColor))
                        .overlay(Circle().fill(Self.iconDisc(for: event.kind)))
                )
                .frame(width: 24 * zoom)
            HStack(spacing: 4) {
                if !event.actor.isEmpty {
                    Text(event.actor)
                        .zoomFont(11, weight: .semibold)
                }
                Text(Self.phrase(for: event))
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let label = event.label {
                    LabelChip(label: label)
                }
                if let created = event.createdAt {
                    Text("· \(AgeBreaks.compact(date: created))")
                        .zoomFont(11)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 1)
    }

    /// The sentence after the actor's name. Label events say only
    /// "added" / "removed" — the chip right after them is the object.
    private static func phrase(for event: IssueEvent) -> String {
        switch event.kind {
        case .labeled: return "added"
        case .unlabeled: return "removed"
        case .referenced: return "mentioned this in \(event.detail)"
        case .renamed: return "changed the title to “\(event.detail)”"
        case .assigned:
            return event.detail == event.actor
                ? "self-assigned this" : "assigned \(event.detail)"
        case .unassigned: return "unassigned \(event.detail)"
        case .closed: return "closed this"
        case .reopened: return "reopened this"
        case .milestoned: return "added this to the \(event.detail) milestone"
        case .demilestoned: return "removed this from the \(event.detail) milestone"
        case .system: return event.detail
        }
    }

    private static func icon(for kind: IssueEvent.Kind) -> String {
        switch kind {
        case .labeled, .unlabeled: return "tag"
        case .referenced: return "link"
        case .renamed: return "pencil"
        case .assigned, .unassigned: return "person"
        case .closed: return "checkmark.circle"
        case .reopened: return "dot.circle"
        case .milestoned, .demilestoned: return "flag"
        case .system: return "gearshape"
        }
    }

    /// GitHub's two-tone discs: state changes get a filled coloured disc
    /// with white glyph, everything else a quiet grey one.
    private static func iconDisc(for kind: IssueEvent.Kind) -> Color {
        switch kind {
        case .closed: return .purple
        case .reopened: return .green
        default: return Color.primary.opacity(0.08)
        }
    }

    private static func iconForeground(for kind: IssueEvent.Kind) -> Color {
        switch kind {
        case .closed, .reopened: return .white
        default: return .secondary
        }
    }

    /// GitHub's comment shape: the author's face in a gutter on the left,
    /// and a bordered bubble whose header strip names them — instead of an
    /// anonymous grey slab.
    private func commentCard(_ comment: IssueComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AuthorBubble(author: comment.author)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(comment.author.isEmpty ? "unknown" : comment.author)
                        .zoomFont(11, weight: .semibold)
                    Text("commented")
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                    if let created = comment.createdAt {
                        Text(AgeBreaks.compact(date: created))
                            .zoomFont(11)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.045))
                Divider()
                Markdown(comment.body)
                    .markdownTheme(Self.theme(zoom: zoom))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
        }
    }

    /// Forge accounts have usernames, not the emails AvatarStore is keyed
    /// by (and avatars are opt-in anyway), so the gutter face is initials
    /// in a colour the name always hashes to — the same fallback the
    /// graph's nodes draw.
    private struct AuthorBubble: View {
        let author: String
        @Environment(\.uiZoom) private var zoom

        private static let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red,
        ]

        /// djb2 over utf8 — Hashable's hashValue is per-run seeded, and a
        /// colour that changes on every launch reads as a different person.
        private var color: Color {
            var hash = 5381
            for byte in author.utf8 { hash = (hash &* 33) &+ Int(byte) }
            return Self.palette[abs(hash) % Self.palette.count]
        }

        var body: some View {
            // Opaque base under the tint: the timeline rail runs behind
            // this circle and must not show through it.
            Circle()
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(Circle().fill(color.opacity(0.2)))
                .overlay(
                    Circle().strokeBorder(color.opacity(0.75), lineWidth: 1)
                )
                .overlay(
                    Text(LaneCanvas.initials(author))
                        .zoomFont(9, weight: .bold)
                        .foregroundStyle(color)
                )
                .frame(width: 24 * zoom, height: 24 * zoom)
        }
    }

    /// MarkdownUI's GitHub theme, scaled down from its web-sized 16pt base
    /// to this app's 12pt body text. Heading, code, and table styles in
    /// the theme are all em-relative, so one FontSize override rescales
    /// the lot.
    private static func theme(zoom: Double) -> Theme {
        Theme.gitHub.text {
            FontSize(12 * zoom)
        }
    }
}
