import SwiftUI

/// GitKraken-style unified diff for one working-tree file, shown in place
/// of the graph. One mode only: line numbers, green adds, red deletes.
struct FileDiffView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if repo.diffLines.isEmpty {
                Text("No textual changes to show")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(repo.diffLines) { line in
                            DiffLineRow(line: line)
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
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)

                Spacer()

                Button(file.area == .staged ? "Unstage File" : "Stage File") {
                    if file.area == .staged {
                        repo.unstage(file)
                    } else {
                        repo.stage(file)
                    }
                    repo.closeDiff()
                }
                .controlSize(.small)

                Button {
                    repo.closeDiff()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
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

struct DiffLineRow: View {
    let line: DiffLine

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
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .textSelection(.enabled)
    }
}
