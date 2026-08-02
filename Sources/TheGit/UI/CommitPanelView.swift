import AppKit
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

            // Sections size to their content: a one-file list takes one
            // row, an empty list takes a single hint line. The spacer
            // below absorbs what's left, so short lists sit together at
            // the top instead of floating in two half-panel voids. Long
            // lists still split the available space between them.
            FileSection(
                title: "Unstaged Files",
                files: repo.snapshot.unstaged,
                actionIcon: "plus.circle",
                actionHelp: "Stage file",
                actionTitle: "Stage",
                bulkTitle: "Stage All",
                emptyText: "No unstaged changes — working tree is clean",
                action: { repo.stage($0) },
                batchAction: { repo.stage($0) },
                bulkAction: { repo.stageAll() },
                repo: repo
            )

            FileSection(
                title: "Staged Files",
                files: repo.snapshot.staged,
                actionIcon: "minus.circle",
                actionHelp: "Unstage file",
                actionTitle: "Unstage",
                bulkTitle: "Unstage All",
                emptyText: "No staged changes — stage files to commit them",
                action: { repo.unstage($0) },
                batchAction: { repo.unstage($0) },
                bulkAction: { repo.unstageAll() },
                repo: repo
            )

            Spacer(minLength: 0)

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
                        repo.amendChanged(amending)
                    }

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
                    // A TextEditor has no placeholder of its own; without
                    // one an empty box gives no hint of what belongs here
                    // (or that a stash message is optional).
                    .overlay(alignment: .topLeading) {
                        if repo.commitMessage.isEmpty {
                            Text(repo.panelMode == .commit
                                ? "Commit message" : "Stash message (optional)")
                                .zoomFont(12)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 11)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    // ✨ lives inside the box it writes into — the control
                    // next to what it affects, instead of a stray row of
                    // chrome floating above.
                    .overlay(alignment: .bottomTrailing) {
                        if ai.isEnabled, repo.panelMode == .commit {
                            generateControl
                                .padding(6)
                        }
                    }

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
                    // A grey button with no reason is a dead end; the
                    // tooltip names the missing step.
                    .help(canCommit ? "" : cannotCommitReason)
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
        // Staging moves a row from one list to the other; the sections
        // resize to follow. Critically damped — layout should settle,
        // not bounce.
        .animation(
            .spring(response: 0.3, dampingFraction: 1),
            value: repo.snapshot.staged.count
        )
        .animation(
            .spring(response: 0.3, dampingFraction: 1),
            value: repo.snapshot.unstaged.count
        )
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
        .alert(
            "Stop tracking \(repo.pendingIgnore?.file.fileName ?? "")?",
            isPresented: Binding(
                get: { repo.pendingIgnore != nil },
                set: { if !$0 { repo.pendingIgnore = nil } }
            ),
            presenting: repo.pendingIgnore
        ) { _ in
            Button("Ignore and Stop Tracking") { repo.confirmIgnore() }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            // Spell out the index part: the file staying on disk while the
            // next commit records it as deleted is the surprising half.
            Text("""
                \(pending.pattern) goes into \(pending.ignoreFile). \
                Git only ignores files it isn't already tracking, so \
                \(pending.file.fileName) is removed from the index — it stays \
                on disk, and the next commit records it as deleted for \
                everyone else.
                """)
        }
        .alert(
            "Stop tracking \(repo.fileToUntrack?.fileName ?? "")?",
            isPresented: Binding(
                get: { repo.fileToUntrack != nil },
                set: { if !$0 { repo.fileToUntrack = nil } }
            )
        ) {
            Button("Stop Tracking") { repo.confirmStopTracking() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // No pattern is written here, so say what that leaves behind:
            // without an ignore rule the file comes straight back as
            // untracked, which looks like the action did nothing.
            Text("""
                The file is removed from the index and stays on disk. The next \
                commit records it as deleted for everyone else, and unless an \
                ignore rule covers it, it reappears here as an untracked file.
                """)
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
    /// shouldn't grow a button advertising it. Sits inside the message
    /// box; the model id moved into the tooltip, where detail belongs.
    private var generateControl: some View {
        HStack(spacing: 6) {
            if repo.isGeneratingMessage {
                ProgressView()
                    .controlSize(.small)
                Button("Stop") { repo.cancelMessageGeneration() }
                    .buttonStyle(.plain)
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
            } else {
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
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.pressEffect)
                .disabled(!canGenerate)
                .help(
                    ai.notReadyReason
                        ?? "Write the commit message from the staged diff (\(ai.modelID))"
                )
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
            // git refuses to commit with unmerged paths; greying the button
            // out says so before the error alert would.
            && repo.snapshot.conflicted.isEmpty
            && !repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repo.isBusy
    }

    /// The first missing step, in the order the user would fix them.
    private var cannotCommitReason: String {
        if !repo.snapshot.conflicted.isEmpty { return "Resolve the conflicted files first" }
        if !repo.amend && repo.snapshot.staged.isEmpty { return "Stage at least one file to commit" }
        if repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a commit message"
        }
        return "Working…"
    }

    private var hasAnyChanges: Bool {
        !repo.snapshot.staged.isEmpty || !repo.snapshot.unstaged.isEmpty
    }

    private var commitButtonTitle: String {
        if repo.amend { return "Amend Previous Commit" }
        // Mid-merge, "Commit Changes to 236 Files" reads like an accident
        // about to happen; committing here is what completes the merge,
        // so say that (GitKraken's "Commit and Merge").
        if repo.snapshot.operation == .merge { return "Commit and Complete Merge" }
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
            // GitKraken names both sides mid-merge; "Merge in progress"
            // alone doesn't say what is being merged into what.
            if let headline = repo.snapshot.operationHeadline {
                Text(headline)
                    .zoomFont(11, weight: .medium)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conflicted Files (\(repo.snapshot.conflicted.count))")
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding(.horizontal, FileListMetrics.inset)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: FileListMetrics.spacing * zoom) {
                    ForEach(repo.snapshot.conflicted) { file in
                        ConflictRow(file: file, repo: repo)
                            .padding(.horizontal, (FileListMetrics.inset - FileListMetrics.bleed) * zoom)
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
    @Environment(\.uiZoom) private var zoom

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
        .padding(.horizontal, FileListMetrics.bleed * zoom)
        .frame(height: FileListMetrics.row * zoom)
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
    let actionTitle: String
    let bulkTitle: String
    let emptyText: String
    let action: (FileChange) -> Void
    let batchAction: ([FileChange]) -> Void
    let bulkAction: () -> Void
    @ObservedObject var repo: RepoState
    @Environment(\.uiZoom) private var zoom
    @FocusState private var focusedFileID: FileChange.ID?

    /// What the rows genuinely need, so the list never claims more. When
    /// two long lists both want more than the panel has, the VStack splits
    /// the space between them — same behaviour as before for full panels.
    private var contentHeight: CGFloat {
        let rows = CGFloat(files.count)
        return (rows * FileListMetrics.row + (rows - 1) * FileListMetrics.spacing) * zoom + 4
    }

    private var selectedFiles: [FileChange] {
        repo.selectedWorkingTreeFiles(in: files)
    }

    private var allSelected: Bool {
        !files.isEmpty && selectedFiles.count == files.count
    }

    private var selectAllIcon: String {
        if allSelected { return "checkmark.square.fill" }
        return selectedFiles.isEmpty ? "square" : "minus.square.fill"
    }

    private var batchActionLabel: String {
        let count = selectedFiles.count
        if count == 0 || count == files.count { return bulkTitle }
        return "\(actionTitle) \(count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(title) (\(files.count))")
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(files.count)))
                    .animation(.easeOut(duration: 0.2), value: files.count)
                Spacer()
                if !files.isEmpty {
                    Button {
                        if allSelected {
                            repo.clearFileSelection(in: files)
                            focusedFileID = nil
                        } else {
                            focusedFileID = repo.selectAllFiles(in: files)?.id
                        }
                    } label: {
                        Image(systemName: selectAllIcon)
                            .zoomFont(12)
                            .frame(width: 18 * zoom, height: 18 * zoom)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressEffect)
                    .foregroundStyle(
                        selectedFiles.isEmpty ? Color.secondary : Color.accentColor
                    )
                    .help(allSelected ? "Clear selection" : "Select all \(title.lowercased())")
                    .accessibilityLabel(allSelected ? "Clear selection" : "Select all")

                    Button(batchActionLabel) {
                        let selection = selectedFiles
                        if selection.isEmpty {
                            bulkAction()
                        } else {
                            batchAction(selection)
                        }
                    }
                        .buttonStyle(.pressEffect)
                        .zoomFont(11)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if files.isEmpty {
                // One quiet line under the header, not half a panel of
                // void: the empty state names the next step and gets out
                // of the way.
                Text(emptyText)
                    .zoomFont(11)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                let selection = selectedFiles
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: FileListMetrics.spacing * zoom) {
                            ForEach(files) { file in
                                let fileIsSelected = repo.selectedWorkingTreeFileIDs.contains(file.id)
                                FileRow(
                                    file: file,
                                    actionIcon: actionIcon,
                                    actionHelp: selection.count > 1 && fileIsSelected
                                        ? "\(actionTitle) \(selection.count) selected files"
                                        : actionHelp,
                                    isSelected: fileIsSelected,
                                    isFocused: focusedFileID == file.id,
                                    action: {
                                        if selection.count > 1 && fileIsSelected {
                                            batchAction(selection)
                                        } else {
                                            action(file)
                                        }
                                    },
                                    select: {
                                        let modifiers = NSEvent.modifierFlags
                                        focusedFileID = repo.selectFile(
                                            file,
                                            in: files,
                                            extending: modifiers.contains(.shift),
                                            toggling: modifiers.contains(.command)
                                        )?.id
                                    }
                                )
                                .id(file.id)
                                .focusable()
                                .focused($focusedFileID, equals: file.id)
                                .focusEffectDisabled()
                                .onMoveCommand { direction in
                                    let movement: RepoState.FileSelectionDirection?
                                    switch direction {
                                    case .up: movement = .previous
                                    case .down: movement = .next
                                    default: movement = nil
                                    }
                                    guard let movement,
                                          let selected = repo.moveFileSelection(
                                            movement,
                                            extendingSelection: NSEvent.modifierFlags.contains(.shift)
                                          )
                                    else { return }
                                    focusedFileID = selected.id
                                }
                                .onCommand(#selector(NSResponder.selectAll(_:))) {
                                    focusedFileID = repo.selectAllFiles(in: files)?.id
                                }
                                .contextTarget("file:" + file.id, repo)
                                .contextMenu {
                                    FileMenu(file: file, sectionFiles: files, repo: repo)
                                }
                                .padding(
                                    .horizontal,
                                    (FileListMetrics.inset - FileListMetrics.bleed) * zoom
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: focusedFileID) { _, id in
                        guard let id else { return }
                        // With no anchor SwiftUI performs the smallest scroll
                        // needed to reveal the focused row.
                        proxy.scrollTo(id)
                    }
                }
                .frame(maxHeight: contentHeight)
            }
        }
    }
}

/// GitKraken-style right-click menu for a changed file. Staged and
/// unstaged variants differ only in the first block.
struct FileMenu: View {
    let file: FileChange
    let sectionFiles: [FileChange]
    @ObservedObject var repo: RepoState

    private var selectedFiles: [FileChange] {
        guard repo.selectedWorkingTreeFileIDs.contains(file.id) else { return [] }
        return repo.selectedWorkingTreeFiles(in: sectionFiles)
    }

    private func actionLabel(_ verb: String) -> String {
        guard selectedFiles.count > 1 else { return verb }
        return selectedFiles.count == sectionFiles.count
            ? "\(verb) All"
            : "\(verb) \(selectedFiles.count) Selected"
    }

    var body: some View {
        if file.area == .staged {
            Button(actionLabel("Unstage")) {
                if selectedFiles.count > 1 {
                    repo.unstage(selectedFiles)
                } else {
                    repo.unstage(file)
                }
            }
            Button("Unstage and delete file…") { repo.fileToDelete = file }
        } else {
            Button(actionLabel("Stage")) {
                if selectedFiles.count > 1 {
                    repo.stage(selectedFiles)
                } else {
                    repo.stage(file)
                }
            }
            if file.status != "?" {
                // Untracked files have nothing to restore — Delete covers them.
                Button("Discard changes…", role: .destructive) { repo.fileToDiscard = file }
            }
        }
        Menu("Ignore") {
            IgnoreButtons(file: file, repo: repo, local: false)
            Divider()
            // .git/info/exclude — same effect, but private to this
            // clone: nothing to commit, nothing pushed to the team.
            Menu("Ignore for me only") {
                IgnoreButtons(file: file, repo: repo, local: true)
            }
        }
        // The index half of Ignore on its own, for a file that is already
        // covered by an ignore rule — or that the user wants to word the
        // rule for by hand. Untracked files are not in the index to leave.
        if file.status != "?" {
            Button("Stop tracking…") { repo.fileToUntrack = file }
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
    /// git ignores nothing that is already in the index, so ignoring a
    /// tracked file also has to drop it from the index — a change worth a
    /// confirmation, and worth an ellipsis on the menu item.
    private var tracked: Bool { file.status != "?" }

    var body: some View {
        Button(title("Ignore \"\(file.fileName)\"")) {
            apply(GitIgnore.filePattern(file.path))
        }
        if !ext.isEmpty {
            Button(title("Ignore all \"*.\(ext)\" files")) {
                apply(GitIgnore.extensionPattern(ext))
            }
        }
        if !file.directory.isEmpty {
            Button(title("Ignore everything in \"\(file.directory)\"")) {
                apply(GitIgnore.directoryPattern(file.directory))
            }
        }
    }

    private func title(_ text: String) -> String { tracked ? text + "…" : text }

    private func apply(_ pattern: String) {
        if tracked {
            repo.pendingIgnore = .init(file: file, pattern: pattern, local: local)
        } else {
            repo.ignore(pattern: pattern, local: local)
        }
    }
}

/// The file lists' layout grid, at zoom 1. Shared by the commit panel, the
/// conflict list and the commit-detail list: three lists of the same thing
/// in one window, so they have to keep one rhythm.
enum FileListMetrics {
    /// One row's height. The rows used to declare none, so it fell out of
    /// whichever glyph happened to be tallest — the 13pt stage button —
    /// leaving about 17pt with the filename hard against its neighbours.
    /// 24 is the macOS list row, and it's a click target as well as a line
    /// of text: single click opens the diff, many times a day.
    static let row: CGFloat = 24
    /// How far the selection fill extends past the row's text. A highlight
    /// that stops at the glyphs reads as a box drawn around a word; one
    /// with air in it reads as a selected row.
    static let bleed: CGFloat = 6
    /// Panel edge → row text. `bleed` is taken out of it at the call site,
    /// so filenames still line up under the section title above them.
    static let inset: CGFloat = 12
    /// Between rows. Small on purpose now that each row carries its own
    /// height: the rhythm belongs to the rows, not to the gaps.
    static let spacing: CGFloat = 2
}

struct FileRow: View {
    let file: FileChange
    let actionIcon: String
    let actionHelp: String
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

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
        .padding(.horizontal, FileListMetrics.bleed * zoom)
        .frame(height: FileListMetrics.row * zoom)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Single click opens the diff — a many-times-a-day action, instant.
        .onTapGesture { select() }
    }

    /// Hover gets its own (fainter) fill: with a row this size the pointer
    /// is often between two filenames, and a row that lights up says which
    /// one the click will land on before it lands.
    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}
