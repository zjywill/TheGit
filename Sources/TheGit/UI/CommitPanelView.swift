import SwiftUI

/// Right panel: unstaged / staged files + commit message + commit button.
struct CommitPanelView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            FileSection(
                title: "Unstaged Files",
                files: repo.snapshot.unstaged,
                actionIcon: "plus.circle",
                actionHelp: "Stage file",
                bulkTitle: "Stage All",
                emptyText: "No unstaged changes",
                action: { repo.stage($0) },
                bulkAction: { repo.stageAll() }
            )

            Divider()

            FileSection(
                title: "Staged Files",
                files: repo.snapshot.staged,
                actionIcon: "minus.circle",
                actionHelp: "Unstage file",
                bulkTitle: "Unstage All",
                emptyText: "No staged changes",
                action: { repo.unstage($0) },
                bulkAction: { repo.unstageAll() }
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Commit Message")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextEditor(text: $repo.commitMessage)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1))
                    )

                Button {
                    repo.commit()
                } label: {
                    Text(commitButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
            }
            .padding(12)
        }
        .background(.background)
    }

    private var canCommit: Bool {
        !repo.snapshot.staged.isEmpty
            && !repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repo.isBusy
    }

    private var commitButtonTitle: String {
        let count = repo.snapshot.staged.count
        return count > 0 ? "Commit Changes to \(count) File\(count == 1 ? "" : "s")" : "Commit"
    }
}

struct FileSection: View {
    let title: String
    let files: [FileChange]
    let actionIcon: String
    let actionHelp: String
    let bulkTitle: String
    let emptyText: String
    let action: (FileChange) -> Void
    let bulkAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title) (\(files.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !files.isEmpty {
                    Button(bulkTitle) { bulkAction() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if files.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files) { file in
                    FileRow(file: file, actionIcon: actionIcon, actionHelp: actionHelp) {
                        action(file)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct FileRow: View {
    let file: FileChange
    let actionIcon: String
    let actionHelp: String
    let action: () -> Void
    @State private var hovering = false

    var statusColor: Color {
        switch file.status {
        case "A", "?": return .green
        case "M": return .yellow
        case "D": return .red
        case "R", "C": return .blue
        case "U": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.head)

            Spacer()

            Button(action: action) {
                Image(systemName: actionIcon)
                    .font(.system(size: 13))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(Color.accentColor)
            .opacity(hovering ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(actionHelp)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { action() }
    }
}
