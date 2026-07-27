import SwiftUI

/// The Clean sheet: a review surface, not a batch operation. Opening it
/// does nothing; every deletion is one row, one click, with the evidence
/// for it sitting right there on the row.
struct CleanupView: View {
    @ObservedObject var repo: RepoState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minHeight: 140, maxHeight: 340)
            Divider()
            footer
        }
        .frame(width: 520)
        .alert(
            "Delete \(repo.candidateToConfirm?.name ?? "")?",
            isPresented: Binding(
                get: { repo.candidateToConfirm != nil },
                set: { if !$0 { repo.candidateToConfirm = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { repo.confirmCleanCandidate() }
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

    private var confirmMessage: String {
        guard let candidate = repo.candidateToConfirm else { return "" }
        if candidate.isWorktree {
            return "The worktree folder is removed from disk. "
                + "git refuses if it still has uncommitted changes."
        }
        return "\(candidate.strandedCommits) commit"
            + (candidate.strandedCommits == 1 ? "" : "s")
            + " exist only on this branch and will be lost. You can undo this from the sheet."
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up")
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
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
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(Color.accentColor)
                .help("Scan again")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if repo.scanningCleanup && repo.cleanupCandidates.isEmpty {
            centered {
                Text("Scanning…")
                    .font(.system(size: 12))
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
                            reduceMotion: reduceMotion
                        ) {
                            if candidate.isSafe {
                                repo.clean(candidate)
                            } else {
                                repo.candidateToConfirm = candidate
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
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.green)
            Text("Nothing to clean")
                .font(.system(size: 12, weight: .medium))
            Text("Every local branch is either active or unmerged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // The safety net shouldn't pop into existence — it fades in the
            // moment the first delete makes it meaningful.
            if let last = repo.cleanupUndo.last {
                Button("Undo") { repo.undoLastClean() }
                    .controlSize(.small)
                    .help("Recreate \(last.name) at \(String(last.tip.prefix(7)))")
                    .transition(.opacity)
            }
            if let error = repo.cleanupError {
                Text(error)
                    .font(.system(size: 10))
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
    let action: () -> Void

    @State private var appeared = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.isWorktree ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(candidate.isSafe ? Color.secondary : .orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 10))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The ellipsis is the macOS promise that a dialog follows —
            // it tells the user which rows are one-click before they click.
            Button(candidate.isSafe ? "Clean" : "Clean…", action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            Rectangle()
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
