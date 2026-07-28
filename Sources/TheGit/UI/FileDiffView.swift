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
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(repo.diffLines) { line in
                            DiffLineRow(
                                line: line,
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
