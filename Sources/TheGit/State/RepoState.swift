import AppKit
import Foundation
import SwiftUI

/// An action that needs text typed into a dialog first.
enum BranchPrompt: Identifiable {
    case createBranch(from: Branch)
    case rename(Branch)
    case createBranchAtCommit(Commit)
    case tagCommit(Commit)
    case amendMessage(Commit)

    var id: String {
        switch self {
        case .createBranch(let b): return "create-\(b.name)"
        case .rename(let b): return "rename-\(b.name)"
        case .createBranchAtCommit(let c): return "create-at-\(c.hash)"
        case .tagCommit(let c): return "tag-\(c.hash)"
        case .amendMessage(let c): return "amend-\(c.hash)"
        }
    }

    var title: String {
        switch self {
        case .createBranch(let b): return "New branch at \(b.name)"
        case .rename(let b): return "Rename \(b.name)"
        case .createBranchAtCommit(let c): return "New branch at \(c.shortHash)"
        case .tagCommit(let c): return "New tag at \(c.shortHash)"
        case .amendMessage: return "Edit commit message"
        }
    }

    var confirmLabel: String {
        switch self {
        case .createBranch, .createBranchAtCommit: return "Create"
        case .rename: return "Rename"
        case .tagCommit: return "Tag"
        case .amendMessage: return "Amend"
        }
    }

    var fieldLabel: String {
        switch self {
        case .tagCommit: return "Tag name"
        case .amendMessage: return "Commit message"
        default: return "Branch name"
        }
    }
}

/// Observable state for one open repository (one tab).
@MainActor
final class RepoState: ObservableObject, Identifiable {
    let path: String
    let git: GitClient

    @Published var snapshot = RepoSnapshot()
    @Published var commitMessage = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var selectedCommit: String?
    @Published var branchPrompt: BranchPrompt?
    @Published var promptText = ""
    @Published var branchToDelete: Branch?
    @Published var commitToHardReset: Commit?
    @Published var selectedFile: FileChange?
    @Published var diffLines: [DiffLine] = []

    nonisolated var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    init(path: String) {
        self.path = path
        self.git = GitClient(repoPath: path)
    }

    private var hasLoaded = false
    private var autoFetchTask: Task<Void, Never>?
    private var watcher: FSWatcher?
    private var pendingRefresh: Task<Void, Never>?

    deinit {
        autoFetchTask?.cancel()
        pendingRefresh?.cancel()
    }

    /// Watch the repo (working tree + .git) and refresh quietly, debounced.
    /// Editing .gitignore, saving files, or committing from a terminal all
    /// show up within a second — no ⌘R needed.
    private func startWatching() {
        guard watcher == nil else { return }
        watcher = FSWatcher(path: path) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleQuietRefresh() }
        }
    }

    private func scheduleQuietRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            await self.refresh(quiet: true)
        }
    }

    /// Built-in sensible default (no settings UI): quiet auto-fetch with
    /// prune every 5 minutes, like GitKraken's Auto-Fetch Interval.
    private func startAutoFetch() {
        guard autoFetchTask == nil else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !Task.isCancelled else { return }
                try? await self.git.fetch()
                await self.refresh(quiet: true)
            }
        }
    }

    /// Called when the repo tab appears. First time: full load with busy
    /// indicator. Subsequent tab switches show cached data instantly and
    /// only freshen quietly in the background — switching tabs is a
    /// many-times-a-day action and must never flash a spinner.
    func appeared() async {
        startAutoFetch()
        startWatching()
        if hasLoaded {
            await refresh(quiet: true)
        } else {
            hasLoaded = true
            await refresh()
        }
    }

    func refresh(quiet: Bool = false) async {
        if !quiet { isBusy = true }
        defer { if !quiet { isBusy = false } }
        do {
            async let commits = git.log()
            async let branches = git.branches()
            async let worktrees = git.worktrees()
            async let status = git.status()
            async let operation = git.operationState()
            async let submodules = git.submodules()

            var snap = RepoSnapshot()
            snap.commits = try await commits
            snap.graphRows = GraphLayout.layout(commits: snap.commits)
            let b = try await branches
            snap.localBranches = b.local
            snap.remoteBranches = b.remote
            snap.worktrees = try await worktrees
            snap.submodules = try await submodules
            let s = try await status
            snap.staged = s.staged
            snap.unstaged = s.unstaged
            snap.conflicted = s.conflicted
            snap.currentBranch = s.branch
            snap.operation = try await operation
            snapshot = snap
            // Close the diff if its file no longer has changes.
            if let file = selectedFile {
                let all = snap.staged + snap.unstaged + snap.conflicted
                if !all.contains(where: { $0.id == file.id }) { closeDiff() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run a mutating git action, then refresh everything. When the repo
    /// has submodules, keep them updated after every action (GitKraken's
    /// "Keep submodules up to date" default).
    func perform(_ action: @escaping (GitClient) async throws -> Void) {
        Task {
            isBusy = true
            do {
                try await action(git)
                if !snapshot.submodules.isEmpty {
                    try? await git.updateSubmodules()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    // MARK: - Convenience actions

    func stage(_ file: FileChange) { perform { try await $0.stage(file.path) } }
    func unstage(_ file: FileChange) { perform { try await $0.unstage(file.path) } }
    func stageAll() { perform { try await $0.stageAll() } }
    func unstageAll() { perform { try await $0.unstageAll() } }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !snapshot.staged.isEmpty else { return }
        Task {
            isBusy = true
            do {
                try await git.commit(message: message)
                commitMessage = "" // only clear once the commit actually succeeded
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    func checkout(_ branch: Branch) {
        let localExists = snapshot.localBranches.contains { $0.name == branch.shortName }
        perform { git in
            if case .remote = branch.kind {
                try await git.checkoutRemote(branch, localExists: localExists)
            } else {
                try await git.checkout(branch: branch.name)
            }
        }
    }

    /// GitKraken's pull-button default operation choices.
    enum PullMode: String, CaseIterable {
        case fetchAll
        case ff
        case ffOnly
        case rebase

        var title: String {
            switch self {
            case .fetchAll: return "Fetch All"
            case .ff: return "Pull (fast-forward if possible)"
            case .ffOnly: return "Pull (fast-forward only)"
            case .rebase: return "Pull (rebase)"
            }
        }
    }

    func fetch() { perform { try await $0.fetch() } }
    func pull() { perform { try await $0.pull() } }
    func push() { perform { try await $0.push() } }

    func runPull(_ mode: PullMode) {
        switch mode {
        case .fetchAll: perform { try await $0.fetch() }
        case .ff: perform { try await $0.pull() }
        case .ffOnly: perform { try await $0.pull(extraArgs: ["--ff-only"]) }
        case .rebase: perform { try await $0.pull(extraArgs: ["--rebase"]) }
        }
    }

    func stash() { perform { try await $0.stashPush() } }
    func stashPop() { perform { try await $0.stashPop() } }

    func promptNewBranch() {
        guard let current = snapshot.localBranches.first(where: \.isCurrent) else { return }
        promptText = ""
        branchPrompt = .createBranch(from: current)
    }

    // MARK: - Branch context-menu actions

    func merge(_ branch: Branch) {
        perform { try await $0.merge(branch.name) }
    }

    func rebaseOnto(_ branch: Branch) {
        perform { try await $0.rebase(onto: branch.name) }
    }

    func setUpstream(_ branch: Branch) {
        let remote = snapshot.defaultRemote
        perform { try await $0.setUpstream(branch.name, to: "\(remote)/\(branch.name)") }
    }

    func updateSubmodules() {
        perform { try await $0.updateSubmodules() }
    }

    /// Confirm side of the name-input dialog (create branch / rename).
    func confirmPrompt() {
        guard let prompt = branchPrompt else { return }
        let name = promptText.trimmingCharacters(in: .whitespaces)
        branchPrompt = nil
        promptText = ""
        guard !name.isEmpty else { return }
        switch prompt {
        case .createBranch(let from):
            perform { try await $0.createBranch(name, at: from.name, checkout: true) }
        case .rename(let branch):
            perform { try await $0.renameBranch(branch.name, to: name) }
        case .createBranchAtCommit(let commit):
            perform { try await $0.createBranch(name, at: commit.hash, checkout: true) }
        case .tagCommit(let commit):
            perform { try await $0.tag(name, at: commit.hash) }
        case .amendMessage:
            perform { try await $0.amendMessage(name) }
        }
    }

    /// Confirm side of the delete dialog. Local: force delete.
    /// Remote: push --delete on the branch's remote.
    func confirmDelete() {
        guard let branch = branchToDelete else { return }
        branchToDelete = nil
        switch branch.kind {
        case .local:
            perform { try await $0.deleteLocalBranch(branch.name) }
        case .remote(let remote):
            perform { try await $0.deleteRemoteBranch(remote: remote, branch: branch.shortName) }
        }
    }

    /// Pick a folder with NSOpenPanel, then `git worktree add` there.
    func addWorktree(for branch: Branch) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an empty folder for the \(branch.shortName) worktree"
        panel.prompt = "Create Worktree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try await $0.addWorktree(at: url.path, branch: branch.shortName) }
    }

    nonisolated static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Diff view

    func selectFile(_ file: FileChange) {
        selectedFile = file
        diffLines = []
        Task {
            do {
                if file.status == "?" {
                    let content = (try? String(contentsOfFile: path + "/" + file.path, encoding: .utf8)) ?? ""
                    diffLines = DiffParser.synthesizeAdded(content)
                } else {
                    let text = try await git.diff(path: file.path, staged: file.area == .staged)
                    diffLines = DiffParser.parse(text)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeDiff() {
        selectedFile = nil
        diffLines = []
    }

    // MARK: - Conflict resolution

    func acceptOurs(_ file: FileChange) {
        perform { try await $0.acceptSide(file.path, ours: true) }
    }

    func acceptTheirs(_ file: FileChange) {
        perform { try await $0.acceptSide(file.path, ours: false) }
    }

    func markResolved(_ file: FileChange) {
        perform { try await $0.stage(file.path) }
    }

    func continueOperation() {
        guard let op = snapshot.operation else { return }
        perform { try await $0.continueOperation(op) }
    }

    func abortOperation() {
        guard let op = snapshot.operation else { return }
        perform { try await $0.abortOperation(op) }
    }

    // MARK: - Commit context-menu actions

    func checkoutCommit(_ commit: Commit) {
        perform { try await $0.checkout(branch: commit.hash) }
    }

    func cherryPick(_ commit: Commit) {
        perform { try await $0.cherryPick(commit.hash) }
    }

    func revert(_ commit: Commit) {
        perform { try await $0.revert(commit.hash) }
    }

    func rebaseOntoCommit(_ commit: Commit) {
        perform { try await $0.rebase(onto: commit.hash) }
    }

    func reset(to commit: Commit, mode: GitClient.ResetMode) {
        perform { try await $0.reset(to: commit.hash, mode: mode) }
    }

    func confirmHardReset() {
        guard let commit = commitToHardReset else { return }
        commitToHardReset = nil
        reset(to: commit, mode: .hard)
    }

    func addWorktree(atCommit commit: Commit) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an empty folder for the worktree at \(commit.shortHash)"
        panel.prompt = "Create Worktree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try await $0.addWorktree(at: url.path, branch: commit.hash) }
    }

    /// git format-patch → NSSavePanel.
    func savePatch(for commit: Commit) {
        Task {
            do {
                let patch = try await git.formatPatch(commit.hash)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(commit.shortHash).patch"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try patch.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Build a web URL for the commit from origin's URL and copy it.
    /// Handles both https:// and git@host: remote formats.
    func copyRemoteLink(for commit: Commit) {
        Task {
            do {
                var url = try await git.remoteURL(snapshot.defaultRemote)
                if url.hasPrefix("git@"), let colon = url.firstIndex(of: ":") {
                    let host = url[url.index(url.startIndex, offsetBy: 4)..<colon]
                    let path = url[url.index(after: colon)...]
                    url = "https://\(host)/\(path)"
                }
                if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
                Self.copyToPasteboard("\(url)/commit/\(commit.hash)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
