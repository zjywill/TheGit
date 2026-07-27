import SwiftUI

/// Right panel: unstaged / staged files + commit message + commit button.
struct CommitPanelView: View {
    @ObservedObject var repo: RepoState
    @ObservedObject private var ai = AISettings.shared
    @Environment(\.uiZoom) private var zoom
    @State private var confirmingSend = false

    /// Message box height, unzoomed, 0 until the user drags it. A generated
    /// message is several lines longer than a hand-typed one, so the old
    /// fixed 90pt box stopped being enough the moment ✨ landed.
    @AppStorage("commitMessageHeight") private var storedMessageHeight: Double = 0
    /// Live height while the drag is in flight. The stored value is written
    /// once, on release: a UserDefaults write per frame republishes
    /// @AppStorage and rebuilds the whole panel sixty times a second.
    @State private var draggedHeight: CGFloat?
    @State private var dragBaseHeight: CGFloat?
    @State private var hoveringResizer = false

    private static let defaultMessageHeight: CGFloat = 90
    private static let messageHeightRange: ClosedRange<CGFloat> = 60...460

    private var messageHeight: CGFloat {
        if let draggedHeight { return draggedHeight }
        return storedMessageHeight > 0 ? CGFloat(storedMessageHeight) : Self.defaultMessageHeight
    }

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
                bulkAction: { repo.stageAll() },
                repo: repo
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
                bulkAction: { repo.unstageAll() },
                repo: repo
            )

            messageResizer

            VStack(alignment: .leading, spacing: 8) {
                // GitKraken's Commit / Stash mode tabs: same message box,
                // different action.
                Picker("", selection: $repo.panelMode) {
                    ForEach(RepoState.PanelMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Always in the layout — hidden in stash mode instead of
                // removed, so switching tabs never changes the panel height.
                Toggle("Amend previous commit", isOn: $repo.amend)
                    .zoomFont(11)
                    .toggleStyle(.checkbox)
                    .opacity(repo.panelMode == .commit ? 1 : 0)
                    .disabled(repo.panelMode != .commit)
                    .onChange(of: repo.amend) { _, amending in
                        if amending, repo.commitMessage.isEmpty,
                           let subject = repo.headSubject {
                            repo.commitMessage = subject
                        }
                    }

                if ai.isEnabled, repo.panelMode == .commit { generateRow }

                TextEditor(text: $repo.commitMessage)
                    .zoomFont(12)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: messageHeight * zoom)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1))
                    )

                if repo.panelMode == .commit {
                    Button {
                        repo.commit()
                    } label: {
                        Text(commitButtonTitle)
                            // The file count rolls like an odometer when
                            // staging/unstaging — feedback that the button
                            // heard the change, without relayout jumps.
                            .contentTransition(.numericText(value: Double(repo.snapshot.staged.count)))
                            .animation(.easeOut(duration: 0.2), value: repo.snapshot.staged.count)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                } else {
                    // Split button: the whole tree stays the primary action,
                    // but staging a file first is a statement of intent, and
                    // the arrow is where that intent gets honoured. A menu
                    // rather than a second button so the panel keeps its
                    // height whatever is staged.
                    let staged = repo.snapshot.staged.map(\.path)
                    let unstaged = (repo.snapshot.unstaged + repo.snapshot.conflicted).map(\.path)
                    Menu {
                        Button("Stash \(staged.count) Staged File\(staged.count == 1 ? "" : "s")") {
                            repo.stashChanges(only: staged)
                        }
                        .disabled(staged.isEmpty)
                        Button("Stash \(unstaged.count) Unstaged File\(unstaged.count == 1 ? "" : "s")") {
                            repo.stashChanges(only: unstaged)
                        }
                        .disabled(unstaged.isEmpty)
                    } label: {
                        Text("Stash All Changes")
                            .frame(maxWidth: .infinity)
                    } primaryAction: {
                        repo.stashChanges()
                    }
                    .menuStyle(.button)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnyChanges || repo.isBusy)
                }
            }
            .padding(12)
        }
        .background(.background)
        .alert(
            "Discard changes in \(repo.fileToDiscard?.fileName ?? "")?",
            isPresented: Binding(
                get: { repo.fileToDiscard != nil },
                set: { if !$0 { repo.fileToDiscard = nil } }
            )
        ) {
            Button("Discard", role: .destructive) { repo.confirmDiscardFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be restored to its last committed state. Unstaged edits are permanently lost.")
        }
        .alert(
            "Delete \(repo.fileToDelete?.fileName ?? "")?",
            isPresented: Binding(
                get: { repo.fileToDelete != nil },
                set: { if !$0 { repo.fileToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { repo.confirmDeleteFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be removed from disk. Uncommitted changes in it are lost.")
        }
    }

    /// The divider above the message box doubles as its resize handle —
    /// same spreadsheet-column feel as the graph's, turned on its side. The
    /// file lists above are flexible, so the space comes out of them.
    private var messageResizer: some View {
        Rectangle()
            .fill(hoveringResizer || dragBaseHeight != nil
                ? Color.accentColor.opacity(0.6)
                : Color.primary.opacity(0.07))
            // The hover tint fades; the drag itself tracks the pointer 1:1.
            .animation(.easeOut(duration: 0.1), value: hoveringResizer)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                // The handle slides out from under the pointer as the box
                // grows, so hover flips constantly mid-drag. Pushing and
                // popping the cursor on each flip makes it strobe.
                guard dragBaseHeight == nil else { return }
                hoveringResizer = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Global coordinates, not the default local ones: this view
                // moves as a direct result of the drag, and a translation
                // measured against a moving frame feeds back into itself —
                // which is what made fast drags flicker.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBaseHeight ?? messageHeight
                        dragBaseHeight = base
                        // Dragging up grows the box; the height is kept
                        // unzoomed so the box survives ⌘= at its own size.
                        let height = base - value.translation.height / zoom
                        draggedHeight = min(
                            max(height, Self.messageHeightRange.lowerBound),
                            Self.messageHeightRange.upperBound
                        )
                    }
                    .onEnded { _ in
                        if let draggedHeight { storedMessageHeight = Double(draggedHeight) }
                        draggedHeight = nil
                        dragBaseHeight = nil
                    }
            )
            .help("Drag to resize the message box")
    }

    /// GitKraken's ✨: writes the message from the staged diff. Only ever
    /// shown when AI is switched on — a git client with no AI configured
    /// shouldn't grow a button advertising it.
    private var generateRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if repo.isGeneratingMessage {
                ProgressView()
                    .controlSize(.small)
                Button("Stop") { repo.cancelMessageGeneration() }
                    .buttonStyle(.plain)
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
            } else {
                if ai.isReady {
                    Text(ai.modelID)
                        .zoomFont(10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    if ai.didConfirmSending {
                        repo.generateCommitMessage()
                    } else {
                        confirmingSend = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("Generate")
                    }
                    .zoomFont(11)
                }
                .buttonStyle(.pressEffect)
                .disabled(!canGenerate)
                .help(ai.notReadyReason ?? "Write the commit message from the staged diff")
            }
        }
        .alert(
            "Send this diff to \(ai.provider?.name ?? "the provider")?",
            isPresented: $confirmingSend
        ) {
            Button("Send") {
                ai.didConfirmSending = true
                repo.generateCommitMessage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Generating a message uploads the staged diff — file paths and the changed lines — to \(ai.provider?.name ?? "the provider") at \(ai.baseURL?.host ?? "its endpoint").

            TheGit won't ask again. Turn the feature off in Settings (⌘,) at any time.
            """)
        }
    }

    private var canGenerate: Bool {
        ai.isReady && (repo.amend || !repo.snapshot.staged.isEmpty)
    }

    private var canCommit: Bool {
        (repo.amend || !repo.snapshot.staged.isEmpty)
            && !repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repo.isBusy
    }

    private var hasAnyChanges: Bool {
        !repo.snapshot.staged.isEmpty || !repo.snapshot.unstaged.isEmpty
    }

    private var commitButtonTitle: String {
        if repo.amend { return "Amend Previous Commit" }
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
                    .zoomFont(12, weight: .semibold)
                Spacer()
            }
            Text(conflicts > 0
                ? "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") — resolve them, then continue."
                : "All conflicts resolved. Continue to finish the \(op.rawValue.lowercased()).")
                .zoomFont(11)
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
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(repo.snapshot.conflicted) { file in
                        ConflictRow(file: file, repo: repo)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 2)
            }
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
                .zoomFont(11)
                .foregroundStyle(.orange)

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

            Menu {
                Button("Accept Ours (current branch)") { repo.acceptOurs(file) }
                Button("Accept Theirs (incoming)") { repo.acceptTheirs(file) }
                Divider()
                Button("Mark Resolved (keep file as-is)") { repo.markResolved(file) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .zoomFont(13)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Resolve conflict")
        }
        .contentShape(Rectangle())
        .onTapGesture { repo.selectFile(file) }
        .contextTarget("conflict:" + file.id, repo)
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
    @ObservedObject var repo: RepoState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title) (\(files.count))")
                    .zoomFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(files.count)))
                    .animation(.easeOut(duration: 0.2), value: files.count)
                Spacer()
                if !files.isEmpty {
                    Button(bulkTitle) { bulkAction() }
                        .buttonStyle(.pressEffect)
                        .zoomFont(11)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if files.isEmpty {
                Text(emptyText)
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files) { file in
                            FileRow(
                                file: file,
                                actionIcon: actionIcon,
                                actionHelp: actionHelp,
                                isSelected: repo.selectedFile?.id == file.id,
                                action: { action(file) },
                                select: { repo.selectFile(file) }
                            )
                            .contextTarget("file:" + file.id, repo)
                            .contextMenu { FileMenu(file: file, repo: repo) }
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// GitKraken-style right-click menu for a changed file. Staged and
/// unstaged variants differ only in the first block.
struct FileMenu: View {
    let file: FileChange
    @ObservedObject var repo: RepoState

    var body: some View {
        if file.area == .staged {
            Button("Unstage") { repo.unstage(file) }
            Button("Unstage and delete file…") { repo.fileToDelete = file }
        } else {
            Button("Stage") { repo.stage(file) }
            if file.status != "?" {
                // Untracked files have nothing to restore — Delete covers them.
                Button("Discard changes…", role: .destructive) { repo.fileToDiscard = file }
            }
        }
        // Untracked only: git ignores nothing that is already in the index,
        // so offering it on a tracked file would be a menu item that does
        // nothing. Those files need "Stop tracking" instead.
        if file.status == "?" {
            Menu("Ignore") {
                IgnoreButtons(file: file, repo: repo, local: false)
                Divider()
                // .git/info/exclude — same effect, but private to this
                // clone: nothing to commit, nothing pushed to the team.
                Menu("Ignore for me only") {
                    IgnoreButtons(file: file, repo: repo, local: true)
                }
            }
        }
        // Only with git-lfs installed, and only for a file it isn't
        // already storing — "Track" on an LFS file would be a no-op.
        if repo.lfsAvailable, !repo.isLFSTracked(file.path) {
            LFSTrackMenu(file: file, repo: repo)
        }
        Button("Stash file") { repo.stashFile(file) }
        Divider()
        Button("File History") { repo.showFileHistory(file.path) }
        Divider()
        Button("Open file in default program") { repo.openFile(file) }
        Button("Show in Finder") { repo.showInFinder(file) }
        Divider()
        Button("Copy file path") { repo.copyFilePath(file) }
        Button("Create patch from file changes…") { repo.savePatch(forFile: file) }
        Divider()
        Button("Delete file…", role: .destructive) { repo.fileToDelete = file }
    }
}

/// "Track with LFS": writes the pattern to `.gitattributes` and stages it,
/// so the next commit stores a pointer instead of the bytes.
struct LFSTrackMenu: View {
    let file: FileChange
    @ObservedObject var repo: RepoState

    private var ext: String { (file.fileName as NSString).pathExtension }

    var body: some View {
        if ext.isEmpty {
            Button("Track \"\(file.fileName)\" with LFS") {
                repo.trackWithLFS(file, pattern: file.path)
            }
        } else {
            Menu("Track with LFS") {
                Button("Track all \"*.\(ext)\" files") {
                    repo.trackWithLFS(file, pattern: "*.\(ext)")
                }
                Button("Track only \"\(file.fileName)\"") {
                    repo.trackWithLFS(file, pattern: file.path)
                }
            }
        }
    }
}

/// The three ignore granularities — this file, this extension, this
/// directory — shared by the shared and the local (`info/exclude`) menus.
struct IgnoreButtons: View {
    let file: FileChange
    @ObservedObject var repo: RepoState
    let local: Bool

    private var ext: String { (file.fileName as NSString).pathExtension }

    var body: some View {
        Button("Ignore \"\(file.fileName)\"") {
            repo.ignore(pattern: GitIgnore.filePattern(file.path), local: local)
        }
        if !ext.isEmpty {
            Button("Ignore all \"*.\(ext)\" files") {
                repo.ignore(pattern: GitIgnore.extensionPattern(ext), local: local)
            }
        }
        if !file.directory.isEmpty {
            Button("Ignore everything in \"\(file.directory)\"") {
                repo.ignore(pattern: GitIgnore.directoryPattern(file.directory), local: local)
            }
        }
    }
}

struct FileRow: View {
    let file: FileChange
    let actionIcon: String
    let actionHelp: String
    let isSelected: Bool
    let action: () -> Void
    let select: () -> Void
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
                .zoomFont(10, weight: .bold, design: .monospaced)
                .foregroundStyle(statusColor)
                .frame(width: 14)

            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .foregroundStyle(.secondary)
                }
                Text(file.fileName)
            }
            .zoomFont(12)
            .lineLimit(1)
            .truncationMode(.head)

            Spacer()

            Button(action: action) {
                Image(systemName: actionIcon)
                    .zoomFont(13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(Color.accentColor)
            .opacity(hovering ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(actionHelp)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Single click opens the diff — a many-times-a-day action, instant.
        .onTapGesture { select() }
    }
}
