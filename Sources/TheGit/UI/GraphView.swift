import SwiftUI

/// Middle panel: commit graph with lane rendering.
struct GraphView: View {
    @ObservedObject var repo: RepoState
    @Environment(\.uiZoom) private var zoom

    /// Base metrics at zoom 1; multiply by the environment's uiZoom.
    static let rowHeight: CGFloat = 32
    static let laneWidth: CGFloat = 18
    static let defaultVisibleLanes = 8

    /// User-adjusted graph column width; 0 means "auto" (fit, capped at default).
    @AppStorage("graphColumnWidth") private var storedWidth: Double = 0
    @State private var dragBaseWidth: CGFloat?
    @State private var hoveringResizer = false
    /// Shared horizontal offset for the lane column. The ref-label column
    /// sits outside it, so labels stay put while the lanes slide.
    @State private var graphScrollX: CGFloat = 0

    private static let leadingInset: CGFloat = 8

    var body: some View {
        let allRows = repo.snapshot.graphRows
        let query = repo.searchText.trimmingCharacters(in: .whitespaces)
        let searching = !query.isEmpty
        // Search filters to a flat list — lane lines are meaningless across
        // filtered gaps, so rows collapse to a single node column.
        let rows = searching
            ? allRows.filter {
                !$0.commit.isWip
                    && ($0.commit.subject.localizedCaseInsensitiveContains(query)
                        || $0.commit.author.localizedCaseInsensitiveContains(query)
                        || $0.commit.hash.hasPrefix(query.lowercased()))
            }
            : allRows
        // Stash nodes occupy the first free lane(s) to the right of their
        // base commit's row; widen the graph only when stashes exist.
        let stashesByBase = searching ? [:] : repo.snapshot.stashesByBase
        let totalLanes = stashesByBase.isEmpty
            ? GraphLayout.maxLanes(of: rows)
            : rows.map { $0.laneCount + (stashesByBase[$0.commit.hash]?.count ?? 0) }.max() ?? 1
        let laneW = Self.laneWidth * zoom
        let rowH = Self.rowHeight * zoom
        let neededWidth = CGFloat(totalLanes) * laneW + 8
        let autoWidth = CGFloat(min(totalLanes, Self.defaultVisibleLanes)) * laneW + 8
        let graphWidth = searching
            ? laneW * 2
            : storedWidth > 0
                ? min(max(CGFloat(storedWidth), laneW * 2), neededWidth)
                : autoWidth
        // How far the lanes can slide before their right edge is reached.
        let maxScroll = max(0, neededWidth - graphWidth)
        let scrollX = min(graphScrollX, maxScroll)
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

        // ScrollView + LazyVStack instead of List: NSTableView-backed List
        // restores/adjusts its scroll offset on SwiftUI updates (selection,
        // background refreshes), producing large jumps. With fixed-height
        // rows and stable ids, LazyVStack never moves the scroll position.
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
                                stashes: stashesByBase[row.commit.hash] ?? []
                            )
                            // Infinite scroll: reaching the last row loads 500 more.
                            .onAppear { repo.loadMoreIfNeeded(row) }
                        }
                    }
                    .frame(height: rowH)
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
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topLeading) {
            // Only over the lane column: scrolling elsewhere is unaffected.
            if maxScroll > 0 {
                HorizontalScrollCatcher { delta in
                    graphScrollX = min(max(graphScrollX - delta, 0), maxScroll)
                }
                .frame(width: graphWidth + Self.leadingInset + badgeWidth)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        }
        .overlay(alignment: .topLeading) {
            // Column resizer, spreadsheet-style: the graph is one column of a
            // table. Tracks the pointer 1:1 — no animation on direct manipulation.
            Rectangle()
                .fill(hoveringResizer || dragBaseWidth != nil
                    ? Color.accentColor.opacity(0.6)
                    : Color.primary.opacity(0.07))
                // Hover tint fades; the width drag itself stays 1:1.
                .animation(.easeOut(duration: 0.1), value: hoveringResizer)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: Self.leadingInset + graphWidth + 2)
                .contentShape(Rectangle().inset(by: -4))
                .onHover { inside in
                    hoveringResizer = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = dragBaseWidth ?? graphWidth
                            dragBaseWidth = base
                            storedWidth = Double(min(max(base + value.translation.width, laneW * 2), neededWidth))
                        }
                        .onEnded { _ in dragBaseWidth = nil }
                )
        }
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

struct GraphRowView: View {
    let row: GraphRow
    let graphWidth: CGFloat
    let badgeWidth: CGFloat
    let faded: Bool
    var fadeLeading = false
    var searchMode: Bool = false
    @ObservedObject var repo: RepoState
    var scrollX: CGFloat = 0
    /// Stashes taken on this commit; drawn as dashed nodes to the right.
    var stashes: [Stash] = []
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

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                BadgeColumn(
                    refs: row.commit.refs,
                    localBranches: repo.snapshot.localBranches,
                    repo: repo,
                    maxBadgeWidth: max(40, badgeWidth - 34)
                )
                .frame(width: badgeWidth, alignment: .trailing)
            }

            LaneCanvas(
                row: displayRow,
                dimmed: !onCurrentBranch,
                brightColors: searchMode ? nil : repo.snapshot.brightColors,
                avatar: avatars.isEnabled
                    ? avatars.avatar(
                        for: row.commit.email,
                        gitlabRepo: repo.forge == .gitlab ? repo.path : nil
                    )
                    : nil,
                scrollX: scrollX,
                fadeLeading: fadeLeading,
                fadeTrailing: faded,
                stashCount: searchMode ? 0 : stashes.count,
                stashStartLane: row.laneCount
            )
            .frame(width: graphWidth, height: GraphView.rowHeight * zoom)
                .overlay(alignment: .leading) {
                    // Hit areas over the canvas-drawn stash nodes. An
                    // overlay adds nothing to the row's layout, so lane
                    // alignment can't drift. Only the on-screen part of a
                    // node is interactive (clipped() doesn't stop hits).
                    if !searchMode {
                        let laneW = GraphView.laneWidth * zoom
                        ForEach(Array(stashes.enumerated()), id: \.element.ref) { i, stash in
                            let cx = CGFloat(row.laneCount + i) * laneW + laneW / 2 - scrollX
                            if cx > 0, cx < graphWidth {
                                Color.clear
                                    .frame(width: laneW, height: laneW)
                                    .contentShape(Circle())
                                    .onTapGesture { repo.selectedStashRef = stash.ref }
                                    .help("\(stash.ref) — \(stash.message)")
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
                                    .offset(x: cx - laneW / 2)
                            }
                        }
                    }
                }
                .clipped()

            // Branch-colored tick before the message, GitKraken-style.
            RoundedRectangle(cornerRadius: 1)
                .fill(LaneCanvas.color(row.columnColor))
                .frame(width: 3, height: 16 * zoom)
                .opacity(onCurrentBranch ? 1 : 0.45)

            Text(row.commit.subject)
                .zoomFont(12)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(onCurrentBranch ? 1 : 0.55)

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
                .opacity(onCurrentBranch ? 1 : 0.55)

            Text(row.commit.shortHash)
                .zoomFont(11, design: .monospaced)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .opacity(onCurrentBranch ? 1 : 0.55)
        }
        .background(
            repo.selectedCommit == row.commit.hash
                ? Color.accentColor.opacity(0.22)
                // Subtle branch-color tint per row, GitKraken-style.
                : LaneCanvas.color(row.columnColor).opacity(0.055)
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
        RefBadge.infos(for: row.commit.refs)
            .filter { !$0.isTag }
            .compactMap { info in
                repo.snapshot.localBranches.first { $0.name == info.label }
                    ?? repo.snapshot.remoteBranches.first { $0.name == info.label }
            }
    }

    /// GitKraken-style commit context menu.
    @ViewBuilder
    private var menuItems: some View {
        let commit = row.commit
        let current = repo.snapshot.currentBranch ?? "HEAD"

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
    /// Stash nodes for this row: dashed grey circles in the first free
    /// lanes right of `stashStartLane`, GitKraken-style. Zero when none.
    var stashCount = 0
    var stashStartLane = 0
    @Environment(\.uiZoom) private var zoom

    static let palette: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .green, .indigo, .red, .cyan, .yellow,
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

            // Node position on screen. Scrolling right would carry the dot
            // out the left edge; instead it pins at lane 0's center and the
            // lines keep sliding underneath, GitKraken-style. The WIP node
            // is the exception: it isn't a real commit, so it hides with
            // its lane instead of pinning — same as GitKraken.
            let pinX = laneW / 2
            let pinned = !isWip && scrollX > 0 && dotX - scrollX < pinX

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
                    style: edge.dashed
                        ? StrokeStyle(lineWidth: 2 * zoom, dash: [4 * zoom, 4 * zoom])
                        : StrokeStyle(lineWidth: 2 * zoom)
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

            // Children lines joining the dot from the top edge.
            for edge in row.mergeSources {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: lx, y: 0))
                if edge.lane == row.column {
                    p.addLine(to: CGPoint(x: dotX, y: midY))
                } else {
                    p.addCurve(
                        to: CGPoint(x: dotX, y: midY),
                        control1: CGPoint(x: lx, y: midY * 0.8),
                        control2: CGPoint(x: dotX, y: midY * 0.4)
                    )
                }
                stroke(p, edge: edge)
            }

            // Lines leaving the dot toward parents at the bottom edge.
            for edge in row.parentLanes {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: dotX, y: midY))
                if edge.lane == row.column {
                    p.addLine(to: CGPoint(x: lx, y: size.height))
                } else {
                    p.addCurve(
                        to: CGPoint(x: lx, y: size.height),
                        control1: CGPoint(x: dotX, y: midY + midY * 0.6),
                        control2: CGPoint(x: lx, y: midY + midY * 0.2)
                    )
                }
                stroke(p, edge: edge)
            }

            // Stash nodes: dashed grey circles beside the base commit, in
            // the lines' context on purpose — they scroll, fade and hide
            // with the lanes and never pin, so they cannot disturb the
            // row's alignment.
            for i in 0..<stashCount {
                let sx = x(stashStartLane + i, laneW)
                let sr: CGFloat = 7 * zoom
                let stashRect = CGRect(x: sx - sr, y: midY - sr, width: sr * 2, height: sr * 2)
                lineContext.fill(
                    Path(ellipseIn: stashRect),
                    with: .color(Color(nsColor: .textBackgroundColor))
                )
                lineContext.stroke(
                    Path(ellipseIn: stashRect),
                    with: .color(.secondary.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.5 * zoom, dash: [3 * zoom, 2.5 * zoom])
                )
                lineContext.draw(
                    Text(Image(systemName: "tray.full"))
                        .font(.system(size: 7 * zoom))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: sx, y: midY)
                )
            }

            // The node draws in its own context: trailing fade only, never
            // the leading one — a dot approaching the left edge stays fully
            // opaque until it pins, so there is no fade-then-snap. The WIP
            // node instead shares the lines' clipping, so it slides into
            // the blank strip and disappears along with its lane.
            var nodeContext: GraphicsContext
            if isWip {
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
            if isWip {
                // Empty dashed circle, GitKraken-style uncommitted node.
                nodeContext.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: 1 * zoom, dy: 1 * zoom)),
                    with: .color(Self.color(row.columnColor).opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.5 * zoom, dash: [3 * zoom, 2.5 * zoom])
                )
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
    /// When set, badges become drag sources and drop targets.
    var repo: RepoState?
    /// Widest a single badge may get before its label truncates.
    var maxBadgeWidth: CGFloat = 130
    @State private var showOverflow = false

    /// ahead/behind of the local branch a badge represents, if any.
    private func track(_ info: RefBadge.Info) -> (ahead: Int, behind: Int)? {
        guard info.hasLocal,
              let branch = localBranches.first(where: { $0.name == info.label }),
              branch.ahead > 0 || branch.behind > 0
        else { return nil }
        return (branch.ahead, branch.behind)
    }

    var body: some View {
        let infos = RefBadge.infos(for: refs)
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let first = infos.first {
                // Capped rather than left to overflow: an unbounded badge
                // grows past its column and gets sliced by the window edge.
                RefBadge(info: first, track: track(first), repo: repo)
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
    static func infos(for refs: [String]) -> [Info] {
        var result: [Info] = []
        for ref in refs {
            if ref.hasSuffix("/HEAD") { continue }
            let isHead = ref.hasPrefix("HEAD")
            let isTag = ref.hasPrefix("tag: ")
            var label = ref
            if isTag { label = String(ref.dropFirst(5)) }
            if let arrow = ref.range(of: "-> ") { label = String(ref[arrow.upperBound...]) }
            let isRemote = !isTag && label.contains("/") // heuristic: origin/x
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
        .zoomFont(10, weight: .medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundStyle(color)
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
