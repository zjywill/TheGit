import SwiftUI

/// Every commit that touched one file (follows renames), shown over the
/// graph. Clicking an entry opens that commit's diff for the file.
struct FileHistoryView: View {
    @ObservedObject var repo: RepoState
    let path: String
    let commits: [Commit]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                Text(path)
                    .zoomFont(12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("\(commits.count) commits")
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    repo.closeFileHistory()
                } label: {
                    Image(systemName: "xmark")
                        .zoomFont(10, weight: .bold)
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close file history (esc)")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commits) { commit in
                        HStack(spacing: 8) {
                            Text(commit.subject)
                                .zoomFont(12)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(commit.author)
                                .zoomFont(11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 90, alignment: .trailing)
                            Text(commit.date.formatted(date: .abbreviated, time: .omitted))
                                .zoomFont(11)
                                .foregroundStyle(.tertiary)
                                .frame(width: 76, alignment: .trailing)
                            Text(commit.shortHash)
                                .zoomFont(11, design: .monospaced)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { repo.selectHistoryEntry(commit, path: path) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
