import Foundation

// The merge editor's data layer: a conflict-markered file read straight
// from the working tree, split into the shared text and the contested
// blocks, plus the user's picks. Parsing the markers git already wrote —
// instead of re-diffing the :1/:2/:3 index stages — means the blocks here
// are exactly the blocks `git merge` reported, orange-for-orange with
// what a terminal user sees.

/// Which side of a conflict a line belongs to. `ours` is the branch that
/// was checked out (HEAD, the `<<<<<<<` half), `theirs` the one being
/// merged, rebased or cherry-picked in (the `>>>>>>>` half).
enum ConflictSide {
    case ours, theirs
}

/// One pickable line: which conflict, which side, which line of that side.
struct ConflictLineRef: Hashable {
    var conflict: Int
    var side: ConflictSide
    var line: Int
}

/// One conflicted region: the lines each side wants it to say.
struct ConflictBlock: Identifiable, Equatable {
    let id: Int
    var ours: [String] = []
    var theirs: [String] = []
    /// The ||||||| middle section under merge.conflictStyle=diff3/zdiff3.
    /// Kept out of both panes and out of the output — it is what the text
    /// said before either side touched it, context and never a resolution.
    var base: [String] = []
    var oursLabel = ""
    var theirsLabel = ""
}

/// A conflict-markered file in file order: runs of shared text
/// alternating with conflict blocks.
struct ConflictDocument: Equatable {
    enum Segment: Equatable {
        case shared([String])
        case conflict(Int)
    }

    var segments: [Segment] = []
    var conflicts: [ConflictBlock] = []
    var endsWithNewline = true

    /// nil when the text has no complete conflict block — deleted-by-them
    /// and binary conflicts carry no markers, and those fall back to the
    /// plain diff view.
    static func parse(_ text: String) -> ConflictDocument? {
        var lines = text.components(separatedBy: "\n")
        var doc = ConflictDocument()
        if lines.last == "" {
            lines.removeLast()
        } else {
            doc.endsWithNewline = false
        }

        enum Mode { case shared, ours, base, theirs }
        var mode = Mode.shared
        var run: [String] = []
        var block = ConflictBlock(id: 0)

        for line in lines {
            switch mode {
            case .shared:
                if line.hasPrefix("<<<<<<<") {
                    block = ConflictBlock(id: doc.conflicts.count)
                    block.oursLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    mode = .ours
                } else {
                    run.append(line)
                }
            case .ours:
                if line.hasPrefix("|||||||") {
                    mode = .base
                } else if line == "=======" {
                    mode = .theirs
                } else {
                    block.ours.append(line)
                }
            case .base:
                if line == "=======" {
                    mode = .theirs
                } else {
                    block.base.append(line)
                }
            case .theirs:
                if line.hasPrefix(">>>>>>>") {
                    block.theirsLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    if !run.isEmpty {
                        doc.segments.append(.shared(run))
                        run = []
                    }
                    doc.segments.append(.conflict(doc.conflicts.count))
                    doc.conflicts.append(block)
                    mode = .shared
                } else {
                    block.theirs.append(line)
                }
            }
        }

        // A block the file ends inside of (truncated write, or markers
        // that were never git's) isn't a conflict — put its lines back
        // as ordinary text so nothing silently disappears on save.
        if mode != .shared {
            run.append(contentsOf: ["<<<<<<< " + block.oursLabel] + block.ours)
            if !block.base.isEmpty { run.append(contentsOf: ["|||||||"] + block.base) }
            if mode == .theirs { run.append(contentsOf: ["======="] + block.theirs) }
        }
        if !run.isEmpty { doc.segments.append(.shared(run)) }

        return doc.conflicts.isEmpty ? nil : doc
    }
}

/// One cell of the side-by-side view: a line as one side has it.
struct MergeCell {
    /// Line number in this side's version of the file.
    let number: Int
    let text: String
    /// Set on lines inside a conflict block; nil for shared text.
    let ref: ConflictLineRef?
}

/// One row of the aligned side-by-side view. Both sides live in the same
/// row — the two "panes" are two columns of ONE scroll view, which is
/// what keeps them aligned and scrolling together (GitKraken pads the
/// shorter side of each block the same way). A nil cell is the filler
/// where the other side's block is longer.
struct MergeAlignedRow: Identifiable {
    let id: Int
    let left: MergeCell?
    let right: MergeCell?
    /// Which conflict this row is inside, nil for shared text.
    let conflict: Int?
    /// True on a block's first row — where the gutter checkboxes sit.
    let opensConflict: Bool
}

/// Everything one open merge editor knows: the parsed document, the
/// aligned rows, and which lines the user has taken so far — in the
/// order they took them, because that order is the output order
/// (GitKraken semantics: take B then A and the block reads B then A).
@MainActor
final class MergeEditorSession: ObservableObject {
    let file: FileChange
    let document: ConflictDocument
    let encoding: String.Encoding
    let alignedRows: [MergeAlignedRow]

    /// Per conflict: nil until the user touches it, then the taken lines
    /// in click order. The nil/empty distinction is the Save gate — an
    /// untouched conflict blocks saving, while an explicitly emptied one
    /// means "drop both sides".
    @Published var choices: [[ConflictLineRef]?]

    /// Non-nil while the user is hand-editing the output. The draft is
    /// the whole truth once it exists: Save writes it verbatim and the
    /// checkboxes freeze — regenerating from picks would eat the edits.
    @Published var draft: String?

    init(file: FileChange, document: ConflictDocument, encoding: String.Encoding) {
        self.file = file
        self.document = document
        self.encoding = encoding
        self.choices = Array(repeating: nil, count: document.conflicts.count)
        self.alignedRows = Self.aligned(document)
    }

    private static func aligned(_ doc: ConflictDocument) -> [MergeAlignedRow] {
        var rows: [MergeAlignedRow] = []
        var leftNumber = 1
        var rightNumber = 1
        for segment in doc.segments {
            switch segment {
            case .shared(let lines):
                for line in lines {
                    rows.append(MergeAlignedRow(
                        id: rows.count,
                        left: MergeCell(number: leftNumber, text: line, ref: nil),
                        right: MergeCell(number: rightNumber, text: line, ref: nil),
                        conflict: nil, opensConflict: false))
                    leftNumber += 1
                    rightNumber += 1
                }
            case .conflict(let index):
                let block = doc.conflicts[index]
                // max(…, 1): a block where one side is empty still needs
                // its row — the checkboxes live on it.
                let height = max(block.ours.count, block.theirs.count, 1)
                for i in 0..<height {
                    var left: MergeCell?
                    var right: MergeCell?
                    if i < block.ours.count {
                        left = MergeCell(
                            number: leftNumber, text: block.ours[i],
                            ref: ConflictLineRef(conflict: index, side: .ours, line: i))
                        leftNumber += 1
                    }
                    if i < block.theirs.count {
                        right = MergeCell(
                            number: rightNumber, text: block.theirs[i],
                            ref: ConflictLineRef(conflict: index, side: .theirs, line: i))
                        rightNumber += 1
                    }
                    rows.append(MergeAlignedRow(
                        id: rows.count, left: left, right: right,
                        conflict: index, opensConflict: i == 0))
                }
            }
        }
        return rows
    }

    // MARK: - Picks

    var resolvedCount: Int { choices.lazy.filter { $0 != nil }.count }
    var allResolved: Bool { !choices.contains(nil) }
    var anyTouched: Bool { choices.contains { $0 != nil } }

    func isPicked(_ ref: ConflictLineRef) -> Bool {
        choices[ref.conflict]?.contains(ref) ?? false
    }

    /// Take (or untake) one line. A fresh take goes to the END of the
    /// conflict's list — output order is click order.
    func toggleLine(_ ref: ConflictLineRef) {
        var picked = choices[ref.conflict] ?? []
        if let at = picked.firstIndex(of: ref) {
            picked.remove(at: at)
        } else {
            picked.append(ref)
        }
        choices[ref.conflict] = picked
    }

    private func lineCount(_ conflict: Int, side: ConflictSide) -> Int {
        let block = document.conflicts[conflict]
        return side == .ours ? block.ours.count : block.theirs.count
    }

    enum SideState { case none, some, all }

    /// Checked / mixed / unchecked for one conflict's side checkbox.
    func sideState(_ conflict: Int, side: ConflictSide) -> SideState {
        guard let picked = choices[conflict] else { return .none }
        let count = lineCount(conflict, side: side)
        let taken = picked.lazy.filter { $0.side == side }.count
        if taken == 0 { return count == 0 ? .all : .none }
        return taken == count ? .all : .some
    }

    /// Take a whole side of one block. The block arrives at the end of
    /// the list as one run, in file order — same click-order rule.
    func setSide(_ conflict: Int, side: ConflictSide, on: Bool) {
        var picked = (choices[conflict] ?? []).filter { $0.side != side }
        if on {
            for i in 0..<lineCount(conflict, side: side) {
                picked.append(ConflictLineRef(conflict: conflict, side: side, line: i))
            }
        }
        choices[conflict] = picked
    }

    /// The column header's checkbox: this side across every conflict.
    func wholeSideState(_ side: ConflictSide) -> SideState {
        let states = (0..<document.conflicts.count).map { sideState($0, side: side) }
        if states.allSatisfy({ $0 == .all }) { return .all }
        if states.allSatisfy({ $0 == .none }) { return .none }
        return .some
    }

    func setWholeSide(_ side: ConflictSide, on: Bool) {
        for i in 0..<document.conflicts.count { setSide(i, side: side, on: on) }
    }

    /// Back to untouched — GitKraken's Reset.
    func reset() {
        choices = Array(repeating: nil, count: document.conflicts.count)
    }

    // MARK: - Output

    /// One output row: shared text, a taken line (tinted by the side it
    /// came from), or the thin strip an unresolved conflict leaves.
    struct OutputLine: Identifiable {
        enum Kind { case shared, picked, unresolved }
        let id: Int
        let number: Int?
        let text: String
        let kind: Kind
        /// The side a picked line came from — its tint and margin letter.
        let side: ConflictSide?
        /// Which conflict a picked/unresolved row belongs to — the
        /// navigation anchor.
        let conflict: Int?
        let opensConflict: Bool
    }

    /// What Save would write, as rows. An unresolved conflict contributes
    /// no text — just a marker row so navigation still has somewhere to
    /// land (GitKraken shows nothing at all; its output pane is
    /// scroll-synced, ours navigates by anchor).
    var outputLines: [OutputLine] {
        var rows: [OutputLine] = []
        var number = 1
        for segment in document.segments {
            switch segment {
            case .shared(let lines):
                for line in lines {
                    rows.append(OutputLine(
                        id: rows.count, number: number, text: line,
                        kind: .shared, side: nil, conflict: nil, opensConflict: false))
                    number += 1
                }
            case .conflict(let index):
                guard let picked = choices[index], !picked.isEmpty else {
                    // Untouched or explicitly emptied: no lines. The
                    // marker row renders as a hairline, not text.
                    rows.append(OutputLine(
                        id: rows.count, number: nil, text: "",
                        kind: choices[index] == nil ? .unresolved : .picked,
                        side: nil, conflict: index, opensConflict: true))
                    continue
                }
                for (i, ref) in picked.enumerated() {
                    rows.append(OutputLine(
                        id: rows.count, number: number, text: text(of: ref),
                        kind: .picked, side: ref.side,
                        conflict: index, opensConflict: i == 0))
                    number += 1
                }
            }
        }
        return rows
    }

    private func text(of ref: ConflictLineRef) -> String {
        let block = document.conflicts[ref.conflict]
        return ref.side == .ours ? block.ours[ref.line] : block.theirs[ref.line]
    }

    /// The file Save writes: the hand-edited draft verbatim when there
    /// is one, otherwise shared text plus the taken lines in the order
    /// they were taken.
    func resolvedContent() -> String {
        if let draft { return draft }
        var lines: [String] = []
        for segment in document.segments {
            switch segment {
            case .shared(let shared):
                lines.append(contentsOf: shared)
            case .conflict(let index):
                for ref in choices[index] ?? [] { lines.append(text(of: ref)) }
            }
        }
        return lines.joined(separator: "\n") + (document.endsWithNewline ? "\n" : "")
    }

    // MARK: - Hand editing

    var isEditing: Bool { draft != nil }

    /// A hand-edit that still contains conflict markers is a file nobody
    /// meant to save — the gate the Save button checks while editing.
    var draftHasMarkers: Bool {
        guard let draft else { return false }
        return draft.components(separatedBy: "\n").contains {
            $0.hasPrefix("<<<<<<<") || $0 == "=======" || $0.hasPrefix(">>>>>>>")
        }
    }

    var canSave: Bool { isEditing ? !draftHasMarkers : allResolved }

    func beginEditing() {
        draft = editableContent()
    }

    func cancelEditing() {
        draft = nil
    }

    /// The seed for hand editing: what the picks produced so far — and
    /// where a conflict is still untouched, its ORIGINAL marker block,
    /// so the text to resolve is right there under the cursor instead
    /// of silently dropped.
    func editableContent() -> String {
        var lines: [String] = []
        for segment in document.segments {
            switch segment {
            case .shared(let shared):
                lines.append(contentsOf: shared)
            case .conflict(let index):
                if let picked = choices[index] {
                    for ref in picked { lines.append(text(of: ref)) }
                } else {
                    let block = document.conflicts[index]
                    lines.append("<<<<<<< " + block.oursLabel)
                    lines.append(contentsOf: block.ours)
                    if !block.base.isEmpty {
                        lines.append("|||||||")
                        lines.append(contentsOf: block.base)
                    }
                    lines.append("=======")
                    lines.append(contentsOf: block.theirs)
                    lines.append(">>>>>>> " + block.theirsLabel)
                }
            }
        }
        return lines.joined(separator: "\n") + (document.endsWithNewline ? "\n" : "")
    }
}
