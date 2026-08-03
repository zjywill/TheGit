import Foundation

// The merge editor's data layer: a conflict-markered file read straight
// from the working tree, split into the shared text and the contested
// blocks, plus the user's picks. Parsing the markers git already wrote —
// instead of re-diffing the :1/:2/:3 index stages — means the blocks here
// are exactly the blocks `git merge` reported, orange-for-orange with
// what a terminal user sees.

/// Which side of a conflict a line belongs to. These are Git's stage-2
/// (`<<<<<<<`) and stage-3 (`>>>>>>>`) sides; their human meaning depends
/// on the operation, especially during a rebase.
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
    var markerSize = 7
    var oursMarker = "<<<<<<<"
    var baseMarker: String?
    var separatorMarker = "======="
    var theirsMarker = ">>>>>>>"
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
    var lineEnding = "\n"

    /// nil when the text has no complete conflict block — deleted-by-them
    /// and binary conflicts carry no markers, and those fall back to the
    /// plain diff view.
    static func parse(_ text: String) -> ConflictDocument? {
        var lines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map(String.init)
        var doc = ConflictDocument()
        doc.lineEnding = firstLineEnding(in: text)
        doc.endsWithNewline = text.last?.isNewline == true
        if doc.endsWithNewline, lines.last == "" {
            lines.removeLast()
        }

        enum Mode { case shared, ours, base, theirs }
        var mode = Mode.shared
        var run: [String] = []
        var block = ConflictBlock(id: 0)
        var rawBlock: [String] = []

        for line in lines {
            switch mode {
            case .shared:
                if let marker = marker(line, character: "<") {
                    block = ConflictBlock(id: doc.conflicts.count)
                    block.markerSize = marker.length
                    block.oursLabel = marker.label
                    block.oursMarker = line
                    rawBlock = [line]
                    mode = .ours
                } else {
                    run.append(line)
                }
            case .ours:
                rawBlock.append(line)
                if marker(
                    line,
                    character: "|",
                    length: block.markerSize
                ) != nil {
                    block.baseMarker = line
                    mode = .base
                } else if marker(
                    line,
                    character: "=",
                    length: block.markerSize
                ) != nil {
                    block.separatorMarker = line
                    mode = .theirs
                } else {
                    block.ours.append(line)
                }
            case .base:
                rawBlock.append(line)
                if marker(
                    line,
                    character: "=",
                    length: block.markerSize
                ) != nil {
                    block.separatorMarker = line
                    mode = .theirs
                } else {
                    block.base.append(line)
                }
            case .theirs:
                rawBlock.append(line)
                if let marker = marker(
                    line,
                    character: ">",
                    length: block.markerSize
                ) {
                    block.theirsLabel = marker.label
                    block.theirsMarker = line
                    if !run.isEmpty {
                        doc.segments.append(.shared(run))
                        run = []
                    }
                    doc.segments.append(.conflict(doc.conflicts.count))
                    doc.conflicts.append(block)
                    rawBlock = []
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
            run.append(contentsOf: rawBlock)
        }
        if !run.isEmpty { doc.segments.append(.shared(run)) }

        return doc.conflicts.isEmpty ? nil : doc
    }

    private static func firstLineEnding(in text: String) -> String {
        for character in text where character.isNewline {
            return String(character)
        }
        return "\n"
    }

    private static func marker(
        _ line: String,
        character: Character,
        length: Int? = nil
    ) -> (length: Int, label: String)? {
        let count = line.prefix { $0 == character }.count
        guard count >= 7, length == nil || count == length else { return nil }
        let remainder = line.dropFirst(count)
        if character == "=" {
            guard remainder.allSatisfy(\.isWhitespace) else { return nil }
        } else {
            guard remainder.isEmpty || remainder.first?.isWhitespace == true else {
                return nil
            }
        }
        return (
            count,
            String(remainder).trimmingCharacters(in: .whitespaces)
        )
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
    private let byteOrderMark: Data
    /// Exact bytes this editor parsed. Save compares the working tree
    /// against them before writing so another editor cannot be silently
    /// overwritten. Updated after our own successful write, even if
    /// staging then fails, so a retry remains possible.
    var originalData: Data

    /// Per conflict: nil until the user touches it, then the taken lines
    /// in click order. The nil/empty distinction is the Save gate — an
    /// untouched conflict blocks saving, while an explicitly emptied one
    /// means "drop both sides".
    @Published var choices: [[ConflictLineRef]?]

    /// Non-nil while the user is hand-editing the output. The draft is
    /// the whole truth once it exists: Save writes it verbatim and the
    /// checkboxes freeze — regenerating from picks would eat the edits.
    @Published var draft: String?
    @Published var isSaving = false
    var acknowledgedExternalStatusChange = false

    init(
        file: FileChange,
        document: ConflictDocument,
        encoding: String.Encoding,
        originalData: Data
    ) {
        self.file = file
        self.document = document
        let bom = Self.byteOrderMark(in: originalData)
        self.byteOrderMark = bom
        self.encoding = Self.roundTripEncoding(encoding, byteOrderMark: bom)
        self.originalData = originalData
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
        return join(lines, endingWithNewline: document.endsWithNewline)
    }

    func encodedContent(_ content: String) -> Data? {
        guard var data = content.data(
            using: encoding,
            allowLossyConversion: false
        ) else { return nil }
        if !byteOrderMark.isEmpty, !data.starts(with: byteOrderMark) {
            var marked = byteOrderMark
            marked.append(data)
            data = marked
        }
        return data
    }

    // MARK: - Hand editing

    var isEditing: Bool { draft != nil }
    var handEditIsDirty: Bool {
        guard let draft else { return false }
        return draft != editableContent()
    }
    var hasUnsavedChanges: Bool { anyTouched || handEditIsDirty }

    /// Marker lines still in a hand edit usually mean the conflict is not
    /// resolved. All four diff3 forms count, including a lone/partial
    /// marker. The UI warns rather than permanently blocking Save because
    /// source files can legitimately contain marker-looking literals.
    var draftHasMarkers: Bool {
        guard let draft else { return false }
        return draft.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map(String.init).contains(where: Self.isConflictMarkerLine)
    }

    var canSave: Bool { isEditing || allResolved }

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
                    lines.append(block.oursMarker)
                    lines.append(contentsOf: block.ours)
                    if let baseMarker = block.baseMarker {
                        lines.append(baseMarker)
                        lines.append(contentsOf: block.base)
                    }
                    lines.append(block.separatorMarker)
                    lines.append(contentsOf: block.theirs)
                    lines.append(block.theirsMarker)
                }
            }
        }
        return join(lines, endingWithNewline: document.endsWithNewline)
    }

    private func join(_ lines: [String], endingWithNewline: Bool) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: document.lineEnding)
            + (endingWithNewline ? document.lineEnding : "")
    }

    private static func byteOrderMark(in data: Data) -> Data {
        let markers: [[UInt8]] = [
            [0x00, 0x00, 0xFE, 0xFF],
            [0xFF, 0xFE, 0x00, 0x00],
            [0xEF, 0xBB, 0xBF],
            [0xFE, 0xFF],
            [0xFF, 0xFE],
        ]
        for marker in markers where data.starts(with: marker) {
            return Data(marker)
        }
        return Data()
    }

    private static func roundTripEncoding(
        _ detected: String.Encoding,
        byteOrderMark: Data
    ) -> String.Encoding {
        switch Array(byteOrderMark) {
        case [0x00, 0x00, 0xFE, 0xFF]: return .utf32BigEndian
        case [0xFF, 0xFE, 0x00, 0x00]: return .utf32LittleEndian
        case [0xFE, 0xFF]: return .utf16BigEndian
        case [0xFF, 0xFE]: return .utf16LittleEndian
        default: return detected
        }
    }

    private static func isConflictMarkerLine(_ line: String) -> Bool {
        guard let first = line.first, "<|=>".contains(first) else { return false }
        let markerLength = line.prefix { $0 == first }.count
        guard markerLength >= 7 else { return false }
        let remainder = line.dropFirst(markerLength)
        switch first {
        case "=":
            return remainder.allSatisfy(\.isWhitespace)
        case "<", "|", ">":
            return remainder.isEmpty || remainder.first?.isWhitespace == true
        default:
            return false
        }
    }
}
