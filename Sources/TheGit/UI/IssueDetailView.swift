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
    @ObservedObject private var agents = AgentTools.shared
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

            // The one place the feature is visible without a right-click,
            // and the right place for it: you've just read the issue, and
            // "find the cause" is the next thing you were going to do.
            if !agents.available.isEmpty {
                Menu("Hand Off") {
                    HandoffMenu(tasks: HandoffTask.forIssues) { task, agent in
                        repo.handOff(task, to: agent, issue: issue)
                    }
                }
                .controlSize(.regular)
                .fixedSize()
                .help("Open a terminal in this repo with an agent already working on \(forge.label(issue.number)).")
            }

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
                        .markdownTheme(ForgeMarkdown.theme(zoom: zoom))
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

    /// The thread under the body. Three states, three sentences: an
    /// unreachable thread must not read like an empty one, and neither
    /// should one still in flight.
    @ViewBuilder
    private var comments: some View {
        if let error = repo.issueThreadError {
            Label(error, systemImage: "exclamationmark.triangle")
                .zoomFont(11)
                .foregroundStyle(.secondary)
        } else if let thread = repo.issueThread {
            if !thread.isEmpty {
                ForgeTimeline(items: thread, truncated: repo.issueThreadTruncated)
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
}
