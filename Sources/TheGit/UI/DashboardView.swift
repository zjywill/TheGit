import AppKit
import SwiftUI

/// The window's home: every repository the user has added on one wall of
/// cards — whether or not it has a tab open — each
/// answering the two questions a tab bar can't — is there uncommitted work
/// in there, and what happened in it most recently — under one grid that
/// answers the question no single card can: what the last year of work has
/// looked like across all of them (see `ActivitySection`).
///
/// It's a tab rather than a sheet or a sidebar section because that's the
/// only shape that keeps a repo one click away in both directions: the
/// Dashboard never covers a repo, and going back to one is the same gesture
/// as leaving it.
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    /// The tallest card's natural height, which every card and the open
    /// tile then adopt. Measured rather than declared: a card's height is
    /// the sum of a dozen text metrics that move with zoom and with the
    /// user's text-size setting, and a hardcoded number is wrong on the
    /// first system that disagrees with this Mac.
    @State private var cardHeight: CGFloat = 0

    private var dirtyCount: Int {
        appState.repos.filter { $0.card?.isClean == false }.count
    }

    var body: some View {
        if appState.repos.isEmpty {
            // Nothing to lay out, and the one action worth offering is
            // already the empty state's whole subject.
            EmptyStateView()
        } else {
            // The width the tiles lay out in has to come from a
            // GeometryReader wrapped AROUND the scroller, not from a probe on
            // it. A GeometryReader reports the size it was offered and never
            // grows to its content; a ScrollView in a VStack reports whichever
            // is wider, itself or the content inside it.
            //
            // Measuring the scroller latched, and the failure was ugly: the
            // tiles sized themselves from a width they had caused, so the row
            // stayed at its old size when the window narrowed and the whole
            // wall — tiles, headings, cards — hung off both edges.
            GeometryReader { geo in
                ScrollView {
                // Two sections with a heading each, and enough air between
                // them to read as two: charts about the whole year and cards
                // about this minute are different kinds of claim, and tiling
                // them 12pt apart made one long undifferentiated wall.
                    VStack(alignment: .leading, spacing: 22 * zoom) {
                        ActivitySection(width: geo.size.width - 32 * zoom)
                        VStack(alignment: .leading, spacing: 8 * zoom) {
                            SectionHeading(title: "Repositories", detail: repoSummary)
                            LazyVGrid(
                                columns: [GridItem(
                                    .adaptive(minimum: 300 * zoom, maximum: 460 * zoom),
                                    spacing: 12 * zoom
                                )],
                                spacing: 12 * zoom
                            ) {
                                ForEach(appState.repos) { repo in
                                    RepoCardView(repo: repo, height: cardHeight)
                                }
                                // Last slot, in the flow rather than in the
                                // corner: the wall's own "and one more" is
                                // where the eye already is when it runs out
                                // of cards.
                                OpenRepoTile(height: cardHeight)
                            }
                            // One height for the whole wall, not per row: a
                            // grid row sizes to its own tallest cell, so a
                            // tile that wrapped onto a row by itself took
                            // that row down to its own content height and
                            // read as a different kind of thing.
                            .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
                        }
                    }
                    .padding(16 * zoom)
                    // The scroller is as wide as the reader around it, so its
                    // content can't widen the window's idea of itself.
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
            // Sequential on purpose: a card is two subprocesses, and firing
            // nine repos' worth at once to fill one screen is a spike the
            // user pays for in every other git command running at the time.
            // They fill in from the top instead, which is also the order
            // they're read in.
            //
            // Cards before the heatmap: the cards are the answer to "what
            // was I doing", which is what the screen is opened for, and the
            // grid is a year of history that can afford to arrive second.
            .task {
                for repo in appState.repos { await repo.loadCard() }
                await appState.loadActivity()
                // Last, because it's the only network on this screen: a
                // slow forge must never hold up cards or the grid, and by
                // now the wall is settled — the badges just fill in.
                for repo in appState.repos { await repo.loadCardPullRequests() }
            }
        }
    }

    /// What the count line used to say from a pinned bar above the wall. It
    /// belongs to the wall, so it moved onto the wall's own heading — one
    /// place saying how big the wall is, not two.
    private var repoSummary: String {
        // How many repos there are, then how many are open — since a closed
        // tab now leaves its card here, "N open" on its own would be a count
        // of the wall claiming to be a count of the tab strip.
        var parts = ["\(appState.repos.count) repositor\(appState.repos.count == 1 ? "y" : "ies")"]
        let open = appState.openTabIDs.count
        if open > 0 { parts.append("\(open) open") }
        if dirtyCount > 0 { parts.append("\(dirtyCount) with changes") }
        return parts.joined(separator: " · ")
    }
}

/// A section label on the Dashboard: the name, and whatever count or
/// qualifier the section wants beside it. Both sections get one, so that
/// "Activity" reads as a heading rather than as a caption belonging to the
/// first tile under it.
struct SectionHeading: View {
    let title: String
    var detail: String?

    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 6 * zoom) {
            Text(title)
                .zoomFont(12, weight: .semibold)
            if let detail {
                Text("·").foregroundStyle(.quaternary)
                Text(detail)
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // Ranged with the tile text below it rather than with the tile edge:
        // a heading that lines up with a border and not with the words under
        // it reads as sitting slightly left of everything.
        .padding(.leading, 2 * zoom)
    }
}

/// The Dashboard's own toolbar. It exists partly because this screen has two
/// real actions and partly because an empty toolbar collapses its strip and
/// makes the window jump on every switch — see RootView.
struct DashboardToolbar: ToolbarContent {
    @EnvironmentObject var appState: AppState

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                appState.openRepoPanel()
            } label: {
                Label("Open", systemImage: "folder.badge.plus")
            }
            // ⌘O is owned by the tab bar's + button, which is mounted on
            // every screen — three views declaring the same shortcut is
            // ambiguous, and two of them firing opens two panels.
            .help("Open Repository (⌘O)")

            Button {
                appState.refreshDashboard()
            } label: {
                // Split into its two halves so the spin lands on the glyph
                // alone: the systemImage form would turn the word with it.
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .refreshSpin(appState.refreshingDashboard)
                }
            }
            .keyboardShortcut("r")
            .help("Re-read every repository (⌘R)")
        }
    }
}

/// How the activity tiles divide the width they're given. Every number in
/// points before zoom, including the width handed in.
///
/// Split out of the view because of the way this failed once: the tiles were
/// sized from a width they had themselves inflated, so the row came out wider
/// than the window it was laid out in, and the whole wall — tiles, headings,
/// cards — hung off both edges. None of that shows in a screenshot until the
/// window is dragged narrower, and all of it is arithmetic.
struct ActivityLayout {
    static let totalsWidth: CGFloat = 168
    static let repoWidth: CGFloat = 230
    static let gap: CGFloat = 12
    static let inset: CGFloat = 12
    /// A year, which is what a contribution grid means.
    static let weeks = 52
    /// The cell range: the sidebar's size at the bottom, and at the top the
    /// size past which the grid stops reading as a calendar of small marks
    /// and starts reading as a wall of tiles.
    static let minCell: CGFloat = 11
    static let maxCell: CGFloat = 14
    /// How much of the year the grid must still get for a row to be worth it.
    static let rowWeeks = 40

    /// How the three tiles are arranged.
    enum Mode {
        /// All three side by side.
        case row
        /// The two text tiles side by side, the grid full width under them.
        /// Three stacked tiles is a section 400pt tall, which at the window's
        /// own minimum height pushes the card wall off the bottom of the
        /// screen; two rows is 250 and the grid still gets all 52 columns.
        case split
        /// One above another, for a section too narrow even for the two text
        /// tiles — which happens at the larger UI zoom levels rather than at
        /// any window size.
        case stack
    }

    let mode: Mode
    var isRow: Bool { mode == .row }
    /// The grid tile's width.
    let heatmap: CGFloat
    /// The cell size that fills it, within `minCell...maxCell`.
    let cellSize: CGFloat
    /// What the tiles demand at minimum — the two fixed ones, the grid, and
    /// the gaps. Must never exceed the width handed in; the repo tile takes
    /// whatever is left over beyond this.
    let demand: CGFloat

    /// The widest the grid tile is worth making: a year of `maxCell` cells,
    /// plus the tile's own padding. Given more, it would only be growing its
    /// margins — which is what a maximised window looked like before, 600pt
    /// of empty card either side of the grid.
    static var heatmapIdeal: CGFloat {
        ActivityGraph.blockWidth(weeks: weeks, cellSize: maxCell) + 2 * inset
    }

    /// The narrowest row worth laying out.
    static var rowFloor: CGFloat {
        totalsWidth + repoWidth + 2 * gap
            + ActivityGraph.blockWidth(weeks: rowWeeks, cellSize: minCell) + 2 * inset
    }

    /// The narrowest pair of text tiles worth putting side by side.
    static var splitFloor: CGFloat { totalsWidth + repoWidth + gap }

    init(width: CGFloat) {
        if width >= Self.rowFloor {
            mode = .row
            // Bounded by what's actually left, never by the ideal alone —
            // this `min` is what keeps the row inside its window.
            heatmap = min(
                Self.heatmapIdeal,
                width - Self.totalsWidth - Self.repoWidth - 2 * Self.gap
            )
            demand = Self.totalsWidth + Self.repoWidth + 2 * Self.gap + heatmap
        } else {
            // Either way the grid is on a row of its own and gets the whole
            // width, which is how a narrow window still shows all 52 columns.
            mode = width >= Self.splitFloor ? .split : .stack
            heatmap = max(0, width)
            demand = heatmap
        }
        cellSize = min(Self.maxCell, max(
            Self.minCell,
            ActivityGraph.cellSize(fitting: Self.weeks, in: heatmap - 2 * Self.inset)
        ))
    }
}

/// The last year across every repository on the wall, under a heading of its own:
/// the total, the contribution grid, and which repos the grid is made of.
/// The cards below say where each repo is standing right now; this says what
/// the work across all of them has actually looked like, which is the one
/// question on this screen no single card can answer.
///
/// Three tiles rather than one panel. A single box had the grid — a 700pt
/// block that can't grow, because a year is 52 columns however wide the
/// window is — floating in the middle of a 1400pt card with air on both
/// sides. Tiles put facts in that air instead, and each one is free to be
/// the size its own content wants.
///
/// A row when the width is there and a column when it isn't, decided by
/// measurement rather than by a size class: what has to fit is a specific
/// number of points of grid, not "a wide window".
///
/// Its own view rather than a `@ViewBuilder` on DashboardView, so a repo's
/// year landing mid-load redraws these tiles and not the whole wall of cards.
struct ActivitySection: View {
    /// The width to lay the tiles out in. Handed down rather than measured
    /// here: the only width in this screen that content can't inflate is the
    /// scroller's, and that belongs to DashboardView — see the probe there.
    /// Zero until the first layout pass, which is the stacked case anyway.
    let width: CGFloat

    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { 10 * zoom }
    private var inset: CGFloat { ActivityLayout.inset * zoom }
    private var gap: CGFloat { ActivityLayout.gap * zoom }

    /// Every tile width and the grid's cell size, from the one width this
    /// view is sure of — see `ActivityLayout`.
    private var layout: ActivityLayout {
        ActivityLayout(width: zoom > 0 ? width / zoom : width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * zoom) {
            SectionHeading(title: "Activity", detail: "last 12 months")
            switch layout.mode {
            case .row:
                HStack(alignment: .top, spacing: gap) {
                    totalsTile.frame(width: ActivityLayout.totalsWidth * zoom)
                    heatmapTile.frame(width: layout.heatmap * zoom)
                    // Everything left over, rather than a width of its own:
                    // a stretched line still reads, and a 52-column grid
                    // can't use the space anyway.
                    repoTile.frame(
                        minWidth: ActivityLayout.repoWidth * zoom,
                        maxWidth: .infinity
                    )
                }
            case .split:
                VStack(spacing: gap) {
                    HStack(alignment: .top, spacing: gap) {
                        totalsTile.frame(width: ActivityLayout.totalsWidth * zoom)
                        repoTile.frame(maxWidth: .infinity)
                    }
                    heatmapTile
                }
            case .stack:
                // One under another, in the order they'd have been read
                // across: the grid is the subject, so it goes between the
                // number that sums it and the list that breaks it down.
                VStack(spacing: gap) {
                    totalsTile
                    heatmapTile
                    repoTile
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The year in numbers: the total at display size, and under it the facts
    /// that qualify it. Spread top to bottom rather than huddled at the top,
    /// because the tile is as tall as the grid beside it either way.
    @ViewBuilder
    private var totalsTile: some View {
        tile {
            VStack(alignment: .leading, spacing: 0) {
                headline
                Spacer(minLength: 8 * zoom)
                VStack(alignment: .leading, spacing: 2 * zoom) {
                    ForEach(footnotes, id: \.self) { line in
                        Text(line)
                            .zoomFont(11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        // A year of history is a subprocess per repo away, not missing. Say
        // so rather than claim a quiet year and correct it a moment later —
        // the same call the cards make while they're reading.
        if !appState.activityLoaded {
            Text("Reading…")
                .zoomFont(11)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(appState.activityStats.total.formatted())
                    // Tabular, so the number doesn't shuffle its own digits
                    // sideways as repos land one after another.
                    .zoomFont(26, weight: .semibold)
                    .monospacedDigit()
                Text(appState.activityStats.total == 1
                    ? "commit in the last year"
                    : "commits in the last year")
                    .zoomFont(10)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// What qualifies the total, and only what's true: a wall with no commits
    /// this year has nothing to add, and a line reading "0 active days" would
    /// be the total again in another font.
    private var footnotes: [String] {
        let stats = appState.activityStats
        guard appState.activityLoaded, stats.total > 0 else { return [] }
        var lines: [String] = []
        if stats.streak > 0 {
            lines.append("\(stats.streak)-day streak")
        }
        lines.append("\(stats.activeDays) active day\(stats.activeDays == 1 ? "" : "s")")
        if let busiest = stats.busiest {
            lines.append("Busiest \(busiest.count) · \(busiest.label)")
        }
        return lines
    }

    @ViewBuilder
    private var heatmapTile: some View {
        tile {
            ActivityGraph(
                counts: appState.activity,
                // A year, which is what a contribution grid means. A tile too
                // narrow for 52 columns drops its oldest ones, same as the
                // sidebar's grid does.
                maxWeeks: 52,
                detail: appState.activityDetail,
                // The total is in the tile to the left, so the row under the
                // grid belongs to the key alone.
                caption: "",
                showsLegend: true,
                // Spare width goes into bigger squares rather than into air:
                // a year is 52 columns at any window size, so growing the
                // cell is the only way for the grid to fill a wide tile.
                cellSize: layout.cellSize
            )
        }
    }

    /// Which repos the grid is made of, and when each of them was busy — the
    /// two things a summed grid can't say, since one cell can be five repos
    /// and the tooltips only ever name them a day at a time.
    ///
    /// A name, its year as a line, and its total. The line is what makes this
    /// the tile that takes the slack on a wide window: it reads at 100pt and
    /// at 800pt, where the grid beside it is 52 columns either way.
    @ViewBuilder
    private var repoTile: some View {
        tile {
            VStack(alignment: .leading, spacing: 2 * zoom) {
                Text("By repository")
                    .zoomFont(10, weight: .medium)
                    .foregroundStyle(.tertiary)
                if appState.activityRanking.isEmpty {
                    Text(appState.activityLoaded ? "Nothing this year" : "Reading…")
                        .zoomFont(11)
                        .foregroundStyle(.tertiary)
                } else {
                    let shown = appState.activityRanking.prefix(Self.repoRows)
                    ForEach(shown) { entry in
                        repoRow(entry)
                    }
                    // Never a silent cut: the tile holds six rows, and a
                    // seventh repo being missing is a fact about the tile.
                    let rest = appState.activityRanking.count - shown.count
                    if rest > 0 {
                        Text("+\(rest) more")
                            .zoomFont(10)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// As many rows as fit beside the grid at its own height.
    private static let repoRows = 6

    @ViewBuilder
    private func repoRow(_ entry: AppState.RepoActivity) -> some View {
        HStack(spacing: 8 * zoom) {
            Text(entry.name)
                .zoomFont(11)
                .lineLimit(1)
                .truncationMode(.middle)
                // Names in a column, so the lines beside them start on one
                // edge and can be read against each other.
                .frame(width: 96 * zoom, alignment: .leading)
            ActivitySparkline(
                values: entry.weeks,
                // The grid's own hue, a step in from its darkest, so the two
                // tiles read as one subject in two shapes.
                tint: ActivityGraph.ramp(scheme)[2]
            )
            .frame(minWidth: 24 * zoom)
            Text(entry.count.formatted())
                .zoomFont(11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40 * zoom, alignment: .trailing)
        }
        .frame(height: 17 * zoom)
        .help("\(entry.count.formatted()) commit\(entry.count == 1 ? "" : "s") in \(entry.name)")
    }

    /// One bento tile: the wall's own card treatment, and every tile as tall
    /// as the tallest in its row so the row reads as a row.
    @ViewBuilder
    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(inset)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// The wall's last slot: open another one. Dashed rather than filled — a
/// solid card here would read as a repository whose name failed to load.
struct OpenRepoTile: View {
    /// The wall's shared card height — see DashboardView.
    var height: CGFloat = 0
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    private var radius: CGFloat { 10 * zoom }

    var body: some View {
        Button {
            appState.openRepoPanel()
        } label: {
            VStack(spacing: 6 * zoom) {
                Image(systemName: "plus")
                    .zoomFont(18, weight: .light)
                Text("Open Repository…")
                    .zoomFont(11, weight: .medium)
            }
            .foregroundStyle(hovering ? Color.accentColor : .secondary)
            // The same height as a card, measured from the cards themselves,
            // so wrapping onto a row of its own changes nothing about it.
            // The floor is only for the first frame and for a window with no
            // cards to measure.
            .frame(maxWidth: .infinity, minHeight: max(height, 120 * zoom))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(hovering ? 0.22 : 0.13),
                        style: StrokeStyle(lineWidth: 1, dash: [4 * zoom, 3 * zoom])
                    )
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.rowPressEffect)
        .onHover { hovering = $0 }
        .help("Open another repository (⌘O)")
    }
}

/// One repository. The whole card is the button that opens its tab — a card
/// with a "Open" control in the corner spends a third of its width telling
/// you what clicking it does.
struct RepoCardView: View {
    @ObservedObject var repo: RepoState
    /// The wall's shared height. Zero on the first frame, before any card
    /// has been measured — the card falls back to its natural height, which
    /// is what the measurement will report anyway.
    var height: CGFloat = 0
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    /// Card radius, and the padding inside it. Nested corners are
    /// concentric: the branch capsule and the rail dots sit on a 12pt
    /// inset, so the card's own radius is theirs plus that inset.
    private var inset: CGFloat { 12 * zoom }
    private var radius: CGFloat { 10 * zoom }

    /// Whether this repo already has a tab. The card does the same thing
    /// either way — show me this repo — but what that means in words differs,
    /// and a menu offering "Close Tab" on a repo with no tab is a no-op with a
    /// name.
    private var isOpen: Bool { appState.openTabIDs.contains(repo.id) }

    var body: some View {
        Button {
            appState.openTab(repo)
        } label: {
            VStack(alignment: .leading, spacing: 8 * zoom) {
                title
                path
                status
                // Space, not a rule: the commit list is a different kind of
                // fact from the three lines above it, and the extra air says
                // so without drawing anything.
                if let card = repo.card {
                    rail(card).padding(.top, 2 * zoom)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            // Measured here, INSIDE the frame below: the probe has to report
            // the content's natural height, or a card pinned to the shared
            // height would report that height back as its own and the wall
            // could never shrink again when the tallest card closed.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
                }
            )
            // minHeight, not height: a card taller than whatever has been
            // measured so far still shows all of itself.
            .frame(minHeight: height, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            // A border here is structure, not fake elevation: these are
            // tiled cards on a plain background, and without an edge the
            // fill alone leaves them soft-focused against it.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.rowPressEffect)
        .onHover { hovering = $0 }
        .help(isOpen ? "Switch to \(repo.displayName)" : "Open \(repo.displayName)")
        .contextMenu {
            Button(isOpen ? "Switch to Tab" : "Open in a Tab") { appState.openTab(repo) }
            if isOpen {
                Button("Close Tab") { appState.closeTab(repo: repo) }
            }
            Divider()
            Button("Copy Repository Path") { RepoState.copyToPasteboard(repo.path) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Divider()
            // Not "Close": closing is what the tab's × does, and it now keeps
            // the repo on this wall. This is the one that forgets it — and it
            // touches nothing on disk, which the wording has to imply.
            Button("Remove from TheGit") { appState.remove(repo: repo) }
        }
    }

    @ViewBuilder
    private var title: some View {
        HStack(spacing: 6 * zoom) {
            Text(repo.displayName)
                .zoomFont(13, weight: .semibold)
                .lineLimit(1)
            branchPill
            Spacer(minLength: 0)
            idleBadge
            issueBadge
            pullRequestBadge
            tracking
        }
    }

    /// Open issues, in the closest thing SF Symbols has to GitHub's issue
    /// octicon — a dot in a circle. Same contract as the PR badge: shown
    /// only when known and non-zero, "100+" past the count query's cap.
    @ViewBuilder
    private var issueBadge: some View {
        if let count = repo.openIssueCount, count > 0 {
            let display = count >= ForgeClient.issueCountLimit
                ? "\(ForgeClient.issueCountLimit)+" : String(count)
            HStack(spacing: 3 * zoom) {
                Image(systemName: "smallcircle.filled.circle").zoomFont(9)
                Text(display)
            }
            .zoomFont(10, weight: .medium)
            .foregroundStyle(.green)
            .help("\(display) open issue\(count == 1 ? "" : "s")")
        }
    }

    /// A month or more of silence, said quietly: "zzz" and how long. The
    /// rail's own ages say this too, but only to someone already reading
    /// that card — this is for scanning the wall.
    @ViewBuilder
    private var idleBadge: some View {
        if let card = repo.card, card.isStale(), let last = card.commits.first?.date {
            HStack(spacing: 3 * zoom) {
                Image(systemName: "zzz").zoomFont(9)
                Text(AgeBreaks.compact(date: last))
            }
            .zoomFont(10, weight: .medium)
            .foregroundStyle(.tertiary)
            .help("No commits in over a month")
        }
    }

    /// Open PRs/MRs, in GitHub's own glyph and green. Only when the count
    /// is known and non-zero: a 0 would claim we checked the forge on a
    /// card that may never have reached it, and space here is scarce.
    @ViewBuilder
    private var pullRequestBadge: some View {
        if let forge = repo.forge, let count = repo.knownOpenPRCount, count > 0 {
            HStack(spacing: 3 * zoom) {
                PullRequestGlyph()
                    .frame(width: 10 * zoom, height: 10 * zoom)
                // String(), not interpolation into Text — see Forge.label.
                Text(String(count))
            }
            .zoomFont(10, weight: .medium)
            .foregroundStyle(.green)
            .help("\(count) open \(forge.itemNoun.lowercased())\(count == 1 ? "" : "s")")
        }
    }

    @ViewBuilder
    private var branchPill: some View {
        if let branch = repo.card?.branch {
            HStack(spacing: 3 * zoom) {
                Image(systemName: "arrow.triangle.branch").zoomFont(9)
                Text(branch).lineLimit(1)
            }
            .zoomFont(11, weight: .medium)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6 * zoom)
            .padding(.vertical, 1 * zoom)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        } else if let head = repo.card?.head {
            // Detached HEAD has no name but the sha, and saying so matters
            // more here than anywhere: a card is where you decide which
            // repo to walk into.
            Text("detached · \(head.prefix(7))")
                .zoomFont(11, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6 * zoom)
                .padding(.vertical, 1 * zoom)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }

    /// Ahead/behind the upstream, in the same arrows the toolbar's Pull and
    /// Push carry.
    @ViewBuilder
    private var tracking: some View {
        if let card = repo.card, card.ahead > 0 || card.behind > 0 {
            HStack(spacing: 5 * zoom) {
                if card.ahead > 0 {
                    Label("\(card.ahead)", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                if card.behind > 0 {
                    Label("\(card.behind)", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                }
            }
            .zoomFont(10, weight: .medium)
            .foregroundStyle(.secondary)
            .help("\(card.ahead) ahead, \(card.behind) behind the upstream")
        }
    }

    @ViewBuilder
    private var path: some View {
        Text((repo.path as NSString).abbreviatingWithTildeInPath)
            .zoomFont(10)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    @ViewBuilder
    private var status: some View {
        if let card = repo.card {
            HStack(spacing: 5 * zoom) {
                Image(systemName: card.conflicted > 0
                    ? "exclamationmark.triangle.fill"
                    : card.isClean ? "checkmark.circle" : "circle.dashed")
                    .zoomFont(10)
                Text(statusText(card))
                    .zoomFont(11)
                    .lineLimit(1)
            }
            .foregroundStyle(card.conflicted > 0 ? Color.orange : card.isClean ? .secondary : .primary)
        } else {
            // The card is two subprocesses away, not missing. Say nothing
            // rather than flash "clean" and correct itself a moment later.
            Text("Reading…")
                .zoomFont(11)
                .foregroundStyle(.tertiary)
        }
    }

    private func statusText(_ card: RepoState.Card) -> String {
        if card.conflicted > 0 {
            return "\(card.conflicted) conflicted file\(card.conflicted == 1 ? "" : "s")"
        }
        if card.changed == 0 { return "Working tree clean" }
        return "\(card.changed) changed file\(card.changed == 1 ? "" : "s")"
    }

    /// HEAD's last few commits on a single rail. Deliberately not the lane
    /// graph: a card shows one line of history, and lanes drawn for six
    /// commits out of context imply a branch structure that six commits
    /// can't actually show.
    @ViewBuilder
    private func rail(_ card: RepoState.Card) -> some View {
        let dirty = !card.isClean
        let rows = card.commits.prefix(dirty ? 4 : 5)
        if rows.isEmpty {
            Text("No commits yet")
                .zoomFont(11)
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 0) {
                if dirty {
                    RailRow(
                        isFirst: true,
                        isLast: false,
                        isOpen: true,
                        text: "Uncommitted changes",
                        age: "now",
                        emphasis: true
                    )
                }
                ForEach(Array(rows.enumerated()), id: \.element.hash) { index, commit in
                    RailRow(
                        isFirst: !dirty && index == 0,
                        isLast: index == rows.count - 1,
                        isOpen: false,
                        text: commit.subject,
                        age: AgeBreaks.compact(date: commit.date),
                        emphasis: !dirty && index == 0
                    )
                }
            }
        }
    }
}

/// The tallest natural card height on the wall. Max-reduced, so one card
/// with six rail rows sets the height for all of them and for the open tile.
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One line of the card's rail: the dot, the line through it, a subject and
/// an age. The line is drawn as two half-height segments so the first row
/// can start at its dot and the last can stop at its own — a rail that runs
/// past the newest commit implies rows that aren't there.
private struct RailRow: View {
    let isFirst: Bool
    let isLast: Bool
    /// Hollow, for the uncommitted-changes row — the same distinction the
    /// graph makes for its WIP node.
    let isOpen: Bool
    let text: String
    let age: String
    let emphasis: Bool

    @Environment(\.uiZoom) private var zoom

    private var dot: CGFloat { 6 * zoom }
    private var lineTint: Color { Color.primary.opacity(0.18) }

    var body: some View {
        HStack(spacing: 7 * zoom) {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isFirst ? Color.clear : lineTint)
                        .frame(width: 1)
                    Rectangle()
                        .fill(isLast ? Color.clear : lineTint)
                        .frame(width: 1)
                }
                Group {
                    if isOpen {
                        Circle()
                            .strokeBorder(Color.secondary, lineWidth: 1.5 * zoom)
                    } else {
                        Circle().fill(emphasis ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: dot, height: dot)
            }
            .frame(width: dot + 4 * zoom)
            Text(text)
                .zoomFont(11, weight: emphasis ? .medium : .regular)
                .foregroundStyle(emphasis ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6 * zoom)
            Text(age)
                .zoomFont(10)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        // Tall enough for the rail to read as a line with dots on it rather
        // than a stack of touching circles.
        .frame(height: 19 * zoom)
    }
}
