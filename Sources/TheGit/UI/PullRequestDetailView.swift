import MarkdownUI
import SwiftUI

/// A pull/merge request, reviewable where the work is: the overview and
/// the whole branch's diff, over the graph like a file diff is.
///
/// Read-only in this first cut — approving, commenting and merging happen on
/// the forge. What this panel is for is the part the forge is *worse* at:
/// reading a branch's change against the merge base, file by file, with the
/// same diff renderer, line numbers and hunks as every other diff here, at
/// the speed of a local git command instead of a paged web API.
struct PullRequestDetailView: View {
    @ObservedObject var repo: RepoState
    let pr: PullRequest
    @Environment(\.uiZoom) private var zoom

    private var forge: Forge { repo.forge ?? .github }
    private var detail: PullRequestDetail? { repo.prDetail }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch repo.prTab {
            case .overview: overview
            case .files: files
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            PullRequestGlyph()
                .frame(width: 11 * zoom, height: 11 * zoom)
                .foregroundStyle(stateColor)
            Text(forge.label(pr.number))
                .zoomFont(12, weight: .semibold, design: .monospaced)
            Text(detail?.title ?? pr.title)
                .zoomFont(12, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // The tab picker sits in the header rather than on a strip of
            // its own: the panel covers the graph, and a second 34pt band
            // would come out of the diff's height on every screen.
            Picker("", selection: $repo.prTab) {
                Text("Overview").tag(RepoState.ReviewTab.overview)
                Text(fileTabTitle).tag(RepoState.ReviewTab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // Reviewing needs no checkout — the diff comes from a fetched
            // read-only ref. This is for afterwards: running the code,
            // reading it in an editor, pushing a fix onto the branch. And
            // when HEAD is already that branch there is nothing to do but
            // harm, so the button says so instead of offering it.
            Button("Checkout") { repo.checkoutPullRequest(pr) }
                .controlSize(.regular)
                .disabled(repo.isCheckedOut(pr))
                .help(
                    repo.isCheckedOut(pr)
                        ? "You're already on \(headBranch) — the code is right here."
                        : "Check \(headBranch) out locally (moves HEAD)"
                )

            Button("Open in Browser") { repo.openPullRequestInBrowser(pr) }
                .controlSize(.regular)

            Button {
                repo.closePullRequestReview()
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
            .help("Close \(forge.itemNoun.lowercased()) (esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// The count comes from the local diff, so the tab stays unnumbered
    /// until git has answered — a "Files (0)" that later becomes 12 reads
    /// as a request that changes nothing.
    private var fileTabTitle: String {
        repo.prFiles.isEmpty ? "Files" : "Files (\(repo.prFiles.count))"
    }

    /// The branch being merged from — what a checkout would land on. The
    /// fetched page's spelling of it, falling back to the listing's.
    private var headBranch: String {
        let fetched = detail?.headBranch ?? ""
        return fetched.isEmpty ? pr.branch : fetched
    }

    private var stateColor: Color {
        switch detail?.state ?? .open {
        case .open: return pr.isDraft ? .secondary : .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(detail?.title ?? pr.title)
                    .zoomFont(18, weight: .bold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                metaLine
                if let error = repo.prReviewError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                }
                signals

                Divider()

                let body = detail?.body ?? ""
                if detail == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(forge.itemNoun.lowercased())…")
                            .zoomFont(11)
                            .foregroundStyle(.tertiary)
                    }
                } else if body.isEmpty {
                    Text("No description.")
                        .zoomFont(12)
                        .foregroundStyle(.tertiary)
                } else {
                    Markdown(body)
                        .markdownTheme(ForgeMarkdown.theme(zoom: zoom))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                thread
            }
            .padding(20)
            // A reading column, not a full-bleed sprawl — same as the
            // issue viewer.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    /// State pill, number, author, age — the line the forge puts under the
    /// title, and the one people read to know whether this is still live.
    private var metaLine: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: stateIcon)
                    .zoomFont(9, weight: .semibold)
                Text(stateTitle)
                    .zoomFont(10, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(stateColor))

            HStack(spacing: 4) {
                Text(forge.label(pr.number))
                    .zoomFont(11, weight: .semibold, design: .monospaced)
                let author = detail?.author ?? pr.author
                if !author.isEmpty {
                    Text("opened by \(author)")
                        .zoomFont(11)
                }
                if let created = detail?.createdAt {
                    Text("· \(AgeBreaks.compact(date: created))")
                        .zoomFont(11)
                }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var stateTitle: String {
        switch detail?.state ?? .open {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .open: return (detail?.isDraft ?? pr.isDraft) ? "Draft" : "Open"
        }
    }

    private var stateIcon: String {
        switch detail?.state ?? .open {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark"
        case .open: return "smallcircle.filled.circle"
        }
    }

    /// The row of verdicts: branches, review decision, CI, conflicts. Each
    /// chip appears only when the forge told us something — an absent
    /// signal is absent, not green.
    private var signals: some View {
        HStack(spacing: 6) {
            chip(
                "\(detail?.baseBranch ?? "?") ← \(detail?.headBranch ?? pr.branch)",
                icon: "arrow.triangle.branch",
                tint: .secondary,
                monospaced: true
            )
            if let decision = detail?.reviewDecision {
                switch decision {
                case .approved:
                    chip("Approved", icon: "checkmark.seal", tint: .green)
                case .changesRequested:
                    chip("Changes requested", icon: "exclamationmark.bubble", tint: .orange)
                case .reviewRequired:
                    chip("Review required", icon: "person.badge.clock", tint: .secondary)
                }
            }
            if let checks = detail?.checks, !checks.isEmpty {
                chip(checksTitle(checks), icon: checksIcon(checks), tint: checksTint(checks))
            }
            if detail?.hasConflicts == true {
                chip("Conflicts", icon: "exclamationmark.triangle", tint: .red)
            }
            if let stat = diffStat {
                chip(stat, icon: "plusminus", tint: .secondary, monospaced: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, -4)
    }

    /// Total ± over the request, out of the local diff — the one number the
    /// forge and we could disagree on, and ours is the one being shown.
    private var diffStat: String? {
        guard repo.prDiffState == .ready, !repo.prFiles.isEmpty else { return nil }
        let adds = repo.prFiles.reduce(0) { $0 + $1.additions }
        let dels = repo.prFiles.reduce(0) { $0 + $1.deletions }
        return "+\(adds) −\(dels)"
    }

    private func checksTitle(_ checks: CheckRollup) -> String {
        var parts: [String] = []
        if checks.failed > 0 { parts.append("\(checks.failed) failing") }
        if checks.pending > 0 { parts.append("\(checks.pending) running") }
        if checks.passed > 0 { parts.append("\(checks.passed) passed") }
        return parts.joined(separator: " · ")
    }

    private func checksIcon(_ checks: CheckRollup) -> String {
        if checks.failed > 0 { return "xmark.octagon" }
        if checks.pending > 0 { return "clock" }
        return "checkmark.circle"
    }

    private func checksTint(_ checks: CheckRollup) -> Color {
        if checks.failed > 0 { return .red }
        if checks.pending > 0 { return .orange }
        return .green
    }

    private func chip(
        _ text: String, icon: String, tint: Color, monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .zoomFont(9, weight: .semibold)
            Text(text)
                .zoomFont(10, weight: .medium, design: monospaced ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                tint == .secondary ? Color.primary.opacity(0.06) : tint.opacity(0.13)
            )
        )
    }

    @ViewBuilder
    private var thread: some View {
        if let error = repo.prThreadError {
            Label(error, systemImage: "exclamationmark.triangle")
                .zoomFont(11)
                .foregroundStyle(.secondary)
        } else if let thread = repo.prThread {
            if !thread.isEmpty {
                ForgeTimeline(items: thread, truncated: repo.prThreadTruncated)
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

    // MARK: - Files

    private var files: some View {
        HSplitView {
            fileList
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
            diff
                .frame(minWidth: 320)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(reviewedCountTitle)
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    repo.refreshPullRequestReview()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .zoomFont(10, weight: .semibold)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .help("Fetch the \(forge.itemNoun.lowercased()) again")
            }
            .padding(.horizontal, FileListMetrics.inset)
            // The same 34pt as every other header in the app, the diff
            // header beside this one included — the two columns sit under
            // one continuous line, and 8pt of padding around a 20pt button
            // made this side 2pt taller than that one.
            .frame(height: 34)

            Divider()

            switch repo.prDiffState {
            case .loading:
                status {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Fetching the branch…")
                            .zoomFont(11)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .failed(let message):
                status {
                    VStack(spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .zoomFont(11)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { repo.refreshPullRequestReview() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                }
            case .ready where repo.prFiles.isEmpty:
                status {
                    Text("No file changes against \(repo.prDetail?.baseBranch ?? "the base branch").")
                        .zoomFont(11)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            case .ready:
                ScrollView {
                    LazyVStack(spacing: FileListMetrics.spacing * zoom) {
                        ForEach(repo.prFiles) { file in
                            ReviewFileRow(
                                file: file,
                                isSelected: repo.prSelectedFile?.path == file.path,
                                isViewed: repo.prViewedFiles.contains(file.path),
                                select: { repo.selectReviewFile(file) },
                                toggleViewed: { repo.toggleReviewFileViewed(file) }
                            )
                            .padding(.horizontal, (FileListMetrics.inset - FileListMetrics.bleed) * zoom)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .background(.background)
    }

    private var reviewedCountTitle: String {
        guard case .ready = repo.prDiffState, !repo.prFiles.isEmpty else {
            return "Changed Files"
        }
        let viewed = repo.prFiles.filter { repo.prViewedFiles.contains($0.path) }.count
        return viewed == 0
            ? "Changed Files (\(repo.prFiles.count))"
            : "Changed Files (\(viewed)/\(repo.prFiles.count) viewed)"
    }

    private func status<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var diff: some View {
        VStack(spacing: 0) {
            if let file = repo.prSelectedFile {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        if !file.directory.isEmpty {
                            Text(file.directory).foregroundStyle(.secondary)
                        }
                        Text(file.fileName).fontWeight(.semibold)
                    }
                    .zoomFont(12)
                    .lineLimit(1)
                    .truncationMode(.head)
                    if let old = file.oldPath, old != file.path {
                        Text("renamed from \(old)")
                            .zoomFont(10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Text("+\(file.additions) −\(file.deletions)")
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.tertiary)
                    Toggle("Viewed", isOn: Binding(
                        get: { repo.prViewedFiles.contains(file.path) },
                        set: { _ in repo.toggleReviewFileViewed(file) }
                    ))
                    .toggleStyle(.checkbox)
                    .zoomFont(11)
                    .help("Tick the file off and move to the next unread one")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
            }

            if repo.prSelectedFile == nil {
                Text(repo.prFiles.isEmpty ? "" : "Pick a file to read its diff.")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repo.prSelectedFile?.isBinary == true {
                Text("Binary file — nothing to show as text.")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repo.prDiffLines.isEmpty {
                // Empty for two reasons — still loading, or a mode-only
                // change. Both are quiet; neither is worth a spinner that
                // flashes for 30ms on a local diff.
                Text("No textual changes to show")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // No hunk actions: a review's diff isn't the working
                        // tree, and there is nothing here to stage.
                        ForEach(repo.prDiffLines) { line in
                            DiffLineRow(line: line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Identity per file, so switching files starts the new
                // diff at the top instead of keeping the old offset.
                .id(repo.prSelectedFile?.path)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// One row of a review's file list: git's status letter, the path, the
/// file's own ± counts, and the tick that says you've read it.
struct ReviewFileRow: View {
    let file: ReviewFile
    let isSelected: Bool
    let isViewed: Bool
    let select: () -> Void
    let toggleViewed: () -> Void
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    private var statusColor: Color {
        switch file.status {
        case "A": return .green
        case "M": return .yellow
        case "D": return .red
        case "R", "C": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(file.status))
                .zoomFont(10, weight: .bold, design: .monospaced)
                .foregroundStyle(statusColor)
                .frame(width: 14)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory).foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .zoomFont(12)
            .lineLimit(1)
            .truncationMode(.head)

            Spacer(minLength: 4)

            if file.isBinary {
                Text("bin")
                    .zoomFont(9, weight: .medium)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 3) {
                    if file.additions > 0 {
                        Text("+\(file.additions)").foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("−\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .zoomFont(10, design: .monospaced)
            }

            // The tick is a button, not a Toggle: inside a row that is
            // itself tappable, a checkbox's own label area would swallow
            // clicks meant for the row.
            Button(action: toggleViewed) {
                Image(systemName: isViewed ? "checkmark.circle.fill" : "circle")
                    .zoomFont(11)
                    .foregroundStyle(isViewed ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .help(isViewed ? "Mark as not viewed" : "Mark as viewed")
        }
        .padding(.horizontal, FileListMetrics.bleed * zoom)
        .frame(height: FileListMetrics.row * zoom)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.15)
                        : (hovering ? Color.primary.opacity(0.06) : .clear)
                )
        )
        // A read file stays legible but recedes — the list should show at a
        // glance how much of the review is left.
        .opacity(isViewed && !isSelected ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { select() }
    }
}
