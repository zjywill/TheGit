import SwiftUI

/// The Clean sheet: a review surface first. Opening it does nothing, and
/// the default path is still one row, one click, with the evidence for it
/// sitting right there on the row. Ticking rows trades that row-by-row
/// reading for a single dialog that states the stakes for the whole set,
/// which is why every batch asks even when nothing in it is risky.
struct CleanupView: View {
    @ObservedObject var repo: RepoState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !repo.cleanupCandidates.isEmpty {
                selectionBar
                Divider()
            }
            content
                .frame(minHeight: 140, maxHeight: 340)
            Divider()
            footer
        }
        .frame(width: 520)
        .alert(
            confirmTitle,
            isPresented: Binding(
                get: { repo.cleanToConfirm != nil },
                set: { if !$0 { repo.cleanToConfirm = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { repo.confirmPendingClean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    /// The count matters once a long-lived repo turns up thirty of these —
    /// "Clean" on every row is a lot of clicking to estimate by scrolling.
    private var subtitle: String {
        let count = repo.cleanupCandidates.count
        guard count > 0 else { return "Branches and worktrees this repo is done with." }
        let risky = repo.cleanupCandidates.filter { !$0.isSafe }.count
        let items = "\(count) item\(count == 1 ? "" : "s") to clean"
        return risky == 0 ? items : "\(items) · \(risky) need\(risky == 1 ? "s" : "") a closer look"
    }

    // MARK: - Confirmation

    private var confirmTitle: String {
        switch repo.cleanToConfirm {
        case .single(let candidate):
            return "Delete \(candidate.name)?"
        case .batch(let candidates):
            let count = candidates.count
            let items = "\(count) item\(count == 1 ? "" : "s")"
            // "all" is worth saying only when it's true — it's the reading
            // that carries the most consequence.
            return count == repo.cleanupCandidates.count
                ? "Delete all \(items)?" : "Delete \(items)?"
        case nil:
            return ""
        }
    }

    private var confirmMessage: String {
        switch repo.cleanToConfirm {
        case .single(let candidate):
            if candidate.isWorktree {
                guard candidate.dirtyEntries > 0 else {
                    return "The worktree folder is removed from disk. "
                        + "Nothing in it is uncommitted, and the branch stays."
                }
                return "The worktree folder is removed from disk, along with "
                    + "\(candidate.dirtyEntries) uncommitted "
                    + (candidate.dirtyEntries == 1 ? "change" : "changes")
                    + " that exist nowhere else. This can't be undone."
            }
            return "\(candidate.strandedCommits) commit"
                + (candidate.strandedCommits == 1 ? "" : "s")
                + " exist only on this branch and will be lost. You can undo this from the sheet."
        case .batch(let candidates):
            return batchMessage(candidates)
        case nil:
            return ""
        }
    }

    /// A batch dialog stands in for reading every row, so it has to carry
    /// the same three facts the rows do: what is going, what is lost, and
    /// what touches the disk.
    private func batchMessage(_ candidates: [CleanupCandidate]) -> String {
        let branches = candidates.filter { !$0.isWorktree }
        let folders = candidates.filter {
            if case .worktree(_, false) = $0.target { return true }
            return false
        }
        let worktrees = candidates.count - branches.count
        let stranded = branches.reduce(0) { $0 + $1.strandedCommits }

        var inventory: [String] = []
        if !branches.isEmpty {
            inventory.append("\(branches.count) branch\(branches.count == 1 ? "" : "es")")
        }
        if worktrees > 0 {
            inventory.append("\(worktrees) worktree\(worktrees == 1 ? "" : "s")")
        }

        var parts = [inventory.joined(separator: " and ") + "."]
        if stranded > 0 {
            parts.append(stranded == 1
                ? "1 commit exists only on a branch in this list and will be lost."
                : "\(stranded) commits exist only on branches in this list and will be lost.")
        }
        if !folders.isEmpty {
            let dirty = folders.reduce(0) { $0 + $1.dirtyEntries }
            var line = "\(folders.count) worktree folder"
                + (folders.count == 1 ? " is" : "s are")
                + " removed from disk"
            line += dirty == 0
                ? ", none with uncommitted changes."
                : ", including \(dirty) uncommitted "
                    + (dirty == 1 ? "change" : "changes")
                    + " that can't be undone."
            parts.append(line)
        }
        if !branches.isEmpty {
            parts.append("Deleted branches can be restored with Undo.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up")
                    .zoomFont(14, weight: .semibold)
                Text(subtitle)
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if repo.scanningCleanup {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await repo.scanCleanup() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .zoomFont(11, weight: .semibold)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(Color.accentColor)
                .help("Scan again")
                .disabled(repo.cleaning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Selection bar

    /// Selecting all is a checkbox rather than a button so it sits in the
    /// same column as the row ticks it controls — the tick marks read as
    /// one list from the top down.
    private var selectAll: Binding<Bool> {
        Binding(
            get: {
                !repo.cleanupCandidates.isEmpty
                    && repo.cleanupSelection.count == repo.cleanupCandidates.count
            },
            set: { repo.selectAllCleanup($0) }
        )
    }

    /// One button, not two. "Delete everything" is already "Select all"
    /// followed by this, so a separate Delete All would be a second way to
    /// say the same thing — the label just says which of the two it is.
    /// "All" rather than the number once everything is ticked: at that point
    /// the count is trivia and the scope is the thing worth reading.
    ///
    /// No ellipsis, unlike the rows. There it earns its place by separating
    /// the one-click rows from the ones that ask; here every press asks, so
    /// it would only add noise to a label that already changes as you tick.
    private var deleteLabel: String {
        let count = repo.cleanupSelection.count
        if count == 0 { return "Delete" }
        return count == repo.cleanupCandidates.count ? "Delete All" : "Delete \(count)"
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: selectAll) { Text("Select all") }
                .toggleStyle(.checkbox)
                .zoomFont(11)
            Spacer()
            if repo.cleaning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Button {
                repo.requestClean(repo.selectedCleanupCandidates)
            } label: {
                // The font goes on the label, not the button: controlSize
                // shrinks the chrome but leaves the label at the default
                // 13pt, and anything longer than a word then sits jammed
                // against the border.
                Text(deleteLabel).zoomFont(11)
            }
            .controlSize(.small)
            .disabled(repo.cleanupSelection.isEmpty || repo.cleaning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.12), value: repo.cleanupSelection.count)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if repo.scanningCleanup && repo.cleanupCandidates.isEmpty {
            centered {
                Text("Scanning…")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
            }
        } else if repo.cleanupCandidates.isEmpty {
            centered { allClear }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(repo.cleanupCandidates.enumerated()), id: \.element.id) { index, candidate in
                        CleanupRow(
                            candidate: candidate,
                            index: index,
                            reduceMotion: reduceMotion,
                            isSelected: repo.cleanupSelection.contains(candidate.id),
                            busy: repo.cleaning,
                            onSelect: { repo.toggleCleanupSelection(candidate) }
                        ) {
                            if candidate.isSafe {
                                repo.clean(candidate)
                            } else {
                                repo.cleanToConfirm = .single(candidate)
                            }
                        }
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Reward, not an error state — this is where the user wants to end up.
    private var allClear: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .zoomFont(22, weight: .light)
                .foregroundStyle(.green)
            Text("Nothing to clean")
                .zoomFont(12, weight: .medium)
            Text("Every local branch is either active or unmerged.")
                .zoomFont(11)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    /// Undo covers the last click, so after a batch it has to name the batch
    /// — telling the user one branch comes back when eleven do would be a lie.
    private var undoHelp: String {
        guard let last = repo.cleanupUndo.last else { return "" }
        guard last.deletes.count > 1 else {
            guard let only = last.deletes.first else { return "" }
            return "Recreate \(only.name) at \(String(only.tip.prefix(7)))"
        }
        return "Recreate \(last.deletes.count) branches"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // The safety net shouldn't pop into existence — it fades in the
            // moment the first delete makes it meaningful.
            if repo.cleanupUndo.last != nil {
                Button { repo.undoLastClean() } label: {
                    Text("Undo").zoomFont(11)
                }
                .controlSize(.small)
                .help(undoHelp)
                .disabled(repo.cleaning)
                .transition(.opacity)
            }
            if let error = repo.cleanupError {
                Text(error)
                    .zoomFont(10)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(error)
                    .transition(.opacity)
            }
            Spacer()
            Button("Done") { repo.showCleanup = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.16), value: repo.cleanupUndo.count)
        .animation(.easeOut(duration: 0.16), value: repo.cleanupError)
    }
}

/// One candidate. The reason it's here is on the row; the risk, when there
/// is one, is in orange next to it — so the decision is made before the
/// click, not in a dialog after it.
struct CleanupRow: View {
    let candidate: CleanupCandidate
    let index: Int
    let reduceMotion: Bool
    let isSelected: Bool
    let busy: Bool
    let onSelect: () -> Void
    let action: () -> Void

    @State private var appeared = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onSelect() })) {
                Text("Select \(candidate.name)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(busy)
            // Ticking twenty rows through a 14-point box is fussy, so the
            // label area toggles too. It's its own hit region rather than
            // the whole row: the checkbox and the Clean button keep theirs,
            // and no tap has to be resolved between two handlers.
            HStack(spacing: 8) {
                Image(systemName: candidate.isWorktree ? "folder" : "arrow.triangle.branch")
                    .zoomFont(11)
                    .foregroundStyle(candidate.isSafe ? Color.secondary : .orange)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .zoomFont(12, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(candidate.reasonText)
                            .foregroundStyle(.tertiary)
                        if let risk = candidate.riskText {
                            Text("·").foregroundStyle(.tertiary)
                            Text(risk).foregroundStyle(.orange)
                        }
                    }
                    .zoomFont(10)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !busy { onSelect() } }
            // The ellipsis is the macOS promise that a dialog follows —
            // it tells the user which rows are one-click before they click.
            Button(action: action) {
                Text(candidate.isSafe ? "Clean" : "Clean…").zoomFont(11)
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            Rectangle()
                .fill(Color.primary.opacity(isSelected ? 0.08 : (hovering ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .task {
            // Short staggered entrance, capped so a long list never crawls.
            // Reduced motion drops both the travel and the wait — a delay
            // with no motion to justify it is just a slower app.
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(min(index * 40, 240)))
            }
            withAnimation(.easeOutStrong(reduceMotion ? 0.12 : 0.22)) { appeared = true }
        }
    }
}
