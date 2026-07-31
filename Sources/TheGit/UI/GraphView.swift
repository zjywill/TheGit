import SwiftUI

/// Middle panel: commit graph with lane rendering.
struct GraphView: View {
    @ObservedObject var repo: RepoState
    @Environment(\.uiZoom) private var zoom

    /// Base metrics at zoom 1; multiply by the environment's uiZoom.
    static let rowHeight: CGFloat = 32
    static let laneWidth: CGFloat = 18
    static let defaultVisibleLanes = 8

    private static let leadingInset: CGFloat = 8

    /// The pane's current width, for the row-tint gate below.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        let allRows = repo.snapshot.graphRows
        let query = repo.searchText.trimmingCharacters(in: .whitespaces)
        let searching = !query.isEmpty
        // Search filters to a flat list — lane lines are meaningless across
        // filtered gaps, so rows collapse to a single node column.
        let rows = searching
            ? allRows.filter {
                !$0.commit.isWip && !$0.commit.isStash
                    && ($0.commit.subject.localizedCaseInsensitiveContains(query)
                        || $0.commit.author.localizedCaseInsensitiveContains(query)
                        || $0.commit.hash.hasPrefix(query.lowercased()))
            }
            : allRows
        let totalLanes = GraphLayout.maxLanes(of: rows)
        let laneW = Self.laneWidth * zoom
        let rowH = Self.rowHeight * zoom
        let neededWidth = CGFloat(totalLanes) * laneW + 8
        let autoWidth = CGFloat(min(totalLanes, Self.defaultVisibleLanes)) * laneW + 8
        let graphWidth = searching ? laneW * 2 : autoWidth
        // How far the lanes can slide before their right edge is reached.
        let maxScroll = max(0, neededWidth - graphWidth)
        // The offset lives on the repo — see the note there.
        let scrollX = min(repo.graphScrollX, maxScroll)
        // Fade only where content actually continues, so the edge tells you
        // there is more in that direction.
        let fadeTrailing = !searching && scrollX < maxScroll - 1
        let fadeLeading = !searching && scrollX > 1
        let faded = fadeTrailing
        // Dedicated BRANCH/TAG column left of the graph (GitKraken layout):
        // zero width when the loaded range has no refs at all.
        let hasBadges = rows.contains { !RefBadge.infos(for: $0.commit.refs).isEmpty }
        let badgeWidth: CGFloat = hasBadges ? 150 * zoom : 0

        let changeCount = repo.snapshot.staged.count + repo.snapshot.unstaged.count
            + repo.snapshot.conflicted.count

        // The subtle per-row branch tint only works while the message
        // column has text in it. In a narrow pane the fixed columns
        // (badges, lanes, author, hash) squeeze the messages out, and
        // the tint turns into bare colour slabs — adjacent same-lane
        // rows fuse into one block that reads as the conflict banner's
        // orange leaking down the graph. Gate it on the room the
        // messages actually get; the constant is the author + hash
        // columns plus paddings, and the threshold is roughly where
        // subjects stop being legible words.
        let messageRoom = paneWidth - Self.leadingInset - badgeWidth - graphWidth
            - 170 * zoom
        let tintRows = paneWidth <= 0 || messageRoom > 120 * zoom

        // Where the relative age changes between rows (GitKraken's pills).
        let ageBreaks = AgeBreaks.compute(rows: rows)

        // ScrollView + LazyVStack instead of List: NSTableView-backed List
        // restores/adjusts its scroll offset on SwiftUI updates (selection,
        // background refreshes), producing large jumps. With fixed-height
        // rows and stable ids, LazyVStack never moves the scroll position.
        // Same indentation trick as ScrollViewReader/ScrollView below: the
        // banner strip stacks above the graph without reindenting it.
        VStack(spacing: 0) {
        if let op = repo.snapshot.operation, !repo.snapshot.conflicted.isEmpty {
            ConflictGraphBanner(op: op, repo: repo)
        }
        ScrollViewReader { proxy in
        ScrollView {
            // Leading-aligned: rows whose fixed columns overflow a narrow
            // window report different widths, and the default center
            // alignment would shift each row by half its own overflow —
            // the WIP row and commit rows stopped lining up.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Group {
                        if row.commit.isWip {
                            // WIP is a synthetic commit laid out like any other,
                            // so its dashed node sits exactly on HEAD's lane.
                            WipGraphRow(
                                row: row,
                                changeCount: changeCount,
                                graphWidth: graphWidth,
                                badgeWidth: badgeWidth,
                                scrollX: scrollX,
                                fadeLeading: fadeLeading,
                                fadeTrailing: fadeTrailing
                            )
                                .contentShape(Rectangle())
                                // Clicking WIP returns the right panel to the commit box.
                                .onTapGesture { repo.selectedCommit = nil }
                                .contextMenu {
                                    Button("Stage All Changes") { repo.stageAll() }
                                    Button("Stash All Changes") { repo.stash() }
                                    Divider()
                                    Button("Discard All Changes…", role: .destructive) {
                                        repo.confirmDiscardAll = true
                                    }
                                }
                        } else if row.commit.isStash {
                            // A stash row: laid out like any commit, so its
                            // dashed line lands on the base commit's lane.
                            StashGraphRow(
                                row: row,
                                graphWidth: graphWidth,
                                badgeWidth: badgeWidth,
                                repo: repo,
                                scrollX: scrollX,
                                fadeLeading: fadeLeading,
                                fadeTrailing: faded,
                                tinted: tintRows
                            )
                        } else {
                            GraphRowView(
                                row: row,
                                graphWidth: graphWidth,
                                badgeWidth: badgeWidth,
                                faded: faded,
                                fadeLeading: fadeLeading,
                                searchMode: searching,
                                repo: repo,
                                scrollX: scrollX,
                                tinted: tintRows
                            )
                            // Infinite scroll: reaching the last row loads 500 more.
                            .onAppear { repo.loadMoreIfNeeded(row) }
                        }
                    }
                    .frame(height: rowH)
                    // The age pill rides the top edge of the first row of
                    // each older block, drawn after (so above) the row
                    // before it.
                    .overlay(alignment: .topTrailing) {
                        if let label = ageBreaks[row.id] {
                            AgeBreakPill(label: label)
                        }
                    }
                    // Leading-aligned even when the row's fixed columns
                    // exceed the window: an overflowing HStack is centered
                    // by default, which shifts each row left by half its
                    // own overflow — rows with different content (WIP vs
                    // commit) would shift by different amounts and the
                    // lane columns stop lining up.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.leadingInset)
                    .padding(.trailing, 8)
                    .id(row.id)
                }
            }
        }
        // Sidebar tag/branch clicks land here: jump the graph to the commit.
        .onChange(of: repo.scrollTarget) { _, target in
            if let target {
                proxy.scrollTo(target, anchor: .center)
                repo.scrollTarget = nil
            }
        }
        // This pane is reused across tabs rather than rebuilt, so the
        // NSScrollView carries its offset from whatever repo you were just
        // looking at. Land on the newest commit, which is where a rebuilt
        // pane used to start.
        .onChange(of: repo.id) { _, _ in
            if let top = rows.first?.id { proxy.scrollTo(top, anchor: .top) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            paneWidth = $0
        }
        .overlay(alignment: .topLeading) {
            // Only over the lane column: scrolling elsewhere is unaffected.
            if maxScroll > 0 {
                HorizontalScrollCatcher { delta in
                    repo.graphScrollX = min(max(repo.graphScrollX - delta, 0), maxScroll)
                }
                .frame(width: graphWidth + Self.leadingInset + badgeWidth)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        }
        }
    }
}

/// GitKraken's amber strip over the graph: conflicts exist, and here is
/// the operation that hit them. The commit panel owns resolution — this
/// only makes the state impossible to miss from the graph.
struct ConflictGraphBanner: View {
    let op: OngoingOperation
    @ObservedObject var repo: RepoState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomFont(12)
                .foregroundStyle(.orange)
            Text(text)
                .zoomFont(12, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var text: String {
        let n = repo.snapshot.conflicted.count
        let files = "\(n) file conflict\(n == 1 ? "" : "s")"
        if let headline = repo.snapshot.operationHeadline {
            return "\(files) — \(headline)"
        }
        return "\(files) — resolve them to continue the \(op.rawValue.lowercased())"
    }
}

/// GitKraken's "// WIP" row: the synthetic WIP commit rendered by the
/// regular lane canvas (dashed), so it always connects to HEAD's line.
struct WipGraphRow: View {
    let row: GraphRow
    let changeCount: Int
    let graphWidth: CGFloat
    let badgeWidth: CGFloat
    var scrollX: CGFloat = 0
    var fadeLeading = false
    var fadeTrailing = false
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                Spacer().frame(width: badgeWidth)
            }

            LaneCanvas(
                row: row,
                scrollX: scrollX,
                fadeLeading: fadeLeading,
                fadeTrailing: fadeTrailing
            )
            .frame(width: graphWidth, height: GraphView.rowHeight * zoom)

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 3, height: 16 * zoom)

            Text("// WIP")
                .zoomFont(12, design: .monospaced)
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .zoomFont(9, weight: .bold)
                Text("\(changeCount)")
                    .zoomFont(11, weight: .semibold)
                    .contentTransition(.numericText(value: Double(changeCount)))
                    .animation(.easeOut(duration: 0.2), value: changeCount)
            }
            .foregroundStyle(.green)

            Spacer(minLength: 12)
        }
        .background(Color.primary.opacity(0.04))
    }
}

/// A stash as its own graph row, GitKraken-style: a dashed node on its own
/// lane, a dashed line into the base commit below, the stash message as the
/// row text. Clicking highlights the stash in the sidebar; the context menu
/// mirrors the sidebar row's.
struct StashGraphRow: View {
    let row: GraphRow
    let graphWidth: CGFloat
    let badgeWidth: CGFloat
    @ObservedObject var repo: RepoState
    var scrollX: CGFloat = 0
    var fadeLeading = false
    var fadeTrailing = false
    /// Off in narrow panes — see the gate in GraphView.
    var tinted = true
    @Environment(\.uiZoom) private var zoom

    /// The snapshot's stash for this row. Rebuilt from the row itself when
    /// the list has renumbered mid-refresh — rows and stashes then disagree
    /// for one frame, and the row is what's on screen.
    private var stash: Stash {
        let ref = row.commit.stashRef ?? ""
        return repo.snapshot.stashes.first { $0.ref == ref }
            ?? Stash(
                ref: ref,
                date: row.commit.date,
                message: row.commit.subject,
                baseHash: row.commit.parents.first ?? ""
            )
    }

    /// Stashes hang off a commit, not off HEAD's history directly: bright
    /// exactly when the commit they were taken on is — or, with a commit
    /// selected, when the stash belongs to its lineage.
    private var onCurrentBranch: Bool {
        if let lineage = repo.lineageSet { return lineage.contains(row.commit.hash) }
        return repo.snapshot.reachableFromHead.contains(row.commit.parents.first ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                Spacer().frame(width: badgeWidth)
            }

            LaneCanvas(
                row: row,
                dimmed: !onCurrentBranch,
                brightColors: repo.lineageColors ?? repo.snapshot.brightColors,
                scrollX: scrollX,
                fadeLeading: fadeLeading,
                fadeTrailing: fadeTrailing
            )
            .frame(width: graphWidth, height: GraphView.rowHeight * zoom)
            .clipped()

            RoundedRectangle(cornerRadius: 1)
                .fill(LaneCanvas.color(row.columnColor))
                .frame(width: 3, height: 16 * zoom)
                .opacity(onCurrentBranch ? 1 : 0.45)

            Text(stash.message)
                .zoomFont(12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            Text(stash.ref)
                .zoomFont(11, design: .monospaced)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .background(
            repo.selectedStashRef == stash.ref
                ? Color.accentColor.opacity(0.22)
                : tinted ? LaneCanvas.color(row.columnColor).opacity(0.055) : .clear
        )
        .contentShape(Rectangle())
        .onTapGesture { repo.selectedStashRef = stash.ref }
        .contextMenu {
            Button("Apply (keep stash)") { repo.applyStash(stash) }
            Button("Pop (apply and remove)") { repo.popStash(stash) }
            Divider()
            Button("Create branch from stash…") {
                repo.promptText = ""
                repo.branchPrompt = .branchFromStash(stash)
            }
            Divider()
            Button("Drop…", role: .destructive) { repo.stashToDrop = stash }
        }
    }
}

struct GraphRowView: View {
    let row: GraphRow
    let graphWidth: CGFloat
    let badgeWidth: CGFloat
    let faded: Bool
    var fadeLeading = false
    var searchMode: Bool = false
    @ObservedObject var repo: RepoState
    var scrollX: CGFloat = 0
    /// Off in narrow panes — see the gate in GraphView.
    var tinted = true
    @ObservedObject private var avatars = AvatarStore.shared
    @Environment(\.uiZoom) private var zoom

    /// In search mode lane lines are meaningless (rows are filtered),
    /// so each row shows just its node in column 0.
    private var displayRow: GraphRow {
        guard searchMode else { return row }
        return GraphRow(
            commit: row.commit,
            column: 0,
            columnColor: row.columnColor,
            passThrough: [],
            mergeSources: [],
            parentLanes: [],
            laneCount: 1
        )
    }

    /// True when this commit is the tip of the checked-out branch.
    private var isHead: Bool {
        row.commit.refs.contains { $0.hasPrefix("HEAD") }
    }

    /// Full brightness for the checked-out branch's history; everything
    /// else is dimmed so "what's on my branch" reads at a glance.
    private var onCurrentBranch: Bool {
        row.commit.isWip || repo.snapshot.reachableFromHead.contains(row.commit.hash)
    }

    /// With a commit selected, its lineage takes over the spotlight:
    /// bright = related to the selection, not "on the current branch".
    private var bright: Bool {
        if let lineage = repo.lineageSet { return lineage.contains(row.commit.hash) }
        return onCurrentBranch
    }

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                BadgeColumn(
                    refs: row.commit.refs,
                    localBranches: repo.snapshot.localBranches,
                    remotes: Set(repo.snapshot.remoteNames),
                    repo: repo,
                    maxBadgeWidth: max(40, badgeWidth - 34)
                )
                .frame(width: badgeWidth, alignment: .trailing)
                // Above the lane canvas, so the hover-expanded badge isn't
                // drawn under the commit nodes it floats across.
                .zIndex(1)
            }

            LaneCanvas(
                row: displayRow,
                dimmed: !bright,
                brightColors: searchMode
                    ? nil
                    : (repo.lineageColors ?? repo.snapshot.brightColors),
                avatar: avatars.isEnabled
                    ? avatars.avatar(
                        for: row.commit.email,
                        name: row.commit.author,
                        forge: repo.avatarForge
                    )
                    : nil,
                scrollX: scrollX,
                fadeLeading: fadeLeading,
                fadeTrailing: faded
            )
            .frame(width: graphWidth, height: GraphView.rowHeight * zoom)
            .clipped()

            // Branch-colored tick before the message, GitKraken-style.
            RoundedRectangle(cornerRadius: 1)
                .fill(LaneCanvas.color(row.columnColor))
                .frame(width: 3, height: 16 * zoom)
                .opacity(bright ? 1 : 0.45)

            Text(row.commit.subject)
                .zoomFont(12)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(bright ? 1 : 0.55)

            Spacer(minLength: 12)

            // Fixed-width trailing columns: the message truncates,
            // author/hash never wrap or shrink.
            Text(row.commit.author)
                .zoomFont(11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90 * zoom, alignment: .trailing)
                .help(row.commit.author)
                .opacity(bright ? 1 : 0.55)

            Text(row.commit.shortHash)
                .zoomFont(11, design: .monospaced)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .opacity(bright ? 1 : 0.55)
        }
        .background(
            repo.selectedCommit == row.commit.hash
                ? Color.accentColor.opacity(0.22)
                // Subtle branch-color tint per row, GitKraken-style.
                : tinted ? LaneCanvas.color(row.columnColor).opacity(0.055) : .clear
        )
        .contentShape(Rectangle())
        .onTapGesture { repo.selectedCommit = row.commit.hash }
        .contextTarget(row.commit.hash, repo)
        .contextMenu { menuItems }
        // Drag a commit onto a branch to cherry-pick it there. The WIP row
        // isn't a real commit, so it isn't draggable.
        .modifier(CommitDragSource(commit: row.commit))
    }

    /// Branches whose tip is this commit (from its decorations).
    private var branchesHere: [Branch] {
        RefBadge.infos(for: row.commit.refs, remotes: Set(repo.snapshot.remoteNames))
            .filter { !$0.isTag }
            .compactMap { info in
                repo.snapshot.localBranches.first { $0.name == info.label }
                    ?? repo.snapshot.remoteBranches.first { $0.name == info.label }
            }
    }

    /// The current branch when this row is its upstream tip and the branch is
    /// purely behind — the one state where `git merge --ff-only` just works, so
    /// it's also the only state where the offer can't fail.
    private var fastForwardHere: (branch: Branch, upstream: String)? {
        guard let branch = repo.snapshot.localBranches.first(where: \.isCurrent),
              branch.behind > 0, branch.ahead == 0,
              let upstream = branch.upstream, !branch.upstreamGone,
              repo.snapshot.remoteBranches.first(where: { $0.name == upstream })?.tipHash
                  == row.commit.hash
        else { return nil }
        return (branch, upstream)
    }

    /// GitKraken-style commit context menu.
    @ViewBuilder
    private var menuItems: some View {
        let commit = row.commit
        let current = repo.snapshot.currentBranch ?? "HEAD"

        // GitKraken leads with the catch-up move, and so do we: right-clicking
        // the upstream tip while HEAD sits behind it means "get me there", and
        // Checkout alone leaves you a pull short.
        if let ff = fastForwardHere {
            Button("Fast-forward \(ff.branch.name) to \(ff.upstream) (↓\(ff.branch.behind))") {
                repo.fastForward(ff.branch)
            }
            Divider()
        }

        // Branch tips on this commit come first: switching branches is the
        // most common intent when right-clicking a labeled row.
        let tips = branchesHere
        if !tips.isEmpty {
            ForEach(tips) { branch in
                Button("Checkout \(branch.name)") { repo.checkout(branch) }
                    .disabled(branch.isCurrent)
            }
            Divider()
        }

        Button("Checkout this commit (detached)") { repo.checkoutCommit(commit) }
        Button("Create worktree from this commit…") { repo.addWorktree(atCommit: commit) }
        Divider()
        Button("Create branch here…") {
            repo.promptText = ""
            repo.branchPrompt = .createBranchAtCommit(commit)
        }
        Button("Cherry pick commit") { repo.cherryPick(commit) }
        // The branch row offers merge/rebase as a pair; the commit menu had
        // only rebase. Merging HEAD into itself is a no-op, so that row —
        // and only that row — leaves the item out. A branch tip here names
        // itself in the label, the way the sidebar does.
        if !isHead {
            if let tip = tips.first(where: { !$0.isCurrent }) {
                Button("Merge \(tip.name) into \(current)") { repo.merge(tip) }
            } else {
                Button("Merge this commit into \(current)") { repo.merge(commit) }
            }
        }
        Button("Rebase \(current) onto this commit") { repo.rebaseOntoCommit(commit) }
        Menu("Reset \(current) to this commit") {
            Button("Soft — keep all changes staged") { repo.reset(to: commit, mode: .soft) }
            Button("Mixed — keep changes, unstaged") { repo.reset(to: commit, mode: .mixed) }
            Button("Hard — discard all changes…", role: .destructive) {
                repo.commitToHardReset = commit
            }
        }
        Button("Revert commit") { repo.revert(commit) }
        if isHead {
            Divider()
            Button("Edit commit message…") {
                repo.promptText = commit.subject
                repo.branchPrompt = .amendMessage(commit)
            }
        }
        Divider()
        Button("Copy commit sha") { RepoState.copyToPasteboard(commit.hash) }
        Button("Copy commit message") { repo.copyCommitMessage(commit) }
        Button("Copy link to this commit on origin") { repo.copyRemoteLink(for: commit) }
        Button("Create patch from commit…") { repo.savePatch(for: commit) }
        Divider()
        Button("Create tag here…") {
            repo.promptText = ""
            repo.branchPrompt = .tagCommit(commit)
        }
    }
}

/// GitKraken-style relative-age pills ("6 days ago", "a week ago"): shown
/// straddling the row boundary wherever the age label changes, so runs of
/// same-aged commits read as one block and time jumps become visible.
enum AgeBreaks {
    /// Row id -> label, for rows whose age label differs from the row
    /// above. The first row gets none — a pill on top of the newest
    /// commit would label everything and mark nothing.
    static func compute(rows: [GraphRow], now: Date = Date()) -> [String: String] {
        var result: [String: String] = [:]
        var previous: String?
        for row in rows {
            // Synthetic rows have no meaningful date (WIP sits at
            // distantFuture) and must not break a run.
            guard !row.commit.isWip, !row.commit.isStash else { continue }
            let days = max(0, Int(now.timeIntervalSince(row.commit.date) / 86_400))
            let label = Self.label(daysAgo: days)
            if let previous, label != previous { result[row.id] = label }
            previous = label
        }
        return result
    }

    /// The same scale, abbreviated, for places with a column instead of a
    /// pill to put it in — the Dashboard's cards. "3 days ago" at the end of
    /// a 300pt card takes the width the commit subject needs.
    static func compact(date: Date, now: Date = Date()) -> String {
        let d = max(0, Int(now.timeIntervalSince(date) / 86_400))
        switch d {
        case 0: return "today"
        case 1: return "1d"
        case ..<7: return "\(d)d"
        case ..<31: return "\(d / 7)w"
        case ..<366: return "\(max(1, d / 30))mo"
        default: return "\(d / 365)y"
        }
    }

    static func label(daysAgo d: Int) -> String {
        switch d {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<7: return "\(d) days ago"
        case ..<14: return "a week ago"
        case ..<31: return "\(d / 7) weeks ago"
        case ..<61: return "a month ago"
        case ..<366: return "\(d / 30) months ago"
        case ..<731: return "a year ago"
        default: return "\(d / 365) years ago"
        }
    }
}

/// The pill itself — quiet, right-aligned, half over the boundary it marks.
struct AgeBreakPill: View {
    let label: String
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        Text(label)
            .zoomFont(10, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.1))
            )
            .padding(.trailing, 10)
            .offset(y: -9 * zoom)
            .allowsHitTesting(false)
    }
}

/// Draws one row's slice of the commit graph.
struct LaneCanvas: View {
    let row: GraphRow
    /// Dim this commit's node when it isn't on the current branch.
    var dimmed: Bool = false
    /// Branch-line color ids on the current branch; nil = everything bright.
    var brightColors: Set<Int>? = nil
    /// Nil means "draw initials" — loading, disabled, or failed all look
    /// the same from here on purpose.
    var avatar: Image? = nil
    /// Shared horizontal scroll offset for the lane column.
    var scrollX: CGFloat = 0
    /// Fade the lane lines at the edges where content continues. Applied to
    /// the lines only, in-canvas — a pinned node must not fade with them.
    var fadeLeading = false
    var fadeTrailing = false
    @Environment(\.uiZoom) private var zoom

    /// OKLCH-harmonized lane colors: one lightness (0.70), one chroma
    /// percentage (72% of each hue's sRGB maximum), ten hues ordered so
    /// neighbouring lanes sit far apart on the wheel. Equal perceived
    /// brightness is what keeps a busy graph from strobing — the stock
    /// SwiftUI colors differ wildly in it. (Gold runs lighter as an
    /// optical correction; yellows at L 0.70 read as olive.)
    static let palette: [Color] = [
        Color(red: 0.385, green: 0.640, blue: 0.897),  // blue      250°
        Color(red: 0.703, green: 0.524, blue: 0.898),  // purple    305°
        Color(red: 0.335, green: 0.692, blue: 0.649),  // teal      185°
        Color(red: 0.852, green: 0.533, blue: 0.301),  // orange     55°
        Color(red: 0.909, green: 0.430, blue: 0.678),  // pink      350°
        Color(red: 0.335, green: 0.714, blue: 0.434),  // green     150°
        Color(red: 0.556, green: 0.591, blue: 0.897),  // indigo    278°
        Color(red: 0.908, green: 0.471, blue: 0.479),  // red        20°
        Color(red: 0.332, green: 0.677, blue: 0.757),  // cyan      215°
        Color(red: 0.839, green: 0.702, blue: 0.356),  // gold       88°
    ]

    static func color(_ lane: Int) -> Color {
        palette[lane % palette.count]
    }

    /// Soft edges only where the lanes actually continue, so the fade reads
    /// as "there's more this way" rather than as decoration.
    static func fadeStops(
        leading: Bool, trailing: Bool, width: CGFloat
    ) -> [Gradient.Stop] {
        let edge = min(24 / max(width, 1), 0.4)
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: leading ? .clear : .black, location: 0))
        if leading { stops.append(.init(color: .black, location: edge)) }
        if trailing { stops.append(.init(color: .black, location: 1 - edge)) }
        stops.append(.init(color: trailing ? .clear : .black, location: 1))
        return stops
    }

    var body: some View {
        Canvas { context, size in
            let laneW = GraphView.laneWidth * zoom
            let midY = size.height / 2
            let dotX = x(row.column, laneW)
            let isWip = row.commit.isWip
            // WIP and stash rows share the synthetic-node treatment below:
            // dashed outline, no pinning, hide with their lane.
            let synthetic = isWip || row.commit.isStash

            // Node position on screen. Scrolling right would carry the dot
            // out the left edge; instead it pins at lane 0's center and the
            // lines keep sliding underneath, GitKraken-style. Synthetic
            // nodes are the exception: they aren't real commits, so they
            // hide with their lane instead of pinning — same as GitKraken.
            let pinX = laneW / 2
            let pinned = !synthetic && scrollX > 0 && dotX - scrollX < pinX

            // Lines fade at the edges; the mask lives inside the canvas so
            // the pinned node (drawn later, unmasked) stays fully opaque.
            // When scrolled, a blank strip one lane wide grows in from the
            // left: no line is drawn there, so pinned nodes sit on clean
            // background instead of on top of sliding lines.
            var lineContext = context
            if fadeLeading || fadeTrailing {
                let strip = fadeLeading ? min(scrollX, laneW) : 0
                let span = size.width - strip
                lineContext.clipToLayer { layer in
                    layer.fill(
                        Path(CGRect(x: strip, y: 0, width: span, height: size.height)),
                        with: .linearGradient(
                            Gradient(stops: Self.fadeStops(
                                leading: fadeLeading, trailing: fadeTrailing, width: span
                            )),
                            startPoint: CGPoint(x: strip, y: 0),
                            endPoint: CGPoint(x: size.width, y: 0)
                        )
                    )
                }
            }
            // Horizontal scroll is a draw-time translate rather than a view
            // offset: the Canvas already clips to its frame, so the lanes
            // slide under the fixed badge column with nothing to lay out.
            if scrollX != 0 { lineContext.translateBy(x: -scrollX, y: 0) }

            // Whole lines dim together: an edge is bright when its
            // branch-line color id belongs to the current branch's history.
            func lineAlpha(_ color: Int) -> Double {
                guard let brightColors else { return 1 }
                return brightColors.contains(color) ? 1 : 0.35
            }

            func stroke(_ path: Path, edge: GraphEdge) {
                lineContext.stroke(
                    path,
                    with: .color(Self.color(edge.color).opacity(lineAlpha(edge.color))),
                    // Dash period must divide the row height: each row
                    // strokes its own segment from phase 0, and a pattern
                    // that doesn't tile fuses into blobs at row boundaries.
                    // Both scale by zoom together, so tiling is preserved.
                    // Dashes keep butt caps for the same reason — round
                    // caps grow each dash into its gap. Solid lines get
                    // round caps so segments meeting at row boundaries
                    // and arc joins blend without hairline seams.
                    style: edge.dashed
                        ? StrokeStyle(lineWidth: 2 * zoom, dash: [4 * zoom, 4 * zoom])
                        : StrokeStyle(lineWidth: 2 * zoom, lineCap: .round)
                )
            }

            // Straight pass-through lanes.
            for edge in row.passThrough {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: lx, y: 0))
                p.addLine(to: CGPoint(x: lx, y: size.height))
                stroke(p, edge: edge)
            }

            // Corner radius for the subway-style elbows below. Clamped so
            // the arc never overshoots the horizontal run or the half-row.
            func elbow(_ dx: CGFloat) -> CGFloat {
                min(abs(dx), midY, 9 * zoom)
            }

            // Children lines joining the dot from the top edge: straight
            // down the lane, then one rounded right-angle turn into the
            // dot. A cubic between distant lanes stretched into a long
            // flat S — the orthogonal route stays crisp at any distance.
            for edge in row.mergeSources {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: lx, y: 0))
                if edge.lane == row.column {
                    p.addLine(to: CGPoint(x: dotX, y: midY))
                } else {
                    p.addArc(
                        tangent1End: CGPoint(x: lx, y: midY),
                        tangent2End: CGPoint(x: dotX, y: midY),
                        radius: elbow(dotX - lx)
                    )
                    p.addLine(to: CGPoint(x: dotX, y: midY))
                }
                stroke(p, edge: edge)
            }

            // Lines leaving the dot toward parents at the bottom edge:
            // horizontal run first, then the rounded turn down the lane —
            // the mirror of the merge elbow above.
            for edge in row.parentLanes {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: dotX, y: midY))
                if edge.lane == row.column {
                    p.addLine(to: CGPoint(x: lx, y: size.height))
                } else {
                    p.addArc(
                        tangent1End: CGPoint(x: lx, y: midY),
                        tangent2End: CGPoint(x: lx, y: size.height),
                        radius: elbow(lx - dotX)
                    )
                    p.addLine(to: CGPoint(x: lx, y: size.height))
                }
                stroke(p, edge: edge)
            }

            // The node draws in its own context: trailing fade only, never
            // the leading one — a dot approaching the left edge stays fully
            // opaque until it pins, so there is no fade-then-snap. Synthetic
            // nodes instead share the lines' clipping, so they slide into
            // the blank strip and disappear along with their lane.
            var nodeContext: GraphicsContext
            if synthetic {
                nodeContext = lineContext
            } else {
                nodeContext = context
                if fadeTrailing {
                    nodeContext.clipToLayer { layer in
                        layer.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(
                                Gradient(stops: Self.fadeStops(
                                    leading: false, trailing: true, width: size.width
                                )),
                                startPoint: .zero,
                                endPoint: CGPoint(x: size.width, y: 0)
                            )
                        )
                    }
                }
                if scrollX != 0 { nodeContext.translateBy(x: -scrollX, y: 0) }
            }
            let nodeX = pinned ? scrollX + pinX : dotX

            // Avatar-style node: branch-colored ring around author initials.
            let r: CGFloat = 8 * zoom
            let nodeRect = CGRect(x: nodeX - r, y: midY - r, width: r * 2, height: r * 2)
            nodeContext.fill(
                Path(ellipseIn: nodeRect),
                with: .color(Color(nsColor: .textBackgroundColor))
            )
            if synthetic {
                // Empty dashed circle, GitKraken-style uncommitted node.
                // A stash node carries a tray icon so it can't be mistaken
                // for WIP; both take the branch-line color, which is what
                // ties the node to its dashed line.
                let alpha = dimmed ? 0.45 : 0.9
                nodeContext.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: 1 * zoom, dy: 1 * zoom)),
                    with: .color(Self.color(row.columnColor).opacity(alpha)),
                    style: StrokeStyle(lineWidth: 1.5 * zoom, dash: [3 * zoom, 2.5 * zoom])
                )
                if row.commit.isStash {
                    nodeContext.draw(
                        Text(Image(systemName: "tray.full"))
                            .font(.system(size: 7 * zoom))
                            .foregroundColor(Self.color(row.columnColor).opacity(alpha)),
                        at: CGPoint(x: nodeX, y: midY)
                    )
                }
                return
            }
            let inner = nodeRect.insetBy(dx: 1.5 * zoom, dy: 1.5 * zoom)
            nodeContext.fill(
                Path(ellipseIn: inner),
                with: .color(Self.color(row.columnColor).opacity(dimmed ? 0.1 : 0.22))
            )
            // Avatar under the ring, so the branch color still frames it.
            // Nil covers every failure — loading, offline, 404, undecodable
            // — and the initials below are the single fallback for all of
            // them. There is no third state that could render as broken.
            if let avatar {
                nodeContext.drawLayer { layer in
                    layer.opacity = dimmed ? 0.5 : 1
                    layer.clip(to: Path(ellipseIn: inner))
                    layer.draw(avatar, in: inner)
                }
            }
            nodeContext.stroke(
                Path(ellipseIn: nodeRect),
                with: .color(Self.color(row.columnColor).opacity(dimmed ? 0.45 : 1)),
                lineWidth: 2 * zoom
            )
            if avatar == nil {
                // Plain Font here, not the zoomFont modifier:
                // GraphicsContext.draw takes a Text value, not a View.
                nodeContext.draw(
                    Text(Self.initials(row.commit.author))
                        .font(.system(size: 7 * zoom, weight: .bold))
                        .foregroundColor(Self.color(row.columnColor).opacity(dimmed ? 0.5 : 1)),
                    at: CGPoint(x: nodeX, y: midY)
                )
            }
        }
    }

    static func initials(_ author: String) -> String {
        let parts = author.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private func x(_ lane: Int, _ laneW: CGFloat) -> CGFloat {
        CGFloat(lane) * laneW + laneW / 2
    }
}

/// The BRANCH/TAG column cell: one badge, plus a "+N" pill when a commit
/// carries several refs. Hover the "+N" for the full list.
/// SwiftUI exposes no horizontal scroll deltas, so an AppKit event monitor
/// picks them up for the graph column. A monitor rather than a hit-tested
/// overlay: anything sitting on top of the rows to catch scrolls would also
/// swallow their clicks, drags and context menus.
struct HorizontalScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    final class Coordinator {
        var onScroll: ((CGFloat) -> Void)?
        weak var view: NSView?
        var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window
                else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                // A trackpad reports both axes at once; only take over when
                // the gesture is clearly sideways, or vertical scrolling
                // would drag the graph off to one side.
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                self.onScroll?(event.scrollingDeltaX)
                return nil // consumed
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.install()
    }
}

struct CommitDragSource: ViewModifier {
    let commit: Commit

    func body(content: Content) -> some View {
        if commit.isWip {
            content
        } else {
            content.draggable(DraggedCommit(hash: commit.hash, subject: commit.subject))
        }
    }
}

struct BadgeColumn: View {
    let refs: [String]
    var localBranches: [Branch] = []
    /// Real remote names, for telling remote refs from slashed local ones.
    var remotes: Set<String> = []
    /// When set, badges become drag sources and drop targets.
    var repo: RepoState?
    /// Widest a single badge may get before its label truncates.
    var maxBadgeWidth: CGFloat = 130
    @State private var showOverflow = false
    // Two hover flags, not one: the expanded badge is an overlay that
    // extends past the base badge's bounds, so each needs its own tracking
    // and the expansion lives while the pointer is on either.
    @State private var hoverBase = false
    @State private var hoverTail = false

    /// ahead/behind of the local branch a badge represents, if any.
    private func track(_ info: RefBadge.Info) -> (ahead: Int, behind: Int)? {
        guard info.hasLocal,
              let branch = localBranches.first(where: { $0.name == info.label }),
              branch.ahead > 0 || branch.behind > 0
        else { return nil }
        return (branch.ahead, branch.behind)
    }

    var body: some View {
        let infos = RefBadge.infos(for: refs, remotes: remotes)
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let first = infos.first {
                // Capped rather than left to overflow: an unbounded badge
                // grows past its column and gets sliced by the window edge.
                RefBadge(info: first, track: track(first), repo: repo)
                    .onHover { hoverBase = $0 }
                    // GitKraken hover: the badge expands in place to its
                    // full label, floating over the graph to its right,
                    // until the pointer leaves it. Attached inside the
                    // maxWidth frame so it anchors to the badge itself —
                    // the frame is wider than a short badge, and anchoring
                    // there drew the expansion beside the badge, not on it.
                    .overlay(alignment: .leading) {
                        if hoverBase || hoverTail {
                            RefBadge(info: first, track: track(first), repo: repo)
                                .fixedSize()
                                // The badge's tinted capsule is translucent
                                // (made to sit on the row background); when
                                // floating over the graph it needs an opaque
                                // base or the content bleeds through.
                                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                .onHover { hoverTail = $0 }
                        }
                    }
                    .frame(maxWidth: maxBadgeWidth, alignment: .trailing)
            }
            if infos.count > 1 {
                Button {
                    showOverflow.toggle()
                } label: {
                    Text("+\(infos.count - 1)")
                        .zoomFont(10, weight: .medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.pressEffect)
                .help("Show all refs on this commit")
                .popover(isPresented: $showOverflow, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(infos) { info in
                            RefBadge(info: info, repo: repo)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

struct RefBadge: View {
    struct Info: Identifiable {
        let label: String
        let isHead: Bool
        let isTag: Bool
        /// A local branch ref points at this commit.
        let hasLocal: Bool
        /// A remote-tracking ref points at this commit. Both flags true on
        /// one badge = local and remote are in sync (GitKraken's 💻+☁️).
        let hasRemote: Bool
        var id: String { label }
    }

    let info: Info
    /// ahead/behind vs upstream, shown inside the badge when non-nil.
    var track: (ahead: Int, behind: Int)?
    /// Present in the graph (where badges are draggable), absent in the
    /// static contexts that just render a badge.
    var repo: RepoState?
    @State private var targeted = false

    /// Turn raw %D refs into display badges: drop origin/HEAD, merge the
    /// local + remote refs of the same branch into one badge, HEAD first.
    /// `remotes` are the repo's real remote names — a local branch can
    /// itself contain slashes (feature/x), so "has a slash" cannot tell
    /// local from remote; only the first path component being an actual
    /// remote can.
    static func infos(for refs: [String], remotes: Set<String> = []) -> [Info] {
        var result: [Info] = []
        for ref in refs {
            if ref.hasSuffix("/HEAD") { continue }
            let isHead = ref.hasPrefix("HEAD")
            let isTag = ref.hasPrefix("tag: ")
            var label = ref
            if isTag { label = String(ref.dropFirst(5)) }
            if let arrow = ref.range(of: "-> ") { label = String(ref[arrow.upperBound...]) }
            // "HEAD -> x" always names the checked-out local branch.
            let isRemote = !isTag && !isHead
                && remotes.contains(String(label.split(separator: "/").first ?? ""))
            // "origin/main" collapses into an existing "main" badge (and vice versa).
            let short = isRemote ? label.split(separator: "/").dropFirst().joined(separator: "/") : label
            if let i = result.firstIndex(where: { $0.label == short || ($0.hasRemote && !$0.hasLocal && $0.label.hasSuffix("/" + label)) }) {
                let old = result[i]
                result[i] = Info(
                    label: old.hasRemote && !old.hasLocal ? short : old.label,
                    isHead: old.isHead || isHead,
                    isTag: old.isTag,
                    hasLocal: old.hasLocal || !isRemote,
                    hasRemote: old.hasRemote || isRemote
                )
                continue
            }
            result.append(Info(
                label: label,
                isHead: isHead,
                isTag: isTag,
                hasLocal: !isTag && !isRemote,
                hasRemote: isRemote
            ))
        }
        return result.sorted { $0.isHead && !$1.isHead }
    }

    var color: Color {
        if info.isHead { return .accentColor }
        if info.isTag { return .orange }
        if info.hasRemote && !info.hasLocal { return .purple }
        return .teal
    }

    var body: some View {
        if let repo, !info.isTag {
            capsule
                // Ring rather than fill: the badge already carries a color,
                // and the ring reads instantly without a transition.
                .overlay(
                    Capsule().stroke(Color.accentColor, lineWidth: targeted ? 2 : 0)
                )
                .draggable(DraggedBranch(name: info.label))
                .modifier(BranchDropTarget(branch: dropTarget, repo: repo, targeted: $targeted))
        } else {
            capsule
        }
    }

    /// The badge as a branch, so it can share the sidebar's drop logic.
    /// Remote-only badges become `.remote` and are ignored as targets.
    private var dropTarget: Branch {
        if info.hasLocal {
            return Branch(name: info.label, kind: .local, isCurrent: info.isHead)
        }
        let remote = info.label.split(separator: "/").first.map(String.init) ?? "origin"
        return Branch(name: info.label, kind: .remote(remote), isCurrent: false)
    }

    private var capsule: some View {
        HStack(spacing: 3) {
            // The checked-out branch answers "where am I?" — the one
            // wayfinding fact in the whole column — so it gets the two
            // strongest signals macOS has for "current": a checkmark (the
            // menu-bar convention) and a solid filled capsule (the
            // prominent-button treatment). Every other badge keeps the
            // tinted style; hue alone was the only difference before, and
            // hue is the weakest layer of hierarchy.
            if info.isHead {
                Image(systemName: "checkmark").zoomFont(8, weight: .bold)
            }
            Text(info.label)
                .lineLimit(1)
                .truncationMode(.tail)
            if info.isTag {
                Image(systemName: "tag").zoomFont(8)
            }
            if info.hasLocal && !info.isTag {
                Image(systemName: "laptopcomputer").zoomFont(8)
            }
            if info.hasRemote {
                Image(systemName: "cloud").zoomFont(8)
            }
            if let track {
                Text("\(track.ahead > 0 ? "↑\(track.ahead)" : "")\(track.behind > 0 ? "↓\(track.behind)" : "")")
                    .zoomFont(9, weight: .bold, design: .monospaced)
            }
        }
        .zoomFont(10, weight: info.isHead ? .semibold : .medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(info.isHead ? color : color.opacity(0.18)))
        .foregroundStyle(info.isHead ? Color.white : color)
        .help(helpText)
    }

    private var helpText: String {
        if info.isTag { return "Tag \(info.label)" }
        switch (info.hasLocal, info.hasRemote) {
        case (true, true): return "\(info.label) — local and remote in sync here"
        case (true, false): return "\(info.label) — local branch only"
        default: return "\(info.label) — remote branch"
        }
    }
}
