import SwiftUI

/// The compose sheet for a new PR/MR: pick the branches, let the model
/// draft the words, one click to create — then the browser shows the
/// result. Fields live on RepoState so a sidebar rebuild can't eat a
/// half-written description.
struct CreatePullRequestView: View {
    @ObservedObject var repo: RepoState
    @ObservedObject private var ai = AISettings.shared
    @State private var confirmingSend = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var forge: Forge { repo.forge ?? .github }

    /// Local branches are what you open a PR *from*; the target can also
    /// be a branch that only exists on the remote.
    private var sourceOptions: [String] {
        repo.snapshot.localBranches.map(\.name)
    }

    private var targetOptions: [String] {
        var seen = Set<String>()
        return (repo.snapshot.localBranches.map(\.name)
            + repo.snapshot.remoteBranches.map(\.shortName))
            .filter { seen.insert($0).inserted && $0 != "HEAD" }
    }

    private var canCreate: Bool {
        !repo.prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repo.prSource.isEmpty
            && repo.prSource != repo.prTarget
            && !repo.isCreatingPR
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New \(forge.itemNoun)")
                    .zoomFont(14, weight: .semibold)
                Text("Pushes \(repo.prSource.isEmpty ? "the branch" : repo.prSource) if needed, then opens the new \(forge.itemNoun.lowercased()) in the browser.")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            branchRow
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $repo.prTitle)
                    .textFieldStyle(.roundedBorder)
                    .zoomFont(13)
                    .disabled(repo.isGeneratingPR)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $repo.prBody)
                    .zoomFont(12)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 150, maxHeight: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if repo.prBody.isEmpty {
                            Text("Description (Markdown)")
                                .zoomFont(12)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 11)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(repo.isGeneratingPR)
            }
            HStack(spacing: 8) {
                Toggle("Draft", isOn: $repo.prDraft)
                    .toggleStyle(.checkbox)
                    .zoomFont(12)
                Spacer()
                if ai.isEnabled { generateControls }
            }
        }
        .padding(16)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: repo.isGeneratingPR)
    }

    private var branchRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $repo.prSource) {
                // The selection may not be in the list yet (detached HEAD,
                // freshly renamed branch); an unknown tag makes the Picker
                // render blank, so keep it present.
                if !repo.prSource.isEmpty, !sourceOptions.contains(repo.prSource) {
                    Text(repo.prSource).tag(repo.prSource)
                }
                ForEach(sourceOptions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .zoomFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("", selection: $repo.prTarget) {
                if !repo.prTarget.isEmpty, !targetOptions.contains(repo.prTarget) {
                    Text(repo.prTarget).tag(repo.prTarget)
                }
                ForEach(targetOptions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .disabled(repo.isGeneratingPR || repo.isCreatingPR)
    }

    /// Same ✨ as the commit box, including the one-time "this leaves your
    /// machine" confirmation — the branch diff is no less the user's work
    /// than the staged one.
    @ViewBuilder
    private var generateControls: some View {
        if repo.isGeneratingPR {
            ProgressView()
                .controlSize(.small)
            Button {
                repo.cancelPullRequestGeneration()
            } label: {
                Text("Stop")
                    .zoomFont(11)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
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
                    repo.generatePullRequestMessage()
                } else {
                    confirmingSend = true
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                    Text("Generate")
                }
                .zoomFont(11)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(Color.accentColor)
            .disabled(!ai.isReady || repo.prSource.isEmpty || repo.prSource == repo.prTarget)
            .help(ai.notReadyReason ?? "Write the title and description from the branch's commits and diff")
            .alert(
                "Send this branch's diff to \(ai.provider?.name ?? "the provider")?",
                isPresented: $confirmingSend
            ) {
                Button("Send") {
                    ai.didConfirmSending = true
                    repo.generatePullRequestMessage()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                Generating a description uploads the branch's commit messages and diff — file paths and the changed lines — to \(ai.provider?.name ?? "the provider") at \(ai.baseURL?.host ?? "its endpoint").

                TheGit won't ask again. Turn the feature off in Settings (⌘,) at any time.
                """)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = repo.prError {
                Text(error)
                    .zoomFont(10)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(error)
                    .transition(.opacity)
            }
            Spacer()
            Button("Cancel") {
                repo.cancelPullRequestGeneration()
                repo.showCreatePR = false
            }
            .keyboardShortcut(.escape, modifiers: [])
            if repo.isCreatingPR {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 8)
            }
            Button("Create \(forge.itemNoun)") { repo.submitPullRequest() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: repo.prError)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: repo.isCreatingPR)
    }
}
