import AppKit
import SwiftUI

// GitKraken's merge editor, drawn over the graph like FileDiffView. The
// two sides up top — A the checked-out branch, B the incoming one — and
// the resulting file below, live as lines are taken. Semantics verified
// against GitKraken itself: output order is CLICK order (take B's block
// then A's and the result reads B then A), taken lines are tinted with
// their side's colour in the output, and an unresolved conflict shows
// nothing there — not a placeholder.
//
// Layout note: A and B are two columns of ONE scroll view, with each
// conflict block padded to the taller side. That is what keeps the two
// sides row-aligned and scrolling together — two ScrollViews with
// mirrored offsets fight each other; one can't.

private enum MergeTint {
    static let ours = Color.teal
    static let theirs = Color.yellow

    static func of(_ side: ConflictSide) -> Color {
        side == .ours ? ours : theirs
    }
}

/// One "scroll to conflict n" command, generation-stamped so pressing
/// the same arrow twice still re-fires the onChange.
private struct MergeScroll: Equatable {
    var conflict: Int
    var generation: Int
}

struct MergeEditorView: View {
    @ObservedObject var repo: RepoState
    @ObservedObject var session: MergeEditorSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiZoom) private var zoom
    @State private var scroll: MergeScroll?
    @State private var current = 0
    @State private var sourceScrollX: CGFloat = 0

    private var conflictCount: Int { session.document.conflicts.count }

    /// The marker labels, made human: HEAD is spelled as the branch the
    /// user is standing on whenever we know it.
    private var oursLabel: String {
        let label = session.document.conflicts.first?.oursLabel ?? ""
        if label.isEmpty || label == "HEAD" {
            return repo.snapshot.currentBranch ?? "HEAD"
        }
        return label
    }

    private var theirsLabel: String {
        let label = session.document.conflicts.first?.theirsLabel ?? ""
        return label.isEmpty ? "incoming" : label
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                sides
                    .frame(minHeight: 120, idealHeight: 340)
                MergeOutputPane(repo: repo, session: session, scroll: scroll)
                    .frame(minHeight: 100)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerContent(compact: false)
            headerContent(compact: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func headerContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 8) {
            if !compact {
                Image(systemName: "exclamationmark.triangle.fill")
                    .zoomFont(12)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 0) {
                if !compact, !session.file.directory.isEmpty {
                    Text(session.file.directory).foregroundStyle(.secondary)
                }
                Text(session.file.fileName).fontWeight(.semibold)
            }
            .zoomFont(12)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(minWidth: compact ? 48 : 96, alignment: .leading)
            .layoutPriority(1)
            .accessibilityLabel(session.file.path)

            Text(compact
                ? "\(session.resolvedCount)/\(conflictCount) resolved"
                : "\(session.resolvedCount) of \(conflictCount) resolved")
                .zoomFont(11)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(session.allResolved
                    ? AnyShapeStyle(.green)
                    : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.2),
                    value: session.resolvedCount
                )

            Spacer(minLength: compact ? 2 : 8)

            HStack(spacing: 2) {
                Text(compact
                    ? "\(min(current + 1, conflictCount))/\(conflictCount)"
                    : "Conflict \(min(current + 1, conflictCount)) of \(conflictCount)")
                    .zoomFont(11)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Conflict \(min(current + 1, conflictCount)) of \(conflictCount)"
                    )
                stepButton("chevron.up", label: "Previous conflict") {
                    jump(to: (current - 1 + conflictCount) % conflictCount)
                }
                stepButton("chevron.down", label: "Next conflict") {
                    jump(to: (current + 1) % conflictCount)
                }
            }
            .disabled(session.isEditing || session.isSaving)

            Button {
                repo.saveMergeResolution()
            } label: {
                HStack(spacing: 5) {
                    if session.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save")
                }
                .frame(minWidth: 42)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!session.canSave || session.isSaving)
            .accessibilityLabel(session.isSaving ? "Saving resolution" : "Save resolution")
            .help(saveHelp)

            Button {
                if session.isEditing {
                    repo.cancelMergeHandEdit()
                } else {
                    repo.closeMergeEditor()
                }
            } label: {
                Image(systemName: "xmark")
                    .zoomFont(10, weight: .bold)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(session.isSaving)
            .accessibilityLabel(session.isEditing ? "Cancel hand editing" : "Close merge editor")
            .help(session.isEditing ? "Cancel hand editing (esc)" : "Close merge editor (esc)")
        }
    }

    private var saveHelp: String {
        if session.isSaving {
            return "Saving and marking the file resolved"
        }
        if session.draftHasMarkers {
            return "Review the remaining conflict markers before saving"
        }
        if session.canSave {
            return "Write the result and mark the file resolved (⌘S)"
        }
        return "Resolve every conflict first by taking lines from A or B"
    }

    private var sides: some View {
        GeometryReader { geometry in
            let paneWidth = geometry.size.width / 2
            let textViewport = max(1, paneWidth - 86)
            let maxScroll = max(0, sourceTextWidth - textViewport)
            let sourceOffset = min(sourceScrollX, maxScroll)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SideHeader(
                        session: session, side: .ours,
                        badge: "A", label: oursLabel,
                        sideDescription: repo.conflictSideDescription(.ours)
                    )
                    .frame(width: paneWidth)
                    Divider()
                    SideHeader(
                        session: session, side: .theirs,
                        badge: "B", label: theirsLabel,
                        sideDescription: repo.conflictSideDescription(.theirs)
                    )
                    .frame(width: paneWidth)
                }
                .frame(height: 28)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(session.alignedRows) { row in
                                AlignedRowView(
                                    session: session,
                                    row: row,
                                    paneWidth: paneWidth,
                                    textOffset: sourceOffset
                                )
                                .id(row.opensConflict && row.conflict != nil
                                    ? "c\(row.conflict!)" : "r\(row.id)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: scroll) { _, request in
                        guard let request else { return }
                        if reduceMotion {
                            proxy.scrollTo("c\(request.conflict)", anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("c\(request.conflict)", anchor: .center)
                            }
                        }
                    }
                }
                if maxScroll > 0 {
                    MergeHorizontalScroller(
                        offset: $sourceScrollX,
                        maxOffset: maxScroll,
                        visibleFraction: min(1, textViewport / sourceTextWidth)
                    )
                    .frame(height: 12)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Source code horizontal position")
                }
            }
            .overlay {
                if maxScroll > 0 {
                    HorizontalScrollCatcher { delta in
                        sourceScrollX = min(max(sourceScrollX - delta, 0), maxScroll)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: maxScroll) { _, newMaximum in
                if sourceScrollX > newMaximum {
                    sourceScrollX = newMaximum
                }
            }
        }
    }

    private var sourceTextWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11 * zoom, weight: .regular)
        return session.alignedRows.reduce(CGFloat.zero) { width, row in
            let left = row.left.map { Self.width(of: $0.text, font: font) } ?? 0
            let right = row.right.map { Self.width(of: $0.text, font: font) } ?? 0
            return max(width, left, right)
        }
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    private func stepButton(
        _ glyph: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .zoomFont(10, weight: .semibold)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }

    private func jump(to index: Int) {
        current = index
        scroll = MergeScroll(conflict: index, generation: (scroll?.generation ?? 0) + 1)
    }
}

/// Checked / mixed / unchecked, one glyph — SwiftUI's Toggle has no
/// mixed state, and mixed is exactly what "some lines taken" looks like.
private struct TriStateCheckbox: View {
    let state: MergeEditorSession.SideState
    let tint: Color
    let label: String
    let help: String
    let action: () -> Void
    @FocusState private var focused: Bool

    private var accessibilityValue: String {
        switch state {
        case .none: return "Not selected"
        case .some: return "Partially selected"
        case .all: return "Selected"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill"
                : state == .some ? "minus.square.fill" : "square")
                .zoomFont(12)
                .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(1)
                        .opacity(focused ? 1 : 0)
                }
        }
        .buttonStyle(.pressEffect)
        .focused($focused)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .help(help)
    }
}

private struct SideHeader: View {
    @ObservedObject var session: MergeEditorSession
    let side: ConflictSide
    let badge: String
    let label: String
    let sideDescription: String

    var body: some View {
        let tint = MergeTint.of(side)
        let selected = session.wholeSideState(side) == .all
        HStack(spacing: 6) {
            TriStateCheckbox(
                state: session.wholeSideState(side),
                tint: tint,
                label: selected
                    ? "Remove all \(badge) selections"
                    : "Take all conflicts from \(badge)",
                help: selected
                    ? "Remove every selection from \(badge)"
                    : "Take every conflict from \(badge)"
            ) {
                session.setWholeSide(side, on: session.wholeSideState(side) != .all)
            }
            .disabled(session.isEditing || session.isSaving)
            Text(badge)
                .zoomFont(10, weight: .bold)
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1.5))
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(label)
                        .zoomFont(11, weight: .semibold, design: .monospaced)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(sideDescription)
                        .zoomFont(10)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(label)
                    .zoomFont(11, weight: .semibold, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.08))
    }
}

/// One aligned row: A's cell | divider | B's cell.
private struct AlignedRowView: View {
    @ObservedObject var session: MergeEditorSession
    let row: MergeAlignedRow
    let paneWidth: CGFloat
    let textOffset: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            SideCell(
                session: session, row: row, side: .ours,
                cell: row.left, textOffset: textOffset
            )
                .frame(width: paneWidth)
            Divider()
            SideCell(
                session: session, row: row, side: .theirs,
                cell: row.right, textOffset: textOffset
            )
                .frame(width: paneWidth)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One side's half of a row: [block checkbox][number][take][text].
/// A nil cell is the filler where the other side's block is longer —
/// it keeps the checkbox slot so an empty side is still decidable.
private struct SideCell: View {
    @ObservedObject var session: MergeEditorSession
    let row: MergeAlignedRow
    let side: ConflictSide
    let cell: MergeCell?
    let textOffset: CGFloat
    @State private var hovered = false
    @FocusState private var takeFocused: Bool

    private var tint: Color { MergeTint.of(side) }
    private var picked: Bool { cell?.ref.map(session.isPicked) ?? false }
    private var badge: String { side == .ours ? "A" : "B" }

    private var background: Color {
        guard row.conflict != nil else { return .clear }
        // Filler cells: faintly claimed by the block, clearly not a line.
        guard cell != nil else { return tint.opacity(0.04) }
        return tint.opacity(picked ? 0.22 : 0.09)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Block checkbox on the block's first row, GitKraken's
            // left-margin placement.
            if let conflict = row.conflict, row.opensConflict {
                let selected = session.sideState(conflict, side: side) == .all
                TriStateCheckbox(
                    state: session.sideState(conflict, side: side),
                    tint: tint,
                    label: selected
                        ? "Remove conflict \(conflict + 1) from \(badge)"
                        : "Take conflict \(conflict + 1) from \(badge)",
                    help: selected
                        ? "Remove this \(badge) block"
                        : "Take this \(badge) block"
                ) {
                    session.setSide(conflict, side: side,
                                    on: session.sideState(conflict, side: side) != .all)
                }
                .disabled(session.isEditing || session.isSaving)
            } else {
                Spacer().frame(width: 24)
            }

            Text(cell.map { String($0.number) } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)

            // The take button: ✓ once taken, ⊕ under the pointer —
            // GitKraken reveals it on hover, and a column of permanent
            // plus signs is exactly the noise it avoids.
            if let ref = cell?.ref {
                Button {
                    session.toggleLine(ref)
                } label: {
                    Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                        .zoomFont(11)
                        .foregroundStyle(picked ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .opacity(picked || hovered || takeFocused ? 1 : 0)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .padding(1)
                                .opacity(takeFocused ? 1 : 0)
                        }
                }
                .buttonStyle(.pressEffect)
                .focused($takeFocused)
                .disabled(session.isEditing || session.isSaving)
                .accessibilityLabel(
                    picked
                        ? "Remove line \(cell?.number ?? 0) from \(badge)"
                        : "Take line \(cell?.number ?? 0) from \(badge)"
                )
                .help(picked ? "Remove this line from the output" : "Take this line")
            } else {
                Spacer().frame(width: 24)
            }

            // A filler still renders a space: an empty Text measures
            // zero-high, the cell collapses, and its background became
            // a stripe floating mid-row — the banding this replaces.
            GeometryReader { _ in
                Text(cell?.text ?? " ")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -textOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }
        .zoomFont(11, design: .monospaced)
        // Fill the whole row, not just this cell's content height —
        // the background must reach the row's edges or every filler
        // row shows a gap above and below (the "断层" banding).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        // GitKraken's block edge: one continuous bar down the block's
        // left flank, dimmed where this side has no line. It is what
        // makes a block with fillers still read as ONE region.
        .overlay(alignment: .leading) {
            if row.conflict != nil {
                Rectangle()
                    .fill(tint.opacity(cell == nil ? 0.25 : 0.8))
                    .frame(width: 2)
            }
        }
        .textSelection(.enabled)
        .onHover { hovered = $0 }
    }
}

/// A native scrollbar for the source text columns. A and B share the same
/// offset so matching lines move together while their gutters and divider
/// stay fixed.
private struct MergeHorizontalScroller: View {
    @Binding var offset: CGFloat
    let maxOffset: CGFloat
    let visibleFraction: CGFloat
    @State private var dragAnchor: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbWidth = max(32, trackWidth * visibleFraction)
            let travel = max(1, trackWidth - thumbWidth)
            let thumbX = maxOffset > 0 ? (offset / maxOffset) * travel : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.65))
                    .frame(width: thumbWidth, height: 8)
                    .offset(x: thumbX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragAnchor == nil {
                            if value.startLocation.x >= thumbX,
                               value.startLocation.x <= thumbX + thumbWidth {
                                dragAnchor = value.startLocation.x - thumbX
                            } else {
                                dragAnchor = thumbWidth / 2
                            }
                        }
                        let nextX = min(
                            max(value.location.x - (dragAnchor ?? thumbWidth / 2), 0),
                            travel
                        )
                        offset = (nextX / travel) * maxOffset
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source code horizontal position")
        .accessibilityValue(
            maxOffset > 0 ? "\(Int((offset / maxOffset) * 100)) percent" : "Start"
        )
        .accessibilityAdjustableAction { direction in
            let step = max(36, maxOffset * 0.1)
            switch direction {
            case .increment:
                offset = min(offset + step, maxOffset)
            case .decrement:
                offset = max(offset - step, 0)
            @unknown default:
                break
            }
        }
    }
}

/// The bottom pane: the file Save will write, recomputed on every take.
private struct MergeOutputPane: View {
    @ObservedObject var repo: RepoState
    @ObservedObject var session: MergeEditorSession
    let scroll: MergeScroll?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                outputHeader(compact: false)
                outputHeader(compact: true)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider()
            if session.isEditing {
                draftEditor
            } else {
                outputList
            }
        }
    }

    private func outputHeader(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Output")
                .zoomFont(11, weight: .semibold)
                .fixedSize(horizontal: true, vertical: false)
            if !compact {
                Text(outputDescription)
                    .zoomFont(10)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(session.draftHasMarkers ? .orange : .secondary)
            } else if session.draftHasMarkers {
                Image(systemName: "exclamationmark.triangle.fill")
                    .zoomFont(10)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Conflict markers remain")
            }
            Spacer(minLength: 4)
            if session.isEditing {
                if compact {
                    compactOutputButton(
                        "xmark",
                        label: "Cancel hand editing",
                        help: "Discard the hand edit and go back to picking"
                    ) {
                        repo.cancelMergeHandEdit()
                    }
                } else {
                    Button("Cancel Edit") { repo.cancelMergeHandEdit() }
                        .controlSize(.small)
                        .disabled(session.isSaving)
                        .help("Discard the hand edit and go back to picking (esc)")
                }
            } else {
                if compact {
                    compactOutputButton(
                        "pencil",
                        label: "Edit output",
                        help: "Edit the output text directly"
                    ) {
                        session.beginEditing()
                    }
                    if session.anyTouched {
                        compactOutputButton(
                            "arrow.counterclockwise",
                            label: "Reset selections",
                            help: "Untake everything and start over"
                        ) {
                            session.reset()
                        }
                    }
                } else {
                    Button("Edit") { session.beginEditing() }
                        .controlSize(.small)
                        .disabled(session.isSaving)
                        .help("Edit the output text directly — untouched conflicts keep their markers to resolve in place")
                    if session.anyTouched {
                        Button("Reset") { session.reset() }
                            .controlSize(.small)
                            .disabled(session.isSaving)
                            .help("Untake everything and start over")
                    }
                }
            }
        }
    }

    private func compactOutputButton(
        _ glyph: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .zoomFont(10, weight: .semibold)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
        .disabled(session.isSaving)
        .accessibilityLabel(label)
        .help(help)
    }

    private var outputDescription: String {
        if session.isEditing {
            if session.draftHasMarkers {
                return "conflict markers remain in the hand-edited text"
            }
            return "editing by hand; Save writes exactly this text"
        }
        return "what Save writes to \(session.file.fileName)"
    }

    private var draftEditor: some View {
        MergeDraftTextView(
            text: Binding(
                get: { session.draft ?? "" },
                set: { session.draft = $0 }
            ),
            fontSize: 11 * zoom
        )
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var outputList: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width, outputTextWidth + 82)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.outputLines) { line in
                            OutputLineRow(line: line, rowWidth: contentWidth)
                                .id(line.opensConflict && line.conflict != nil
                                    ? "c\(line.conflict!)" : "r\(line.id)")
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: scroll) { _, request in
                    guard let request else { return }
                    if reduceMotion {
                        proxy.scrollTo("c\(request.conflict)", anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("c\(request.conflict)", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var outputTextWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11 * zoom, weight: .regular)
        return session.outputLines.reduce(CGFloat.zero) { width, line in
            max(width, (line.text as NSString).size(withAttributes: [.font: font]).width)
        }
        .rounded(.up)
    }
}

private struct OutputLineRow: View {
    let line: MergeEditorSession.OutputLine
    let rowWidth: CGFloat

    var body: some View {
        if line.number == nil {
            // An unresolved (or emptied) conflict adds no text to the
            // file — GitKraken shows nothing at all. The hairline keeps
            // a navigation anchor and, while unresolved, a trace of the
            // decision still owed.
            Rectangle()
                .fill(line.kind == .unresolved ? Color.orange.opacity(0.55) : Color.clear)
                .frame(height: 2)
                .frame(width: rowWidth)
                .padding(.vertical, 1)
        } else {
            HStack(spacing: 0) {
                // GitKraken stamps each taken run with its origin letter.
                Text(line.side == .ours ? "A" : line.side == .theirs ? "B" : "")
                    .zoomFont(9, weight: .bold)
                    .foregroundStyle(line.side.map { MergeTint.of($0) } ?? .clear)
                    .frame(width: 20)
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityHidden(true)
                Spacer().frame(width: 24)
                Text(line.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .zoomFont(11, design: .monospaced)
            .frame(width: rowWidth, alignment: .leading)
            .background(line.side.map { MergeTint.of($0).opacity(0.13) } ?? .clear)
            // Same block-edge bar as the panes above — the taken run
            // reads as a region, and its colour says where it came from.
            .overlay(alignment: .leading) {
                if let side = line.side {
                    Rectangle()
                        .fill(MergeTint.of(side).opacity(0.8))
                        .frame(width: 2)
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// NSTextView gives the hand editor the code-editor behavior SwiftUI's
/// TextEditor does not expose: no wrapping plus native horizontal and
/// vertical scrolling, undo, selection, and the system find panel.
private struct MergeDraftTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MergeDraftTextView

        init(parent: MergeDraftTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.textContainer?.lineFragmentPadding = 0

        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.setAccessibilityLabel("Merge resolution editor")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        scrollView.backgroundColor = .textBackgroundColor
    }
}
