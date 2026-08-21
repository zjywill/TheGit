import SwiftUI

/// Right panel when a commit is selected in the graph: metadata plus the
/// files it touched. Clicking a file shows that commit's diff for it.
struct CommitDetailView: View {
    @ObservedObject var repo: RepoState
    let commit: Commit
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commit Details")
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    repo.selectedCommit = nil
                } label: {
                    Image(systemName: "xmark")
                        .zoomFont(10, weight: .bold)
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .help("Back to commit panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject)
                    .zoomFont(12, weight: .semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(commit.author)
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .zoomFont(11)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.tertiary)
                    Button {
                        RepoState.copyToPasteboard(commit.hash)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .zoomFont(9)
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(.secondary)
                    .help("Copy full sha")
                }
            }
            .padding(12)

            Divider()

            HStack {
                Text("Changed Files (\(repo.commitFiles.count))")
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, FileListMetrics.inset)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: FileListMetrics.spacing * zoom) {
                    ForEach(repo.commitFiles) { file in
                        CommitFileRow(
                            file: file,
                            isSelected: repo.selectedFile?.id == file.id && repo.diffCommit != nil
                        ) {
                            repo.selectCommitFile(file)
                        }
                        .padding(.horizontal, (FileListMetrics.inset - FileListMetrics.bleed) * zoom)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(.background)
    }
}

struct CommitFileRow: View {
    let file: FileChange
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    var statusColor: Color { Self.color(for: file.status) }

    /// git's letter in the colour the whole app uses for it; the hover
    /// card's rows borrow it so a file reads the same on both.
    static func color(for status: Character) -> Color {
        switch status {
        case "A": return .green
        case "M": return .yellow
        case "D": return .red
        case "R", "C": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(file.status))
                .zoomFont(10, weight: .bold, design: .monospaced)
                .foregroundStyle(statusColor)
                .frame(width: 14)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory).foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .zoomFont(12)
            .lineLimit(1)
            .truncationMode(.head)

            Spacer()
        }
        .padding(.horizontal, FileListMetrics.bleed * zoom)
        .frame(height: FileListMetrics.row * zoom)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.15)
                        : (hovering ? Color.primary.opacity(0.06) : .clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { select() }
    }
}
