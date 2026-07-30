import AppKit
import SwiftUI

/// The window's home: every open repository on one wall of cards, each
/// answering the two questions a tab bar can't — is there uncommitted work
/// in there, and what happened in it most recently.
///
/// It's a tab rather than a sheet or a sidebar section because that's the
/// only shape that keeps a repo one click away in both directions: the
/// Launchpad never covers a repo, and going back to one is the same gesture
/// as leaving it.
struct LaunchpadView: View {
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
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
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
                        // Last slot, in the flow rather than in the corner:
                        // the wall's own "and one more" is where the eye
                        // already is when it runs out of cards.
                        OpenRepoTile(height: cardHeight)
                    }
                    .padding(16 * zoom)
                    // One height for the whole wall, not per row: a grid row
                    // sizes to its own tallest cell, so a tile that wrapped
                    // onto a row by itself took that row down to its own
                    // content height and read as a different kind of thing.
                    .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
                }
            }
            // Sequential on purpose: a card is two subprocesses, and firing
            // nine repos' worth at once to fill one screen is a spike the
            // user pays for in every other git command running at the time.
            // They fill in from the top instead, which is also the order
            // they're read in.
            .task {
                for repo in appState.repos { await repo.loadCard() }
            }
        }
    }

    /// Wayfinding only. No title — the tab that got you here is still on
    /// screen saying "Launchpad" — and no action: opening a repository lives
    /// in the toolbar and in the last tile of the wall, which is two places
    /// already.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text("\(appState.repos.count) \(appState.repos.count == 1 ? "repository" : "repositories")")
                .zoomFont(12, weight: .medium)
            if dirtyCount > 0 {
                Text("·").foregroundStyle(.quaternary)
                Text("\(dirtyCount) with changes")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16 * zoom)
        .frame(height: 34 * zoom)
    }
}

/// The Launchpad's own toolbar. It exists partly because this screen has two
/// real actions and partly because an empty toolbar collapses its strip and
/// makes the window jump on every switch — see RootView.
struct LaunchpadToolbar: ToolbarContent {
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
                appState.refreshLaunchpad()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Re-read every repository (⌘R)")
        }
    }
}

/// The wall's last slot: open another one. Dashed rather than filled — a
/// solid card here would read as a repository whose name failed to load.
struct OpenRepoTile: View {
    /// The wall's shared card height — see LaunchpadView.
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

    var body: some View {
        Button {
            appState.activeRepoID = repo.id
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
        .help("Open \(repo.displayName)")
        .contextMenu {
            Button("Open") { appState.activeRepoID = repo.id }
            Divider()
            Button("Copy Repository Path") { RepoState.copyToPasteboard(repo.path) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Divider()
            Button("Close") { appState.close(repo: repo) }
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
            tracking
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
