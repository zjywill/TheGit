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

        List(rows, selection: $repo.selectedCommit) { row in
            GraphRowView(row: row, graphWidth: graphWidth, faded: faded, repo: repo)
                .frame(height: Self.rowHeight)
                .listRowInsets(EdgeInsets(top: 0, leading: Self.leadingInset, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
                .tag(row.commit.hash)
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

struct GraphRowView: View {
    let row: GraphRow
    let graphWidth: CGFloat
    let faded: Bool
    @ObservedObject var repo: RepoState

    /// True when this commit is the tip of the checked-out branch.
    private var isHead: Bool {
        row.commit.refs.contains { $0.hasPrefix("HEAD") }
    }

    var body: some View {
        HStack(spacing: 8) {
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

            ForEach(row.commit.refs.prefix(3), id: \.self) { ref in
                RefBadge(ref: ref)
            }

            Text(row.commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            Text(row.commit.author)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)

            Text(row.commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
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

struct RefBadge: View {
    let ref: String

    var isHead: Bool { ref.hasPrefix("HEAD") }
    var isTag: Bool { ref.hasPrefix("tag: ") }
    var label: String {
        if isTag { return String(ref.dropFirst(5)) }
        if let arrow = ref.range(of: "-> ") { return String(ref[arrow.upperBound...]) }
        return ref
    }

    var color: Color {
        if isHead { return .accentColor }
        if isTag { return .orange }
        if ref.contains("/") { return .purple } // remote ref
        return .teal
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
