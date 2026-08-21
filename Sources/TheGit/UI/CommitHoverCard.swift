import SwiftUI

/// Show/hide logic for the graph's commit hover card.
///
/// Only `shown` publishes. Pointer traffic — entering and leaving rows on
/// the way to somewhere else — is absorbed here as timers, so sweeping
/// forty rows to reach the scrollbar costs forty cancelled tasks, not
/// forty graph layouts. The timings are the usual hover-card ones: a
/// pause before the first card so a passing pointer raises nothing, a
/// shorter one to move the card to a neighbouring row once one is up,
/// and a grace on leaving long enough to cross the gap into the card.
@MainActor
final class CommitHoverController: ObservableObject {
    @Published private(set) var shown: GraphRow?

    /// Longer than a tooltip's: the card is a paragraph to read, not a
    /// label, so a pointer merely passing along the rows shouldn't raise it.
    static let showDelay: Duration = .milliseconds(700)
    static let switchDelay: Duration = .milliseconds(160)
    static let hideGrace: Duration = .milliseconds(220)
    /// How far into the show delay the fetch starts: early enough that the
    /// card usually opens complete, late enough that a pointer merely
    /// crossing the row spawns no git process.
    static let prefetchDelay: Duration = .milliseconds(120)

    /// Where the card's corner goes: the pointer, as of the moment the
    /// card opened. Frozen at open so the card doesn't chase the cursor.
    private(set) var shownPoint: CGPoint = .zero

    private var pending: Task<Void, Never>?
    /// The pointer is on the card itself; rows under it don't count.
    private var overCard = false
    /// The live pointer, in the graph pane's space. Not published:
    /// every move would re-lay-out the graph.
    private var pointer: CGPoint = .zero

    /// The pointer moved over a row. Cheap by design — a plain store.
    func pointerMoved(to point: CGPoint) {
        pointer = point
    }

    func rowEntered(_ row: GraphRow, in repo: RepoState) {
        guard !overCard else { return }
        pending?.cancel()
        guard shown?.id != row.id else { return }
        let delay = shown == nil ? Self.showDelay : Self.switchDelay
        let hash = row.commit.hash
        pending = Task { [weak self] in
            let lead = min(delay, Self.prefetchDelay)
            try? await Task.sleep(for: lead)
            guard !Task.isCancelled else { return }
            Task { _ = await repo.hoverDetails(for: hash) }
            try? await Task.sleep(for: delay - lead)
            guard !Task.isCancelled, let self else { return }
            self.shownPoint = self.pointer
            self.shown = row
        }
    }

    func rowLeft(_ row: GraphRow) {
        guard !overCard else { return }
        pending?.cancel()
        pending = nil
        guard shown != nil else { return }
        scheduleHide()
    }

    func cardHovered(_ inside: Bool) {
        overCard = inside
        pending?.cancel()
        pending = nil
        if !inside { scheduleHide() }
    }

    /// Instant, for a click, a scroll, or a drag — anything that means the
    /// pointer is no longer reading.
    func dismiss() {
        pending?.cancel()
        pending = nil
        overCard = false
        if shown != nil { shown = nil }
    }

    private func scheduleHide() {
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.hideGrace)
            guard !Task.isCancelled, let self, !self.overCard else { return }
            self.shown = nil
        }
    }
}

/// Where the card goes relative to the pointer, in the graph pane's space.
///
/// Down and to the right of the cursor, the way a pointer-anchored panel
/// goes — so the card lands on what the pointer has already passed rather
/// than over the rows being read. It flips above or slides left when that
/// corner has no room. Pure, so the corner cases — a pointer at the
/// bottom of the pane, a narrow pane — are testable without a window.
struct CommitHoverPlacement: Equatable {
    /// Leading edge, from the pane's leading edge.
    let x: CGFloat
    let width: CGFloat
    let below: Bool
    /// How far in from the pane edge the card hangs: top edge → card top
    /// when below, bottom edge → card bottom when above.
    let inset: CGFloat
    /// The most height the chosen side offers.
    let maxHeight: CGFloat

    static let margin: CGFloat = 8
    static let baseWidth: CGFloat = 400
    /// Clear of the cursor itself, close enough to read as hanging off it.
    static let pointerInset = CGPoint(x: 14, y: 16)
    /// What a card with a body and a handful of files comes to at zoom 1 —
    /// the threshold under which the side with more room wins.
    static let typicalHeight: CGFloat = 360

    init(pointer: CGPoint, pane: CGSize, zoom: CGFloat) {
        width = max(0, min(Self.baseWidth * zoom, pane.width - Self.margin * 2))
        x = max(
            Self.margin,
            min(pointer.x + Self.pointerInset.x, pane.width - width - Self.margin)
        )
        let top = pointer.y + Self.pointerInset.y
        let bottom = pointer.y - Self.pointerInset.y
        let roomBelow = pane.height - top - Self.margin
        let roomAbove = bottom - Self.margin
        below = roomBelow >= Self.typicalHeight * zoom || roomBelow >= roomAbove
        inset = below ? top : pane.height - bottom
        maxHeight = max(0, below ? roomBelow : roomAbove)
    }
}

/// The card: who, when, the whole message, where the commit sits, and
/// what it touched. What the right-hand panel shows on a click, raised on
/// a pause instead — for reading, not for acting, so the only controls
/// are Copy and the file rows, which hand over to the diff.
struct CommitHoverCard: View {
    @ObservedObject var repo: RepoState
    let row: GraphRow
    let width: CGFloat
    let maxHeight: CGFloat
    /// Hides the card — a file click hands over to the diff.
    let dismiss: () -> Void
    @ObservedObject private var avatars = AvatarStore.shared
    @Environment(\.uiZoom) private var zoom
    @State private var details: CommitHoverDetails?

    private static let maxFiles = 8
    private static let maxBodyLines = 10
    private static let maxBadges = 4

    init(
        repo: RepoState, row: GraphRow, width: CGFloat, maxHeight: CGFloat,
        dismiss: @escaping () -> Void
    ) {
        _repo = ObservedObject(wrappedValue: repo)
        self.row = row
        self.width = width
        self.maxHeight = maxHeight
        self.dismiss = dismiss
        // Already-fetched details open with the card, so the usual case is
        // one complete frame rather than a card that grows a moment later.
        _details = State(initialValue: repo.cachedHoverDetails(for: row.commit.hash))
    }

    var body: some View {
        let commit = row.commit
        let color = LaneCanvas.color(row.columnColor)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                avatar(commit, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.author)
                        .zoomFont(12, weight: .semibold)
                        .lineLimit(1)
                    if !commit.email.isEmpty {
                        Text(commit.email)
                            .zoomFont(10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(commit.date.formatted(.relative(presentation: .named)))
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .zoomFont(10)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject)
                    .zoomFont(12, weight: .semibold)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let body = details?.body, !body.isEmpty {
                    Text(body)
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                        .lineLimit(Self.maxBodyLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                    Button {
                        RepoState.copyToPasteboard(commit.hash)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .zoomFont(9)
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(.secondary)
                    .help("Copy full sha")
                    if !commit.parents.isEmpty {
                        Text(commit.parents.count == 1 ? "parent" : "parents")
                            .zoomFont(10)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                        Text(commit.parents.map { String($0.prefix(7)) }.joined(separator: " "))
                            .zoomFont(11, design: .monospaced)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                refs(commit)
            }
            .padding(12)

            if let details {
                Divider()
                files(details)
            }
        }
        .frame(width: width, alignment: .leading)
        // Not `.frame(maxHeight:)`: a flexible frame takes everything it is
        // offered up to its cap, and the card ran to the bottom of the pane.
        // This takes the content's height, and only cuts it off at the cap.
        .modifier(CapHeight(at: maxHeight))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Same chrome as the error toast: a floating layer over the graph,
        // so material and a shadow, and a hairline because the rows under
        // it are busy enough to lose a soft edge against.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .task(id: commit.hash) {
            if details == nil {
                details = await repo.hoverDetails(for: commit.hash)
            }
        }
    }

    /// The graph node, larger: branch-colored ring, the author's picture
    /// inside it when there is one, their initials otherwise.
    private func avatar(_ commit: Commit, color: Color) -> some View {
        let size = 28 * zoom
        return ZStack {
            Circle().fill(color.opacity(0.22))
            if avatars.isEnabled,
               let image = avatars.avatar(
                   for: commit.email, name: commit.author, forge: repo.avatarForge
               ) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(LaneCanvas.initials(commit.author))
                    .zoomFont(10, weight: .bold)
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(color, lineWidth: 1.5 * zoom))
    }

    /// The commit's refs as the graph draws them, a handful at most.
    @ViewBuilder
    private func refs(_ commit: Commit) -> some View {
        let infos = RefBadge.infos(for: commit.refs, remotes: Set(repo.snapshot.remoteNames))
        if !infos.isEmpty {
            HStack(spacing: 4) {
                ForEach(infos.prefix(Self.maxBadges)) { info in
                    RefBadge(info: info)
                        .frame(maxWidth: 140 * zoom, alignment: .leading)
                }
                if infos.count > Self.maxBadges {
                    Text("+\(infos.count - Self.maxBadges)")
                        .zoomFont(10, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func files(_ details: CommitHoverDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(details.files.count) file\(details.files.count == 1 ? "" : "s") changed")
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                if details.additions > 0 {
                    Text("+\(details.additions)")
                        .zoomFont(11, weight: .medium, design: .monospaced)
                        .foregroundStyle(.green)
                }
                if details.deletions > 0 {
                    Text("−\(details.deletions)")
                        .zoomFont(11, weight: .medium, design: .monospaced)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(details.files.prefix(Self.maxFiles)) { file in
                HoverCardFileRow(file: file) { open(file) }
                    .padding(.horizontal, 6)
            }
            if details.files.count > Self.maxFiles {
                Text("and \(details.files.count - Self.maxFiles) more")
                    .zoomFont(10)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }

    /// A file row click is the one thing on the card that acts: it does
    /// what selecting the commit and then the file would, so the card can
    /// close and the diff take over.
    private func open(_ file: ReviewFile) {
        dismiss()
        repo.selectedCommit = row.commit.hash
        repo.selectCommitFile(FileChange(
            path: file.path, status: file.status, area: .unstaged, oldPath: file.oldPath
        ))
    }
}

/// Content-sized, with a ceiling. A flexible frame fills what it is offered
/// up to its max; this one reports the child's own height unless that is
/// more than the cap, when the child is proposed the cap and whatever it
/// can't fit is left for the caller's clip.
struct CapHeight: ViewModifier {
    let cap: CGFloat

    init(at cap: CGFloat) { self.cap = cap }

    func body(content: Content) -> some View {
        CappedHeightLayout(cap: cap) { content }
    }
}

struct CappedHeightLayout: Layout {
    let cap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(natural.height, max(0, cap)))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// One file on the card: the detail panel's row, plus its line counts.
struct HoverCardFileRow: View {
    let file: ReviewFile
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 6) {
            Text(String(file.status))
                .zoomFont(10, weight: .bold, design: .monospaced)
                .foregroundStyle(CommitFileRow.color(for: file.status))
                .frame(width: 14)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory).foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .zoomFont(11)
            .lineLimit(1)
            .truncationMode(.head)

            Spacer(minLength: 8)

            if file.isBinary {
                Text("binary")
                    .zoomFont(10)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    if file.additions > 0 {
                        Text("+\(file.additions)").foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("−\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .zoomFont(10, design: .monospaced)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20 * zoom)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { select() }
        .help(file.path)
    }
}
