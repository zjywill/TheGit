import SwiftUI

/// Right panel: unstaged / staged files + commit message + commit button.
struct CommitPanelView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            if let op = repo.snapshot.operation {
                OperationBanner(op: op, repo: repo)
                Divider()
            }

            if !repo.snapshot.conflicted.isEmpty {
                ConflictSection(repo: repo)
                Divider()
            }

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

/// GitKraken-style banner: a merge/rebase/cherry-pick/revert is paused.
/// Resolve conflicts, then Continue — or Abort to roll everything back.
struct OperationBanner: View {
    let op: OngoingOperation
    @ObservedObject var repo: RepoState

    var body: some View {
        let conflicts = repo.snapshot.conflicted.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(op.rawValue) in progress")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(conflicts > 0
                ? "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") — resolve them, then continue."
                : "All conflicts resolved. Continue to finish the \(op.rawValue.lowercased()).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abort") { repo.abortOperation() }
                Spacer()
                Button("Continue") { repo.continueOperation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(conflicts > 0 || repo.isBusy)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }
}

/// Conflicted files with per-file resolution: take ours, take theirs,
/// or mark resolved after hand-editing.
struct ConflictSection: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conflicted Files (\(repo.snapshot.conflicted.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(repo.snapshot.conflicted) { file in
                ConflictRow(file: file, repo: repo)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            }
            .listStyle(.plain)
            .frame(minHeight: 60, maxHeight: 160)
        }
    }
}

struct ConflictRow: View {
    let file: FileChange
    @ObservedObject var repo: RepoState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory).foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.head)

            Spacer()

            Menu {
                Button("Accept Ours (current branch)") { repo.acceptOurs(file) }
                Button("Accept Theirs (incoming)") { repo.acceptTheirs(file) }
                Divider()
                Button("Mark Resolved (keep file as-is)") { repo.markResolved(file) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Resolve conflict")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Accept Ours (current branch)") { repo.acceptOurs(file) }
            Button("Accept Theirs (incoming)") { repo.acceptTheirs(file) }
            Divider()
            Button("Mark Resolved (keep file as-is)") { repo.markResolved(file) }
        }
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
