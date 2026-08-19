import AppKit
import SwiftUI

/// GitKraken-style unified diff for one working-tree file, shown in place
/// of the graph. One mode only: line numbers, green adds, red deletes.
struct FileDiffView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let pointer = repo.lfsPointer, !repo.showRawPointer {
                // The diff of an LFS file is three lines of pointer text —
                // an oid tells nobody anything. Show what the object is.
                LFSPointerSummary(pointer: pointer, repo: repo)
            } else if let image = repo.imageDiff {
                ImageDiffView(diff: image)
            } else if repo.diffLines.isEmpty {
                Text("No textual changes to show")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Hunk staging only applies to working-tree diffs of
                // tracked files (untracked = stage the whole file).
                let hunksStageable = repo.diffCommit == nil
                    && repo.selectedFile?.status != "?"
                let staged = repo.selectedFile?.area == .staged
                let blame = repo.showBlame
                    ? (repo.blameLines ?? [:])
                    : nil
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(repo.diffLines) { line in
                            DiffLineRow(
                                line: line,
                                blame: blame,
                                hunkAction: hunksStageable && line.hunkIndex != nil
                                    ? (title: staged ? "Unstage Hunk" : "Stage Hunk",
                                       run: { repo.stageHunk(line.hunkIndex!) })
                                    : nil
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let file = repo.selectedFile {
                HStack(spacing: 0) {
                    if !file.directory.isEmpty {
                        Text(file.directory).foregroundStyle(.secondary)
                    }
                    Text(file.fileName).fontWeight(.semibold)
                }
                .zoomFont(12)
                .lineLimit(1)
                .truncationMode(.head)

                if repo.lfsPointer != nil {
                    Text("LFS")
                        .zoomFont(9, weight: .bold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if repo.lfsPointer != nil, repo.showRawPointer {
                    Button("LFS Summary") { repo.showRawPointer = false }
                        .controlSize(.regular)
                }

                if let commitHash = repo.diffCommit {
                    // Diff of a historical commit — nothing to stage.
                    Text("@ \(String(commitHash.prefix(7)))")
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.tertiary)
                } else {
                    // .regular, not .small: the header has 34pt to spend,
                    // and a 19pt bezel in it is a target you have to aim
                    // at. The regular bezel is the whole reachable height.
                    Button(file.area == .staged ? "Unstage File" : "Stage File") {
                        if file.area == .staged {
                            repo.unstage(file)
                        } else {
                            repo.stage(file)
                        }
                        repo.closeDiff()
                    }
                    .controlSize(.regular)
                }

                // Blame only applies to a textual diff — an image or LFS
                // pointer has no lines to attribute — so it is hidden then.
                if repo.diffLines.isEmpty == false,
                   repo.imageDiff == nil, repo.lfsPointer == nil {
                    Button {
                        repo.showBlame.toggle()
                        if repo.showBlame { repo.loadBlame() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                            Text("Blame")
                        }
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(repo.showBlame ? Color.accentColor : .primary)
                    .help("Show which commit last touched each line")
                    .controlSize(.regular)
                }

                Button {
                    repo.closeDiff()
                } label: {
                    // The glyph is 10pt; the target is not. Without the
                    // frame the hittable area is the drawn pixels only.
                    Image(systemName: "xmark")
                        .zoomFont(10, weight: .bold)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close diff (esc)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

/// Raster image comparison shared by working-tree, commit, history and
/// pull-request diffs. The source dimensions are shown alongside the
/// encoded file size so a visually identical density change is still clear.
struct ImageDiffView: View {
    let diff: ImageDiff

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = diff.old != nil && diff.new != nil
                && geometry.size.width >= 760
            ScrollView(.vertical) {
                Group {
                    if sideBySide {
                        HStack(alignment: .top, spacing: 12) {
                            if let old = diff.old {
                                ImageDiffPane(title: "Before", version: old)
                            }
                            if let new = diff.new {
                                ImageDiffPane(title: "After", version: new)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            if let old = diff.old {
                                ImageDiffPane(title: "Before", version: old)
                            }
                            if let new = diff.new {
                                ImageDiffPane(title: "After", version: new)
                            }
                        }
                        .frame(maxWidth: diff.old == nil || diff.new == nil ? 760 : .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(12)
            }
        }
    }
}

private struct ImageDiffPane: View {
    let title: String
    let version: ImageDiffVersion

    private var metadata: String {
        var parts = [version.formattedDimensions, version.formattedByteCount]
        if version.frameCount > 1 {
            parts.append("\(version.frameCount) frames")
        }
        return parts.joined(separator: "  |  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .zoomFont(11, weight: .semibold)
                Spacer(minLength: 12)
                Text(metadata)
                    .zoomFont(10, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            ZStack {
                TransparencyGrid()
                if let image = NSImage(data: version.data) {
                    GeometryReader { geometry in
                        let fitted = fittedSize(in: geometry.size)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(fitted.scale > 1 ? .none : .high)
                            .frame(width: fitted.size.width, height: fitted.size.height)
                            .position(
                                x: geometry.size.width / 2,
                                y: geometry.size.height / 2
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) image, \(metadata)")
        }
        .frame(maxWidth: .infinity)
    }

    private func fittedSize(in bounds: CGSize) -> (size: CGSize, scale: CGFloat) {
        let source = CGSize(
            width: CGFloat(version.pixelWidth),
            height: CGFloat(version.pixelHeight)
        )
        guard source.width > 0, source.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return (.zero, 1) }
        let fit = min(bounds.width / source.width, bounds.height / source.height)
        // Small UI assets need enough enlargement to inspect, but very
        // small icons should not turn into a wall of pixels.
        let scale = min(fit, 4)
        return (
            CGSize(width: source.width * scale, height: source.height * scale),
            scale
        )
    }
}

private struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .windowBackgroundColor))
            )
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: tile, height: tile)),
                            with: .color(Color.primary.opacity(0.045))
                        )
                    }
                    column += 1
                    x += tile
                }
                row += 1
                y += tile
            }
        }
    }
}

/// What a Git LFS pointer diff actually means: which object, how big, and
/// how much the file grew — instead of two hex strings the user cannot
/// compare by eye.
struct LFSPointerSummary: View {
    let pointer: LFSPointerDiff
    @ObservedObject var repo: RepoState

    private var delta: String? {
        guard let delta = pointer.sizeDelta, delta != 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file)
        return delta > 0 ? "+\(size)" : "−\(size)"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .zoomFont(28)
                .foregroundStyle(.tertiary)
            Text("Stored in Git LFS")
                .zoomFont(13, weight: .semibold)

            VStack(spacing: 6) {
                if let new = pointer.new, let old = pointer.old {
                    row("Size", "\(old.formattedSize) → \(new.formattedSize)", trailing: delta)
                    row("Object", "\(old.shortOID) → \(new.shortOID)")
                } else if let new = pointer.new {
                    row("Size", new.formattedSize)
                    row("Object", new.shortOID)
                } else if let old = pointer.old {
                    row("Size", old.formattedSize)
                    row("Object", old.shortOID, trailing: "removed")
                }
            }

            HStack(spacing: 10) {
                Button("Show pointer text") { repo.showRawPointer = true }
                    .controlSize(.small)
                if let file = repo.selectedFile, repo.diffCommit == nil {
                    // Opening a file that was never downloaded hands the
                    // user a 130-byte text file, so offer the fetch first.
                    if repo.isLFSObjectMissing(file.path) {
                        Button("Download LFS Object") { repo.pullLFSObjects() }
                            .controlSize(.small)
                    } else {
                        Button("Open file") { repo.openFile(file) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func row(_ label: String, _ value: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .zoomFont(11)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .zoomFont(11, design: .monospaced)
                .textSelection(.enabled)
            if let trailing {
                Text(trailing)
                    .zoomFont(10, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    /// Blame records keyed by new-file line number, when the Blame column
    /// is on. nil keeps the row in its plain line-number layout (the
    /// pull-request diff view never enables it).
    var blame: [Int: BlameLine]? = nil

    var hunkAction: (title: String, run: () -> Void)?

    private var background: Color {
        switch line.kind {
        case .add: return .green.opacity(0.13)
        case .del: return .red.opacity(0.13)
        case .hunk: return .blue.opacity(0.07)
        case .context: return .clear
        }
    }

    private var marker: String {
        switch line.kind {
        case .add: return "+"
        case .del: return "-"
        default: return " "
        }
    }

    /// The blamed commit for this row's new-file line, if any: only rows
    /// that map to a line in the finished file (adds and context) have one.
    /// Deleted lines vanish from the blamed version, so they can never be
    /// blamed.
    private var blamed: BlameLine? {
        guard let blame, let newNum = line.newNum else { return nil }
        return blame[newNum]
    }

    var body: some View {
        HStack(spacing: 0) {
            if line.kind == .hunk {
                Text(line.text)
                    .foregroundStyle(.blue)
                    .padding(.leading, 8)
                    .padding(.vertical, 3)
                Spacer(minLength: 8)
                if let hunkAction {
                    // The tappable area is the padded shape, not the 10pt
                    // text run — a hunk header is a thin strip and the
                    // words alone are a few dozen hittable pixels.
                    Button(action: hunkAction.run) {
                        Text(hunkAction.title)
                            .zoomFont(10, weight: .medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 4)
                }
            } else {
                if blame != nil {
                    BlameCell(blamed: blamed)
                }
                Text(line.oldNum.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
                Text(line.newNum.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
                Text(marker)
                    .foregroundStyle(line.kind == .add ? .green : line.kind == .del ? .red : .secondary)
                    .frame(width: 16)
                Text(line.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .zoomFont(11, design: .monospaced)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .textSelection(.enabled)
    }
}

/// The author column shown when Blame is on: a short author name and the
/// abbreviated commit hash, hover to see the commit's subject. Rows whose
/// line has no committed blame (uncommitted new lines, deleted lines, or a
/// blame that came back empty) render as a dim dash — an absence, not a
/// value.
private struct BlameCell: View {
    let blamed: BlameLine?

    var body: some View {
        Group {
            if let blamed {
                if blamed.isUncommitted {
                    Text("not committed")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    HStack(spacing: 4) {
                        Text(shortAuthor(blamed.author))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(blamed.shortHash)
                            .foregroundStyle(.tertiary)
                    }
                    .help(blameHelp(blamed))
                }
            } else {
                Text("–")
                    .foregroundStyle(.tertiary.opacity(0.4))
            }
        }
        .frame(width: 140, alignment: .leading)
        .padding(.trailing, 8)
    }

    /// Keep the column narrow: a personal name is the last path component
    /// of the author string, or the whole string when only one word.
    private func shortAuthor(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "unknown" }
        let parts = trimmed.split(separator: " ")
        return String(parts.last ?? "")
    }

    private func blameHelp(_ blamed: BlameLine) -> String {
        let date = blamed.date.formatted(date: .abbreviated, time: .omitted)
        let subject = blamed.summary.isEmpty ? "no message" : blamed.summary
        return "\(blamed.shortHash) · \(blamed.author) · \(date) · \(subject)"
    }
}
