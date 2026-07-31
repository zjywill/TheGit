import MarkdownUI
import SwiftUI

/// The forge's own timeline, as a view: comments and events interleaved,
/// strung on a rail. Shared by the issue viewer and the review panel —
/// GitHub serves both from one endpoint and draws them the same way, and a
/// second copy of this would drift from the first.
///
/// Loading and failure stay with the caller: an issue whose thread is still
/// in flight and a merge request whose notes 403'd need different sentences,
/// and neither is this view's business.
struct ForgeTimeline: View {
    let items: [IssueTimelineItem]
    /// The fetch hit its page cap — what's shown is the head of a longer
    /// thread, and the panel says so rather than ending silently.
    var truncated = false
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        // No count line, no headers: the entries string themselves into a
        // timeline, held together by the rail on the left. Each entry draws
        // its own segment — icon down to the next entry's icon — so the rail
        // ends AT the last entry instead of running past it to the bottom.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                entry(item, isLast: index == items.count - 1)
            }
            if truncated {
                Text("Showing the first \(items.count) entries — open in browser for the rest.")
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 32 * zoom)
                    .padding(.top, 12)
            }
        }
        .padding(.top, 4)
    }

    /// One timeline entry: the gutter column (avatar or icon disc, and —
    /// unless this is the last entry — the rail segment running down to
    /// the next one) beside the entry's content. Per-entry segments are
    /// what make the rail stop at the final entry instead of running on
    /// to the bottom of the container.
    private func entry(_ item: IssueTimelineItem, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch item {
                case .comment(let comment):
                    AuthorBubble(author: comment.author)
                case .event(let event):
                    eventDisc(event.kind)
                }
            }
            .frame(width: 24 * zoom)
            Group {
                switch item {
                case .comment(let comment):
                    commentCard(comment)
                case .event(let event):
                    eventRow(event)
                }
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
        // The rail segment is the entry's own background, full height,
        // running behind the opaque disc — each entry connects itself to
        // the next, and the last one simply doesn't. (Not a flexible
        // frame in the gutter column: an HStack doesn't offer a child
        // the row height, so the line came up short next to tall cards.)
        .background(alignment: .leading) {
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 2 * zoom)
                    .padding(.leading, 11 * zoom)
            }
        }
    }

    private func eventDisc(_ kind: IssueEvent.Kind) -> some View {
        Image(systemName: Self.icon(for: kind))
            .zoomFont(10, weight: .medium)
            .foregroundStyle(Self.iconForeground(for: kind))
            .frame(width: 20 * zoom, height: 20 * zoom)
            .background(
                Circle().fill(Color(nsColor: .textBackgroundColor))
                    .overlay(Circle().fill(Self.iconDisc(for: kind)))
            )
    }

    /// The grey sentence of an event, actor in front. Sized to the disc
    /// beside it so the single line sits centred on it.
    private func eventRow(_ event: IssueEvent) -> some View {
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
        .frame(minHeight: 20 * zoom)
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

    /// GitHub's comment shape: a bordered bubble whose header strip names
    /// the author — instead of an anonymous grey slab. The author's face
    /// sits in the timeline gutter, drawn by `entry`.
    private func commentCard(_ comment: IssueComment) -> some View {
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
                .markdownTheme(ForgeMarkdown.theme(zoom: zoom))
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
struct AuthorBubble: View {
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
        // magnitude, not abs: the hash wraps on purpose, and abs(Int.min)
        // traps rather than returning anything.
        return Self.palette[Int(hash.magnitude % UInt(Self.palette.count))]
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

enum ForgeMarkdown {
    /// MarkdownUI's GitHub theme, scaled down from its web-sized 16pt base
    /// to this app's 12pt body text. Heading, code, and table styles in
    /// the theme are all em-relative, so one FontSize override rescales
    /// the lot.
    static func theme(zoom: Double) -> Theme {
        Theme.gitHub.text {
            FontSize(12 * zoom)
        }
    }
}
