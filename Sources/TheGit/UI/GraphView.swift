import SwiftUI

/// Middle panel: commit graph with lane rendering.
struct GraphView: View {
    @ObservedObject var repo: RepoState

    static let rowHeight: CGFloat = 32
    static let laneWidth: CGFloat = 18
    static let defaultVisibleLanes = 8

    /// User-adjusted graph column width; 0 means "auto" (fit, capped at default).
    @AppStorage("graphColumnWidth") private var storedWidth: Double = 0
    @State private var dragBaseWidth: CGFloat?
    @State private var hoveringResizer = false

    private static let leadingInset: CGFloat = 8

    var body: some View {
        let rows = repo.snapshot.graphRows
        let totalLanes = GraphLayout.maxLanes(of: rows)
        let neededWidth = CGFloat(totalLanes) * Self.laneWidth + 8
        let autoWidth = CGFloat(min(totalLanes, Self.defaultVisibleLanes)) * Self.laneWidth + 8
        let graphWidth = storedWidth > 0
            ? min(max(CGFloat(storedWidth), Self.laneWidth * 2), neededWidth)
            : autoWidth
        // Lanes beyond the column width fade out instead of hard-clipping
        // (VS Code Git Graph style). Drag the column edge to reveal them.
        let faded = neededWidth > graphWidth + 1
        // Dedicated BRANCH/TAG column left of the graph (GitKraken layout):
        // zero width when the loaded range has no refs at all.
        let hasBadges = rows.contains { !RefBadge.infos(for: $0.commit.refs).isEmpty }
        let badgeWidth: CGFloat = hasBadges ? 150 : 0

        let changeCount = repo.snapshot.staged.count + repo.snapshot.unstaged.count
            + repo.snapshot.conflicted.count
        // The dashed WIP node sits on the checked-out branch's lane.
        let headRow = rows.first { $0.commit.refs.contains { $0.hasPrefix("HEAD") } }

        List(selection: $repo.selectedCommit) {
            if changeCount > 0 {
                WipRowView(
                    column: headRow?.column ?? 0,
                    color: headRow?.columnColor ?? 0,
                    changeCount: changeCount,
                    graphWidth: graphWidth,
                    badgeWidth: badgeWidth
                )
                .frame(height: Self.rowHeight)
                .listRowInsets(EdgeInsets(top: 0, leading: Self.leadingInset, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in
                GraphRowView(row: row, graphWidth: graphWidth, badgeWidth: badgeWidth, faded: faded, repo: repo)
                    .frame(height: Self.rowHeight)
                    .listRowInsets(EdgeInsets(top: 0, leading: Self.leadingInset, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                    .tag(row.commit.hash)
            }
        }
        .listStyle(.plain)
        .background(Color(nsColor: .textBackgroundColor))
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
                            storedWidth = Double(min(max(base + value.translation.width, Self.laneWidth * 2), neededWidth))
                        }
                        .onEnded { _ in dragBaseWidth = nil }
                )
        }
    }
}

/// GitKraken's "// WIP" row: uncommitted changes shown as a dashed node
/// on the checked-out branch's lane, above the graph.
struct WipRowView: View {
    let column: Int
    let color: Int
    let changeCount: Int
    let graphWidth: CGFloat
    let badgeWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                Spacer().frame(width: badgeWidth)
            }

            Canvas { context, size in
                let laneW = GraphView.laneWidth
                let x = CGFloat(column) * laneW + laneW / 2
                let midY = size.height / 2
                guard x < size.width else { return }
                let tint = LaneCanvas.color(color)
                let r: CGFloat = 7

                var stub = Path()
                stub.move(to: CGPoint(x: x, y: midY + r))
                stub.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    stub,
                    with: .color(tint.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                )

                let rect = CGRect(x: x - r, y: midY - r, width: r * 2, height: r * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(tint.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                )
            }
            .frame(width: graphWidth, height: GraphView.rowHeight)

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 3, height: 16)

            Text("// WIP")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("\(changeCount)")
                    .font(.system(size: 11, weight: .semibold))
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
    @ObservedObject var repo: RepoState

    /// True when this commit is the tip of the checked-out branch.
    private var isHead: Bool {
        row.commit.refs.contains { $0.hasPrefix("HEAD") }
    }

    var body: some View {
        HStack(spacing: 8) {
            if badgeWidth > 0 {
                BadgeColumn(refs: row.commit.refs)
                    .frame(width: badgeWidth, alignment: .trailing)
            }

            LaneCanvas(row: row)
                .frame(width: graphWidth, height: GraphView.rowHeight)
                .mask(
                    LinearGradient(
                        stops: faded
                            ? [.init(color: .black, location: 0),
                               .init(color: .black, location: max(0, 1 - 24 / graphWidth)),
                               .init(color: .clear, location: 1)]
                            : [.init(color: .black, location: 0),
                               .init(color: .black, location: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipped()

            // Branch-colored tick before the message, GitKraken-style.
            RoundedRectangle(cornerRadius: 1)
                .fill(LaneCanvas.color(row.columnColor))
                .frame(width: 3, height: 16)

            Text(row.commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            // Fixed-width trailing columns: the message truncates,
            // author/hash never wrap or shrink.
            Text(row.commit.author)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90, alignment: .trailing)
                .help(row.commit.author)

            Text(row.commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .background(
            // Subtle branch-color tint per row, GitKraken-style.
            LaneCanvas.color(row.columnColor).opacity(0.055)
        )
        .contextMenu { menuItems }
    }

    /// GitKraken-style commit context menu.
    @ViewBuilder
    private var menuItems: some View {
        let commit = row.commit
        let current = repo.snapshot.currentBranch ?? "HEAD"

        Button("Checkout this commit (detached)") { repo.checkoutCommit(commit) }
        Button("Create worktree from this commit…") { repo.addWorktree(atCommit: commit) }
        Divider()
        Button("Create branch here…") {
            repo.promptText = ""
            repo.branchPrompt = .createBranchAtCommit(commit)
        }
        Button("Cherry pick commit") { repo.cherryPick(commit) }
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

    static let palette: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .green, .indigo, .red, .cyan, .yellow,
    ]

    static func color(_ lane: Int) -> Color {
        palette[lane % palette.count]
    }

    var body: some View {
        Canvas { context, size in
            let laneW = GraphView.laneWidth
            let midY = size.height / 2
            let dotX = x(row.column, laneW)

            func stroke(_ path: Path, color: Int) {
                context.stroke(path, with: .color(Self.color(color)), lineWidth: 2)
            }

            // Straight pass-through lanes.
            for edge in row.passThrough {
                let lx = x(edge.lane, laneW)
                var p = Path()
                p.move(to: CGPoint(x: lx, y: 0))
                p.addLine(to: CGPoint(x: lx, y: size.height))
                stroke(p, color: edge.color)
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
                stroke(p, color: edge.color)
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
                stroke(p, color: edge.color)
            }

            // Avatar-style node: branch-colored ring around author initials.
            let r: CGFloat = 8
            let nodeRect = CGRect(x: dotX - r, y: midY - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: nodeRect),
                with: .color(Color(nsColor: .textBackgroundColor))
            )
            context.fill(
                Path(ellipseIn: nodeRect.insetBy(dx: 1.5, dy: 1.5)),
                with: .color(Self.color(row.columnColor).opacity(0.22))
            )
            context.stroke(
                Path(ellipseIn: nodeRect),
                with: .color(Self.color(row.columnColor)),
                lineWidth: 2
            )
            context.draw(
                Text(Self.initials(row.commit.author))
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Self.color(row.columnColor)),
                at: CGPoint(x: dotX, y: midY)
            )
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
struct BadgeColumn: View {
    let refs: [String]
    @State private var showOverflow = false

    var body: some View {
        let infos = RefBadge.infos(for: refs)
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let first = infos.first {
                RefBadge(info: first)
            }
            if infos.count > 1 {
                Button {
                    showOverflow.toggle()
                } label: {
                    Text("+\(infos.count - 1)")
                        .font(.system(size: 10, weight: .medium))
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
                            RefBadge(info: info)
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
        HStack(spacing: 3) {
            Text(info.label)
                .lineLimit(1)
                .truncationMode(.tail)
            if info.isTag {
                Image(systemName: "tag").font(.system(size: 8))
            }
            if info.hasLocal && !info.isTag {
                Image(systemName: "laptopcomputer").font(.system(size: 8))
            }
            if info.hasRemote {
                Image(systemName: "cloud").font(.system(size: 8))
            }
        }
        .font(.system(size: 10, weight: .medium))
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
