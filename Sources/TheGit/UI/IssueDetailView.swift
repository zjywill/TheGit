import SwiftUI

/// The issue, readable where you already are: title, body, and the thread
/// under it, fetched through the same CLI that listed it. Read-only on
/// purpose — triage happens on the forge, with labels and assignees and
/// everything else this sheet would only imitate badly; what the sidebar
/// needs is to answer "what is this one about" without a context switch.
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
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "smallcircle.filled.circle")
                .zoomFont(13)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .zoomFont(14, weight: .semibold)
                    .textSelection(.enabled)
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
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Body + comments

    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if issue.body.isEmpty {
                    Text("No description.")
                        .zoomFont(12)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Self.rendered(issue.body))
                        .zoomFont(12)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                comments
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var comments: some View {
        if let error = repo.issueCommentsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .zoomFont(11)
                .foregroundStyle(.secondary)
        } else if let comments = repo.issueComments {
            if !comments.isEmpty {
                Text(comments.count == 1 ? "1 comment" : "\(comments.count) comments")
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(comments) { comment in
                    commentCard(comment)
                }
            }
            // No comments: the body just ends, like a thread with no
            // replies does — a "0 comments" line would be dead weight.
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading comments…")
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    private func commentCard(_ comment: IssueComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(comment.author.isEmpty ? "unknown" : comment.author)
                    .zoomFont(11, weight: .semibold)
                if let created = comment.createdAt {
                    Text(AgeBreaks.compact(date: created))
                        .zoomFont(10)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(Self.rendered(comment.body))
                .zoomFont(12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// Inline markdown only, whitespace kept: forge bodies are written as
    /// GitHub-flavoured markdown, and the inline subset (bold, code,
    /// links) renders the common case well while full block parsing would
    /// swallow the newlines that give an issue body its shape. What it
    /// can't render, it shows as written — never an error.
    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open in Browser") { repo.openIssueInBrowser(issue) }
            Spacer()
            Button("Close") { repo.issueToView = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
