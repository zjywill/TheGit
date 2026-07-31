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
    @State private var scroll: MergeScroll?
    @State private var current = 0

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
                    // Frozen while a hand edit is in flight: a checkbox
                    // click would have to regenerate the output and eat
                    // the edits. Dimmed so the freeze is visible, not
                    // a mystery.
                    .disabled(session.isEditing)
                    .opacity(session.isEditing ? 0.55 : 1)
                    .frame(minHeight: 120, idealHeight: 340)
                MergeOutputPane(session: session, scroll: scroll)
                    .frame(minHeight: 100)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomFont(12)
                .foregroundStyle(.orange)

            HStack(spacing: 0) {
                if !session.file.directory.isEmpty {
                    Text(session.file.directory).foregroundStyle(.secondary)
                }
                Text(session.file.fileName).fontWeight(.semibold)
            }
            .zoomFont(12)
            .lineLimit(1)
            .truncationMode(.head)

            Text("\(session.resolvedCount) of \(conflictCount) resolved")
                .zoomFont(11)
                .foregroundStyle(session.allResolved ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: session.resolvedCount)

            Spacer()

            HStack(spacing: 2) {
                Text("Conflict \(min(current + 1, conflictCount)) of \(conflictCount)")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                stepButton("chevron.up", help: "Previous conflict") {
                    jump(to: (current - 1 + conflictCount) % conflictCount)
                }
                stepButton("chevron.down", help: "Next conflict") {
                    jump(to: (current + 1) % conflictCount)
                }
            }
            .disabled(session.isEditing)

            Button("Save") { repo.saveMergeResolution() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!session.canSave)
                .help(session.canSave
                    ? "Write the result and mark the file resolved (⌘S)"
                    : session.isEditing
                        ? "Conflict markers are still in the text — resolve them first"
                        : "Resolve every conflict first — take lines from A or B")

            Button {
                // Esc peels one layer at a time: out of the hand edit
                // first, out of the editor second.
                if session.isEditing {
                    session.cancelEditing()
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
            .help(session.isEditing ? "Stop editing by hand (esc)" : "Close merge editor (esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var sides: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SideHeader(session: session, side: .ours, badge: "A", label: oursLabel)
                Divider()
                SideHeader(session: session, side: .theirs, badge: "B", label: theirsLabel)
            }
            .frame(height: 26)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.alignedRows) { row in
                            AlignedRowView(session: session, row: row)
                                .id(row.opensConflict && row.conflict != nil
                                    ? "c\(row.conflict!)" : "r\(row.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: scroll) { _, request in
                    guard let request else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("c\(request.conflict)", anchor: .center)
                    }
                }
            }
        }
    }

    private func stepButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .zoomFont(10, weight: .semibold)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
        .foregroundStyle(.secondary)
        .help(help)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill"
                : state == .some ? "minus.square.fill" : "square")
                .zoomFont(12)
                .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
    }
}

private struct SideHeader: View {
    @ObservedObject var session: MergeEditorSession
    let side: ConflictSide
    let badge: String
    let label: String

    var body: some View {
        let tint = MergeTint.of(side)
        HStack(spacing: 6) {
            TriStateCheckbox(state: session.wholeSideState(side), tint: tint) {
                session.setWholeSide(side, on: session.wholeSideState(side) != .all)
            }
            .help("Take every conflict from \(badge)")
            Text(badge)
                .zoomFont(10, weight: .bold)
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1.5))
            Text(label)
                .zoomFont(11, weight: .semibold, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(side == .ours ? "ours" : "theirs")
                .zoomFont(10)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 0) {
            SideCell(session: session, row: row, side: .ours, cell: row.left)
            Divider()
            SideCell(session: session, row: row, side: .theirs, cell: row.right)
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
    @State private var hovered = false

    private var tint: Color { MergeTint.of(side) }
    private var picked: Bool { cell?.ref.map(session.isPicked) ?? false }

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
                TriStateCheckbox(state: session.sideState(conflict, side: side), tint: tint) {
                    session.setSide(conflict, side: side,
                                    on: session.sideState(conflict, side: side) != .all)
                }
                .help("Take this block")
            } else {
                Spacer().frame(width: 20)
            }

            Text(cell.map { String($0.number) } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)

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
                        .frame(width: 20)
                        .contentShape(Rectangle())
                        .opacity(picked || hovered ? 1 : 0)
                }
                .buttonStyle(.pressEffect)
                .help(picked ? "Don't take this line" : "Take this line")
            } else {
                Spacer().frame(width: 20)
            }

            // A filler still renders a space: an empty Text measures
            // zero-high, the cell collapses, and its background became
            // a stripe floating mid-row — the banding this replaces.
            Text(cell?.text ?? " ")
                .lineLimit(1)
            Spacer(minLength: 0)
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

/// The bottom pane: the file Save will write, recomputed on every take.
private struct MergeOutputPane: View {
    @ObservedObject var session: MergeEditorSession
    let scroll: MergeScroll?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Output")
                    .zoomFont(11, weight: .semibold)
                Text(session.isEditing
                    ? "editing by hand — Save writes exactly this text"
                    : "what Save writes to \(session.file.fileName)")
                    .zoomFont(10)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isEditing {
                    Button("Cancel Edit") { session.cancelEditing() }
                        .controlSize(.small)
                        .help("Discard the hand edit and go back to picking (esc)")
                } else {
                    // The #6 fallback: touch up the result by hand when
                    // neither side alone is the right text.
                    Button("Edit") { session.beginEditing() }
                        .controlSize(.small)
                        .help("Edit the output text directly — untouched conflicts keep their markers to resolve in place")
                    if session.anyTouched {
                        Button("Reset") { session.reset() }
                            .controlSize(.small)
                            .help("Untake everything and start over")
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            Divider()
            if session.isEditing {
                draftEditor
            } else {
                outputList
            }
        }
    }

    private var draftEditor: some View {
        TextEditor(text: Binding(
            get: { session.draft ?? "" },
            set: { session.draft = $0 }
        ))
        .zoomFont(11, design: .monospaced)
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .padding(.horizontal, 4)
    }

    private var outputList: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.outputLines) { line in
                        OutputLineRow(line: line)
                            .id(line.opensConflict && line.conflict != nil
                                ? "c\(line.conflict!)" : "r\(line.id)")
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: scroll) { _, request in
                guard let request else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("c\(request.conflict)", anchor: .center)
                }
            }
        }
    }
}

private struct OutputLineRow: View {
    let line: MergeEditorSession.OutputLine

    var body: some View {
        if line.number == nil {
            // An unresolved (or emptied) conflict adds no text to the
            // file — GitKraken shows nothing at all. The hairline keeps
            // a navigation anchor and, while unresolved, a trace of the
            // decision still owed.
            Rectangle()
                .fill(line.kind == .unresolved ? Color.orange.opacity(0.55) : Color.clear)
                .frame(height: 2)
                .frame(maxWidth: .infinity)
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
                    .frame(width: 36, alignment: .trailing)
                Spacer().frame(width: 20)
                Text(line.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .zoomFont(11, design: .monospaced)
            .frame(maxWidth: .infinity, alignment: .leading)
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
