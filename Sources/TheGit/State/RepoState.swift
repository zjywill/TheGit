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
    case branchFromStash(Stash)
    case renameRemote(String)

    var id: String {
        switch self {
        case .createBranch(let b): return "create-\(b.name)"
        case .rename(let b): return "rename-\(b.name)"
        case .createBranchAtCommit(let c): return "create-at-\(c.hash)"
        case .tagCommit(let c): return "tag-\(c.hash)"
        case .amendMessage(let c): return "amend-\(c.hash)"
        case .branchFromStash(let s): return "stash-branch-\(s.ref)"
        case .renameRemote(let name): return "rename-remote-\(name)"
        }
    }

    var title: String {
        switch self {
        case .createBranch(let b): return "New branch at \(b.name)"
        case .rename(let b): return "Rename \(b.name)"
        case .createBranchAtCommit(let c): return "New branch at \(c.shortHash)"
        case .tagCommit(let c): return "New tag at \(c.shortHash)"
        case .amendMessage: return "Edit commit message"
        case .branchFromStash(let s): return "New branch from \(s.ref)"
        case .renameRemote(let name): return "Rename remote \(name)"
        }
    }

    var confirmLabel: String {
        switch self {
        case .createBranch, .createBranchAtCommit, .branchFromStash: return "Create"
        case .rename, .renameRemote: return "Rename"
        case .tagCommit: return "Tag"
        case .amendMessage: return "Amend"
        }
    }

    var fieldLabel: String {
        switch self {
        case .tagCommit: return "Tag name"
        case .renameRemote: return "Remote name"
        case .amendMessage: return "Commit message"
        default: return "Branch name"
        }
    }

    /// Extra line under the field, when the action needs explaining.
    var note: String? {
        switch self {
        case .branchFromStash:
            return "Branches off the commit the stash was made on, applies it there, and drops the stash."
        case .renameRemote:
            return "Renames the remote locally and rewrites every branch that tracks it. Nothing changes on the server."
        default: return nil
        }
    }
}

/// A branch delete waiting on confirmation. `includeRemote` is the
/// one-step "delete it everywhere" variant.
struct PendingBranchDelete: Identifiable, Hashable {
    let branch: Branch
    var includeRemote = false
    var id: String { branch.name + (includeRemote ? "+remote" : "") }
}

/// A finished drag, waiting for the user to say what it meant. Dropping is
/// never itself the decision — the menu that follows is.
enum DropIntent: Identifiable {
    case branchOnBranch(source: String, target: String)
    case commitOnBranch(commit: DraggedCommit, target: String)

    var id: String {
        switch self {
        case .branchOnBranch(let s, let t): return "b:\(s)>\(t)"
        case .commitOnBranch(let c, let t): return "c:\(c.hash)>\(t)"
        }
    }

    var target: String {
        switch self {
        case .branchOnBranch(_, let t), .commitOnBranch(_, let t): return t
        }
    }

    var title: String {
        switch self {
        case .branchOnBranch(let source, let target): return "\(source) → \(target)"
        case .commitOnBranch(let commit, let target): return "\(commit.shortHash) → \(target)"
        }
    }
}

/// Observable state for one open repository (one tab).
@MainActor
final class RepoState: ObservableObject, Identifiable {
    let path: String
    let git: GitClient
    let forgeClient: ForgeClient

    enum PanelMode: String, CaseIterable {
        case commit = "Commit"
        case stash = "Stash"
    }

    @Published var snapshot = RepoSnapshot()
    @Published var commitMessage = ""
    @Published var panelMode: PanelMode = .commit
    @Published var searchText = ""
    @Published var amend = false
    @Published var isBusy = false
    /// Separate from `isBusy`: a generation runs for seconds and must not
    /// disable staging or the commit button while it does.
    @Published var isGeneratingMessage = false
    private var generateTask: Task<Void, Never>?
    @Published var errorMessage: String?
    @Published var selectedCommit: String?
    /// Stash highlighted from its graph node; the sidebar row lights up.
    @Published var selectedStashRef: String?
    @Published var branchPrompt: BranchPrompt?
    @Published var promptText = ""
    @Published var branchToDelete: PendingBranchDelete?
    @Published var commitToHardReset: Commit?
    @Published var selectedFile: FileChange?
    @Published var diffLines: [DiffLine] = []
    /// Set when the open diff is an LFS pointer diff: the view shows what
    /// the object is instead of three lines of oid text.
    @Published var lfsPointer: LFSPointerDiff?
    /// "Show pointer text" — the raw diff behind that summary.
    @Published var showRawPointer = false
    /// Raw structure of the current diff, for hunk-level staging.
    private var parsedDiff = ParsedDiff()
    /// Graph visibility filters (GitKraken Solo / Hide). Session-only.
    @Published var soloRev: String?
    @Published var hiddenRefs: Set<String> = []
    /// Expanded sidebar folders, by node id. Lives here rather than in the
    /// row's @State because the sidebar is a LazyVStack: rows that scroll
    /// out of view are destroyed, and with them any state they owned — a
    /// folder would silently re-collapse the moment you scrolled past it.
    @Published var expandedNodes: Set<String> = []

    func toggleExpanded(_ id: String) {
        if expandedNodes.contains(id) { expandedNodes.remove(id) } else { expandedNodes.insert(id) }
    }
    /// History of one file, shown over the graph.
    @Published var fileHistory: (path: String, commits: [Commit])?
    /// Commits loaded so far; grows when the list scrolls to the bottom.
    private var logLimit = 500
    private var loadingMore = false
    /// When non-nil, the diff shown belongs to this commit, not the
    /// working tree (hides stage/unstage in the diff header).
    @Published var diffCommit: String?
    @Published var commitFiles: [FileChange] = []
    @Published var fileToDelete: FileChange?
    @Published var fileToDiscard: FileChange?
    @Published var showAddRemote = false
    @Published var newRemoteName = "origin"
    @Published var newRemoteURL = ""
    @Published var remoteToRemove: String?
    /// Non-nil while the remote sheet is editing an existing remote's URL
    /// rather than adding a new one.
    @Published var editingRemote: String?
    /// A drop that landed and is waiting for the user to pick its meaning.
    @Published var dropIntent: DropIntent?
    /// Row id whose context menu is currently open, so it can be marked.
    @Published var contextTarget: String?
    /// Set once we know the repo's host has a CLI we can drive; nil keeps
    /// the whole pull-request feature invisible.
    @Published var forge: Forge?
    @Published var pullRequests: [PullRequest] = []
    @Published var forgeError: String?
    @Published var loadingPullRequests = false

    nonisolated var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    init(path: String) {
        self.path = path
        self.git = GitClient(repoPath: path)
        self.forgeClient = ForgeClient(repoPath: path)
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
        await detectForge()
        // Coming back to a tab after a while: freshen the PR list, but
        // never on every switch — it's a rate-limited API behind the CLI.
        if forge != nil, let at = prsLoadedAt, Date().timeIntervalSince(at) > 60 {
            await loadPullRequests()
        }
    }

    func refresh(quiet: Bool = false) async {
        if !quiet { isBusy = true }
        defer { if !quiet { isBusy = false } }
        do {
            // Stashes first: their base commits feed the log as extra start
            // points, so a stash taken on a since-rebased branch still has
            // a row in the graph to anchor and locate to.
            let stashList = (try? await git.stashes()) ?? []
            async let commits = git.log(
                limit: logLimit,
                solo: soloRev,
                hiddenPatterns: Array(hiddenRefs),
                extraRevs: stashList.map(\.baseHash).filter { !$0.isEmpty }
            )
            async let branches = git.branches()
            async let worktrees = git.worktrees()
            async let status = git.status()
            async let operation = git.operationState()
            async let submodules = git.submodules()
            async let lfs = git.lfsStatus()
            async let tags = git.tags()

            var snap = RepoSnapshot()
            snap.commits = try await commits
            let s0 = try await status
            // WIP is a synthetic commit whose parent is HEAD: the lane
            // algorithm then routes its line to HEAD's lane correctly,
            // wherever HEAD sits in date-order.
            var layoutCommits = snap.commits
            if !(s0.staged.isEmpty && s0.unstaged.isEmpty && s0.conflicted.isEmpty) {
                let headHash = snap.commits.first { c in
                    c.refs.contains { $0.hasPrefix("HEAD") }
                }?.hash
                let wip = Commit(
                    hash: Commit.wipHash,
                    parents: headHash.map { [$0] } ?? [],
                    author: "",
                    date: Date.distantFuture,
                    refs: [],
                    subject: "// WIP"
                )
                layoutCommits = [wip] + snap.commits
            }
            snap.graphRows = GraphLayout.layout(commits: layoutCommits)
            snap.reachableFromHead = Self.reachableSet(
                from: snap.commits.first { c in c.refs.contains { $0.hasPrefix("HEAD") } }?.hash,
                commits: snap.commits
            )
            // A line is "on the current branch" when it carries a reachable
            // commit or leads to its parents (also reachable by definition).
            var bright: Set<Int> = []
            for row in snap.graphRows
            where row.commit.isWip || snap.reachableFromHead.contains(row.commit.hash) {
                bright.insert(row.columnColor)
                for edge in row.parentLanes { bright.insert(edge.color) }
            }
            snap.brightColors = bright
            let b = try await branches
            snap.localBranches = b.local
            snap.remoteBranches = b.remote
            snap.worktrees = try await worktrees
            snap.submodules = try await submodules
            snap.lfs = await lfs
            snap.stashes = stashList
            snap.stashesByBase = Dictionary(grouping: stashList, by: \.baseHash)
            snap.tags = try await tags
            snap.staged = s0.staged
            snap.unstaged = s0.unstaged
            snap.conflicted = s0.conflicted
            snap.currentBranch = s0.branch
            snap.operation = try await operation
            // Publish only real changes: replacing an identical snapshot
            // still makes List re-diff and visibly nudges the scroll
            // position right after scrolling stops.
            if snap != snapshot { snapshot = snap }
            // Close the diff if its file no longer has changes — but only
            // for working-tree diffs. A commit's diff (diffCommit set) is
            // historical and must survive background refreshes.
            if diffCommit == nil, let file = selectedFile {
                let all = snap.staged + snap.unstaged + snap.conflicted
                if !all.contains(where: { $0.id == file.id }) { closeDiff() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parent-closure of HEAD within the loaded commits.
    nonisolated static func reachableSet(from head: String?, commits: [Commit]) -> Set<String> {
        guard let head else { return [] }
        var parents: [String: [String]] = [:]
        parents.reserveCapacity(commits.count)
        for commit in commits { parents[commit.hash] = commit.parents }
        var seen: Set<String> = [head]
        var queue = [head]
        while let hash = queue.popLast() {
            for parent in parents[hash] ?? [] where seen.insert(parent).inserted {
                queue.append(parent)
            }
        }
        return seen
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
        let amending = amend
        guard !message.isEmpty, amending || !snapshot.staged.isEmpty else { return }
        Task {
            isBusy = true
            do {
                if amending {
                    try await git.commitAmend(message: message)
                    amend = false
                } else {
                    try await git.commit(message: message)
                }
                commitMessage = "" // only clear once the commit actually succeeded
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    // MARK: - AI commit message

    /// Streams a generated message into `commitMessage`. The user's own
    /// draft goes into the prompt as a statement of intent and comes back
    /// if anything fails — nothing they typed is lost to a 401.
    func generateCommitMessage() {
        guard let endpoint = AISettings.shared.endpoint, !isGeneratingMessage else { return }
        let settings = AISettings.shared
        let amending = amend
        let draft = commitMessage
        isGeneratingMessage = true

        generateTask = Task {
            defer {
                isGeneratingMessage = false
                generateTask = nil
            }
            do {
                let stat = try await git.stagedDiff(amend: amending, stat: true)
                let diff = try await git.stagedDiff(amend: amending, stat: false)
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Nothing is staged to describe."
                    return
                }
                let recent = settings.matchRepoStyle
                    ? ((try? await git.recentCommitMessages()) ?? [])
                    : []

                let request = AIRequest(
                    system: CommitMessageGenerator.systemPrompt(
                        style: settings.style,
                        language: settings.language,
                        extra: settings.extraInstructions
                    ),
                    user: CommitMessageGenerator.userPrompt(
                        summary: CommitMessageGenerator.summarize(
                            stat: stat, diff: diff, budget: settings.budget.rawValue
                        ),
                        recentMessages: recent,
                        draft: draft
                    )
                )

                commitMessage = ""
                var answer = ""
                for try await delta in AIClient.stream(request, endpoint: endpoint) {
                    answer += delta
                    commitMessage = CommitMessageGenerator.clean(answer)
                }
                let message = CommitMessageGenerator.clean(answer)
                if message.isEmpty {
                    commitMessage = draft
                    // Cancelling finishes the stream cleanly, so an empty
                    // answer there is the user's doing, not a failure.
                    if !Task.isCancelled { errorMessage = "The model returned nothing." }
                } else {
                    commitMessage = message
                }
            } catch {
                commitMessage = draft
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Stops the stream but keeps whatever already landed in the box.
    func cancelMessageGeneration() { generateTask?.cancel() }

    /// HEAD commit's subject, used to prefill the amend message.
    var headSubject: String? {
        snapshot.commits.first { $0.refs.contains { $0.hasPrefix("HEAD") } }?.subject
    }

    func stashChanges() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            isBusy = true
            do {
                try await git.stashPush(message: message.isEmpty ? nil : message)
                commitMessage = ""
                panelMode = .commit
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
    /// A branch created locally has no upstream, and bare `git push` refuses
    /// to guess one — the toolbar button would fail on every new branch until
    /// the user typed `push -u` by hand. Set the upstream on the first push
    /// instead, the same as the branch menu's "Push to" already does.
    func push() {
        guard let current = snapshot.localBranches.first(where: \.isCurrent),
              current.upstream == nil
        else {
            perform { try await $0.push() }
            return
        }
        let remote = snapshot.defaultRemote
        perform { try await $0.push(remote: remote, branch: current.name, setUpstream: true) }
    }

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

    @Published var stashToDrop: Stash?

    func applyStash(_ stash: Stash) { perform { try await $0.stashApply(stash.ref) } }
    func popStash(_ stash: Stash) { perform { try await $0.stashPop(stash.ref) } }

    func confirmDropStash() {
        guard let stash = stashToDrop else { return }
        stashToDrop = nil
        perform { try await $0.stashDrop(stash.ref) }
    }

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

    func setUpstream(_ branch: Branch, to upstream: String) {
        perform { try await $0.setUpstream(branch.name, to: upstream) }
    }

    func unsetUpstream(_ branch: Branch) {
        perform { try await $0.unsetUpstream(branch.name) }
    }

    // MARK: - Multi-remote

    /// Catch a behind branch up to its upstream without leaving the branch
    /// you're on — the case `git pull` can't cover, because pull only ever
    /// touches HEAD.
    func fastForward(_ branch: Branch) {
        guard let upstream = branch.upstream else { return }
        let remote = remote(for: branch)
        let name = branch.name
        let isCurrent = branch.isCurrent
        perform { git in
            if isCurrent {
                try await git.mergeFastForwardOnly(upstream)
            } else {
                try await git.fastForward(remote: remote, branch: name)
            }
        }
    }

    /// Every local branch that is purely behind its upstream, so the whole
    /// repo can be caught up in one action.
    var fastForwardableBranches: [Branch] {
        snapshot.localBranches.filter {
            $0.upstream != nil && !$0.upstreamGone && $0.behind > 0 && $0.ahead == 0
        }
    }

    func fastForwardAll() {
        let branches = fastForwardableBranches
        guard !branches.isEmpty else { return }
        let current = snapshot.currentBranch
        let targets = branches.map { (name: $0.name, remote: remote(for: $0), upstream: $0.upstream ?? "") }
        perform { git in
            for target in targets {
                // One failure (someone force-pushed) must not stop the rest.
                if target.name == current {
                    try? await git.mergeFastForwardOnly(target.upstream)
                } else {
                    try? await git.fastForward(remote: target.remote, branch: target.name)
                }
            }
        }
    }

    func push(_ branch: Branch, to remote: String) {
        // No upstream yet: set one while pushing, or the next plain Push
        // has nowhere to go.
        let setUpstream = branch.upstream == nil
        perform { try await $0.push(remote: remote, branch: branch.name, setUpstream: setUpstream) }
    }

    func pull(_ branch: Branch, from remote: String) {
        perform { try await $0.pull(remote: remote, branch: branch.name) }
    }

    func pushTag(_ tag: Tag, to remote: String) {
        perform { try await $0.pushTag(tag.name, remote: remote) }
    }

    func promptRenameRemote(_ name: String) {
        promptText = name
        branchPrompt = .renameRemote(name)
    }

    /// Remote-tracking branches offered as upstreams for `branch`, with the
    /// same-named ones first — that's the pick in almost every case.
    func upstreamChoices(for branch: Branch) -> [Branch] {
        snapshot.remoteBranches
            .filter { !$0.name.hasSuffix("/HEAD") }
            .sorted { a, b in
                let aMatch = a.shortName == branch.name
                let bMatch = b.shortName == branch.name
                if aMatch != bMatch { return aMatch }
                return a.name < b.name
            }
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
        case .branchFromStash(let stash):
            perform { try await $0.stashBranch(name, from: stash.ref) }
        case .renameRemote(let old):
            guard old != name else { return }
            perform { try await $0.renameRemote(old, to: name) }
        }
    }

    /// The remote a local branch tracks ("origin/x" -> "origin"), falling
    /// back to the default when nothing is configured.
    func remote(for branch: Branch) -> String {
        guard let upstream = branch.upstream,
              let slash = upstream.firstIndex(of: "/")
        else { return snapshot.defaultRemote }
        return String(upstream[..<slash])
    }

    /// Confirm side of the delete dialog. Local: force delete, optionally
    /// taking the remote branch with it. Remote: push --delete.
    func confirmDelete() {
        guard let pending = branchToDelete else { return }
        branchToDelete = nil
        let branch = pending.branch
        switch branch.kind {
        case .local:
            guard pending.includeRemote else {
                perform { try await $0.deleteLocalBranch(branch.name) }
                return
            }
            let remote = remote(for: branch)
            perform { git in
                // Remote first: it's the half that can fail (no permission,
                // no network). If it does, the local branch is still there
                // and the error means something.
                try await git.deleteRemoteBranch(remote: remote, branch: branch.name)
                try await git.deleteLocalBranch(branch.name)
            }
        case .remote(let remote):
            perform { try await $0.deleteRemoteBranch(remote: remote, branch: branch.shortName) }
        }
    }

    // MARK: - Drag and drop

    /// Both branch-on-branch actions operate on HEAD, so the target has to
    /// be checked out first. The dialog says so before the user commits.
    func needsCheckout(_ intent: DropIntent) -> Bool {
        intent.target != snapshot.currentBranch
    }

    private func withTargetCheckedOut(
        _ target: String,
        _ body: @escaping (GitClient) async throws -> Void
    ) {
        let current = snapshot.currentBranch
        perform { git in
            if target != current { try await git.checkout(branch: target) }
            try await body(git)
        }
    }

    func mergeDropped(source: String, into target: String) {
        dropIntent = nil
        withTargetCheckedOut(target) { try await $0.merge(source) }
    }

    func rebaseDropped(target: String, onto source: String) {
        dropIntent = nil
        withTargetCheckedOut(target) { try await $0.rebase(onto: source) }
    }

    func cherryPickDropped(_ commit: DraggedCommit, onto target: String) {
        dropIntent = nil
        withTargetCheckedOut(target) { try await $0.cherryPick(commit.hash) }
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

    // MARK: - Tags / worktrees / bulk WIP actions

    @Published var tagToDelete: Tag?
    @Published var worktreeToRemove: Worktree?
    @Published var confirmDiscardAll = false

    func checkoutTag(_ tag: Tag) {
        perform { try await $0.checkout(branch: tag.name) }
    }

    func confirmDeleteTag() {
        guard let tag = tagToDelete else { return }
        tagToDelete = nil
        perform { try await $0.deleteTag(tag.name) }
    }

    func pushTag(_ tag: Tag) {
        let remote = snapshot.defaultRemote
        perform { try await $0.pushTag(tag.name, remote: remote) }
    }

    func confirmRemoveWorktree() {
        guard let wt = worktreeToRemove else { return }
        worktreeToRemove = nil
        perform { try await $0.removeWorktree(wt.path) }
    }

    func fetchRemoteOnly(_ name: String) {
        perform { try await $0.fetchRemote(name) }
    }

    func copyRemoteURL(_ name: String) {
        Task {
            do {
                Self.copyToPasteboard(try await git.remoteURL(name))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copyCommitMessage(_ commit: Commit) {
        Task {
            do {
                Self.copyToPasteboard(try await git.commitMessage(commit.hash))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func discardAllChanges() {
        confirmDiscardAll = false
        perform { try await $0.discardAll() }
    }

    // MARK: - Remote management

    func promptAddRemote() {
        editingRemote = nil
        newRemoteName = snapshot.remoteNames.isEmpty ? "origin" : ""
        newRemoteURL = ""
        showAddRemote = true
    }

    /// Same sheet, prefilled: the name is fixed, only the URL is editable.
    func promptEditRemote(_ name: String) {
        editingRemote = name
        newRemoteName = name
        newRemoteURL = ""
        showAddRemote = true
        Task {
            let url = (try? await git.remoteURL(name)) ?? ""
            // The user may already be typing by the time this lands.
            if editingRemote == name, newRemoteURL.isEmpty { newRemoteURL = url }
        }
    }

    /// `git remote add` then fetch it so its branches appear right away —
    /// or `set-url` when the sheet is in edit mode.
    func confirmAddRemote() {
        let name = newRemoteName.trimmingCharacters(in: .whitespaces)
        let url = newRemoteURL.trimmingCharacters(in: .whitespaces)
        let editing = editingRemote
        showAddRemote = false
        editingRemote = nil
        guard !name.isEmpty, !url.isEmpty else { return }
        perform { git in
            if let editing {
                try await git.setRemoteURL(editing, url: url)
            } else {
                try await git.addRemote(name: name, url: url)
            }
            try await git.fetch()
        }
    }

    func confirmRemoveRemote() {
        guard let name = remoteToRemove else { return }
        remoteToRemove = nil
        perform { try await $0.removeRemote(name) }
    }

    // MARK: - Git LFS

    /// Hidden entirely when the binary isn't installed, so nothing in the
    /// UI ever offers something that cannot work.
    var lfsAvailable: Bool { GitClient.hasLFS }

    /// True when this exact path is already stored in LFS.
    func isLFSTracked(_ filePath: String) -> Bool {
        snapshot.lfs.files.contains { $0.path == filePath }
    }

    /// Tracked by LFS, but the object itself was never downloaded — the
    /// working tree holds the pointer, not the file.
    func isLFSObjectMissing(_ filePath: String) -> Bool {
        snapshot.lfsMissing.contains { $0.path == filePath }
    }

    /// Write the pattern into `.gitattributes` and, for a file git already
    /// tracks, rewrite its index entry as a pointer — otherwise nothing
    /// visibly happens until the file is next edited.
    func trackWithLFS(_ file: FileChange, pattern: String) {
        let alreadyTracked = file.status != "?"
        perform { git in
            try await git.lfsTrack(pattern)
            if alreadyTracked { try await git.lfsRenormalize(file.path) }
        }
    }

    func pullLFSObjects() {
        perform { try await $0.lfsPull() }
    }

    // MARK: - Submodule management

    @Published var showAddSubmodule = false
    @Published var newSubmoduleURL = ""
    @Published var newSubmodulePath = ""
    @Published var submoduleToRemove: Submodule?

    func promptAddSubmodule() {
        newSubmoduleURL = ""
        newSubmodulePath = ""
        showAddSubmodule = true
    }

    /// The folder git itself would clone into: the URL's last component
    /// minus `.git`. The sheet fills the path field with it while the user
    /// types the URL, and stops as soon as they edit the path themselves.
    static func defaultSubmodulePath(for url: String) -> String {
        var name = url.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("/") { name.removeLast() }
        // scp-style "git@host:owner/repo.git" separates on ':' as well as '/'.
        name = name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    func confirmAddSubmodule() {
        let url = newSubmoduleURL.trimmingCharacters(in: .whitespaces)
        var destination = newSubmodulePath.trimmingCharacters(in: .whitespaces)
        if destination.isEmpty { destination = Self.defaultSubmodulePath(for: url) }
        showAddSubmodule = false
        guard !url.isEmpty, !destination.isEmpty else { return }
        perform { try await $0.addSubmodule(url: url, path: destination) }
    }

    /// `purgeLocalClone` also deletes `.git/modules/<path>`: it drops any
    /// commit made inside the submodule that was never pushed, and it is
    /// the only way to later add a submodule at that same path again.
    func confirmRemoveSubmodule(purgeLocalClone: Bool) {
        guard let sub = submoduleToRemove else { return }
        submoduleToRemove = nil
        perform { try await $0.removeSubmodule(sub.path, purgeGitDir: purgeLocalClone) }
    }

    // MARK: - Pull requests (gh / glab)

    private var forgeDetected = false
    private var prsLoadedAt: Date?

    /// One-shot: the remote host decides the CLI, and the CLI has to be
    /// installed. Nothing here is shown or logged when it comes back nil.
    private func detectForge() async {
        guard !forgeDetected, forge == nil else { return }
        guard !snapshot.remoteNames.isEmpty else { return } // no remote yet — try again later
        forgeDetected = true
        guard let url = try? await git.remoteURL(snapshot.defaultRemote),
              let found = ForgeClient.detect(remoteURL: url)
        else { return }
        forge = found
        await loadPullRequests()
    }

    func loadPullRequests() async {
        guard let forge else { return }
        loadingPullRequests = true
        defer { loadingPullRequests = false }
        do {
            pullRequests = try await forgeClient.pullRequests(forge)
            forgeError = nil
        } catch {
            pullRequests = []
            forgeError = forgeFailure(error)
        }
        prsLoadedAt = Date()
    }

    func refreshPullRequests() {
        Task { await loadPullRequests() }
    }

    /// `gh pr checkout` moves HEAD, so it refreshes like any git mutation.
    func checkoutPullRequest(_ pr: PullRequest) {
        guard let forge else { return }
        Task {
            isBusy = true
            do {
                try await forgeClient.checkout(pr, forge: forge)
            } catch {
                errorMessage = forgeFailure(error)
            }
            await refresh()
        }
    }

    func openPullRequestInBrowser(_ pr: PullRequest) {
        guard let forge else { return }
        Task {
            do {
                try await forgeClient.openInBrowser(pr, forge: forge)
            } catch {
                errorMessage = forgeFailure(error)
            }
        }
    }

    /// Opens the forge's compose form in the browser — the actual "create"
    /// click stays with the user, and we don't rebuild their form.
    func createPullRequest(from branch: Branch) {
        guard let forge else { return }
        let name = branch.shortName
        Task {
            do {
                try await forgeClient.createPullRequest(branch: name, forge: forge)
            } catch {
                errorMessage = forgeFailure(error)
            }
        }
    }

    /// The one CLI failure worth explaining: not logged in.
    private func forgeFailure(_ error: Error) -> String {
        let text = error.localizedDescription
        guard let forge else { return text }
        let lowered = text.lowercased()
        guard lowered.contains("auth") || lowered.contains("log in")
            || lowered.contains("token") || lowered.contains("credential")
        else { return text }
        return text + "\n\nRun `\(forge.loginHint)` in a terminal, then refresh."
    }

    // MARK: - Clean up

    /// A branch we deleted and can put back, because we kept its tip.
    struct UndoableDelete: Identifiable, Hashable {
        let name: String
        let tip: String
        var id: String { name }
    }

    @Published var showCleanup = false
    @Published var cleanupCandidates: [CleanupCandidate] = []
    @Published var scanningCleanup = false
    @Published var cleanupError: String?
    @Published var candidateToConfirm: CleanupCandidate?
    @Published var cleanupUndo: [UndoableDelete] = []

    func openCleanup() {
        showCleanup = true
        cleanupUndo = []
        Task { await scanCleanup() }
    }

    func scanCleanup() async {
        scanningCleanup = true
        cleanupError = nil
        defer { scanningCleanup = false }
        do {
            cleanupCandidates = try await findCleanupCandidates()
        } catch {
            cleanupCandidates = []
            cleanupError = error.localizedDescription
        }
    }

    /// Four signals, strongest first: the forge says the PR was merged;
    /// git says the tip is an ancestor; the squash probe says the work is
    /// already upstream; the upstream branch is gone. Anything else is
    /// left alone — a branch we can't explain is not a candidate.
    private func findCleanupCandidates() async throws -> [CleanupCandidate] {
        let base = await git.defaultBranch(remote: snapshot.defaultRemote)
        let merged = (try? await git.mergedBranches(into: base)) ?? []
        // Best effort: the whole scan still works offline or without a CLI.
        var mergedPRs: [String: Int] = [:]
        if let forge {
            mergedPRs = (try? await forgeClient.mergedBranches(forge)) ?? [:]
        }
        // A branch checked out in a worktree can't be deleted; its worktree
        // is the candidate instead, and the branch shows up on the rescan.
        let checkedOut = Set(snapshot.worktrees.compactMap(\.branch))

        let candidates = snapshot.localBranches.filter {
            $0.name != base && !$0.isCurrent && !checkedOut.contains($0.name)
        }
        var worktreeBranches: [String: Worktree] = [:]
        for worktree in snapshot.worktrees
        where !worktree.locked && !worktree.prunable {
            if let branch = worktree.branch, branch != base {
                worktreeBranches[branch] = worktree
            }
        }

        // Anything the cheap signals can explain never needs the probe.
        var reasons: [String: CleanupCandidate.Reason] = [:]
        var needProbe: [Branch] = []
        for branch in candidates + worktreeBranches.keys.map({
            Branch(name: $0, kind: .local, isCurrent: false)
        }) {
            if let number = mergedPRs[branch.name] {
                reasons[branch.name] = .mergedPullRequest(
                    number: number, prefix: forge?.numberPrefix ?? "#"
                )
            } else if merged.contains(branch.name) {
                reasons[branch.name] = .merged(into: base)
            } else {
                needProbe.append(branch)
            }
        }
        for name in await squashMerged(needProbe.map(\.name), into: base) {
            reasons[name] = .squashMerged(into: base)
        }

        var found: [CleanupCandidate] = []
        for branch in candidates {
            guard let reason = reasons[branch.name]
                ?? (branch.upstreamGone ? .upstreamGone(branch.upstream ?? "") : nil)
            else { continue }
            var candidate = CleanupCandidate(
                target: .branch(name: branch.name, tip: branch.tipHash),
                reason: reason
            )
            // Only an orphaned branch can strand work: the other three
            // reasons all mean the commits are already in base.
            if case .upstreamGone = reason {
                candidate.strandedCommits =
                    (try? await git.countCommits("\(base)..\(branch.name)")) ?? 0
            }
            found.append(candidate)
        }

        for worktree in snapshot.worktrees where !worktree.locked {
            if worktree.prunable {
                found.append(CleanupCandidate(
                    target: .worktree(path: worktree.path, prunable: true),
                    reason: .worktreeGone
                ))
            } else if let branch = worktree.branch, let reason = reasons[branch] {
                found.append(CleanupCandidate(
                    target: .worktree(path: worktree.path, prunable: false),
                    reason: reason
                ))
            }
        }
        return found
    }

    /// Squash-probe many branches at once. Each probe is four git calls, so
    /// doing them one at a time is what made this scan slow; the cap keeps
    /// a 150-branch repo from spawning hundreds of processes at once.
    private func squashMerged(_ names: [String], into base: String) async -> Set<String> {
        guard !names.isEmpty else { return [] }
        let repoPath = path
        return await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            func schedule() {
                guard next < names.count else { return }
                let name = names[next]
                next += 1
                group.addTask {
                    (name, await GitClient.isSquashMerged(
                        repoPath: repoPath, branch: name, into: base
                    ))
                }
            }
            for _ in 0..<min(8, names.count) { schedule() }
            var result: Set<String> = []
            while let (name, isSquashed) = await group.next() {
                if isSquashed { result.insert(name) }
                schedule()
            }
            return result
        }
    }

    /// Clean exactly one row. Safe rows come straight here; risky rows land
    /// in `candidateToConfirm` first and arrive after the user says yes.
    func clean(_ candidate: CleanupCandidate) {
        Task {
            var rescan = false
            do {
                switch candidate.target {
                case .branch(let name, let tip):
                    try await git.deleteLocalBranch(name)
                    cleanupUndo.append(UndoableDelete(name: name, tip: tip))
                case .worktree(let path, let prunable):
                    if prunable {
                        try await git.pruneWorktrees()
                    } else {
                        try await git.removeWorktreeIfClean(path)
                    }
                    // Removing a worktree frees its branch for cleanup.
                    rescan = true
                }
            } catch {
                cleanupError = error.localizedDescription
                return
            }
            cleanupError = nil
            withAnimation(.easeOut(duration: 0.16)) {
                if case .worktree(_, true) = candidate.target {
                    // `worktree prune` is all-or-nothing, so every stale
                    // entry just went with it.
                    cleanupCandidates.removeAll {
                        if case .worktree(_, true) = $0.target { return true }
                        return false
                    }
                } else {
                    cleanupCandidates.removeAll { $0.id == candidate.id }
                }
            }
            await refresh(quiet: true)
            if rescan { await scanCleanup() }
        }
    }

    func confirmCleanCandidate() {
        guard let candidate = candidateToConfirm else { return }
        candidateToConfirm = nil
        clean(candidate)
    }

    /// Puts the last deleted branch back at exactly the tip it had.
    func undoLastClean() {
        guard let last = cleanupUndo.popLast() else { return }
        Task {
            do {
                try await git.createBranch(last.name, at: last.tip, checkout: false)
                cleanupError = nil
            } catch {
                cleanupError = error.localizedDescription
            }
            await refresh(quiet: true)
            await scanCleanup()
        }
    }

    // MARK: - File context-menu actions

    func stashFile(_ file: FileChange) {
        perform { try await $0.stashFile(file.path) }
    }

    /// Append a pattern to the repo's root `.gitignore` — or, when `local`
    /// is set, to `.git/info/exclude`, which ignores the file for this
    /// clone only and never shows up in a commit.
    func ignore(pattern: String, local: Bool = false) {
        Task {
            do {
                let url: URL
                if local {
                    url = URL(fileURLWithPath: try await git.excludeFilePath())
                    // A repo cloned with an older git may have no info/ dir.
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                } else {
                    url = URL(fileURLWithPath: path + "/.gitignore")
                }
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                // nil means the pattern is already there — nothing to write.
                if let updated = GitIgnore.append(pattern, to: content) {
                    try updated.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh(quiet: true)
        }
    }

    func openFile(_ file: FileChange) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path + "/" + file.path))
    }

    func showInFinder(_ file: FileChange) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path + "/" + file.path)])
    }

    func copyFilePath(_ file: FileChange) {
        Self.copyToPasteboard(path + "/" + file.path)
    }

    /// git diff for one file → .patch via save panel.
    func savePatch(forFile file: FileChange) {
        Task {
            do {
                let patch = try await git.diff(path: file.path, staged: file.area == .staged)
                guard !patch.isEmpty else {
                    errorMessage = "No textual changes to export for \(file.fileName)."
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.fileName + ".patch"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try patch.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Confirmed from the discard dialog: restore the file to its HEAD
    /// state, dropping unstaged edits (git restore).
    func confirmDiscardFile() {
        guard let file = fileToDiscard else { return }
        fileToDiscard = nil
        perform { try await $0.run(["restore", "--", file.path]) }
    }

    /// Confirmed from the delete dialog: unstage if needed, then remove
    /// the file from disk.
    func confirmDeleteFile() {
        guard let file = fileToDelete else { return }
        fileToDelete = nil
        perform { [path] git in
            if file.area == .staged {
                try await git.unstage(file.path)
            }
            try FileManager.default.removeItem(atPath: path + "/" + file.path)
        }
    }

    // MARK: - Commit details

    var selectedCommitObject: Commit? {
        selectedCommit.flatMap { hash in snapshot.commits.first { $0.hash == hash } }
    }

    /// Called when the graph selection changes.
    func commitSelectionChanged() {
        if diffCommit != nil { closeDiff() }
        commitFiles = []
        guard let hash = selectedCommit else { return }
        Task {
            do {
                let files = try await git.commitFiles(hash)
                // Selection may have moved on while we loaded.
                if selectedCommit == hash { commitFiles = files }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectCommitFile(_ file: FileChange) {
        guard let hash = selectedCommit else { return }
        selectedFile = file
        diffCommit = hash
        diffLines = []
        lfsPointer = nil
        Task {
            do {
                let text = try await git.commitFileDiff(hash, path: file.path)
                lfsPointer = LFSParsers.pointerDiff(text)
                let parsed = DiffParser.parse(text)
                parsedDiff = parsed
                diffLines = parsed.lines
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Graph scroll request (commit hash); consumed by GraphView.
    @Published var scrollTarget: String?

    /// Select a commit and scroll the graph to it. If it's deeper than the
    /// loaded window, extend the window far enough first.
    func locate(_ hash: String) {
        guard !hash.isEmpty else { return }
        if snapshot.commits.contains(where: { $0.hash == hash }) {
            selectedCommit = hash
            scrollTarget = hash
            return
        }
        Task {
            // Rough depth: commits (on any ref) newer than the target.
            let out = try? await git.run(["rev-list", "--count", "--all", "^\(hash)"])
            let depth = Int(out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? logLimit
            logLimit = max(logLimit, depth + 100)
            await refresh(quiet: true)
            if snapshot.commits.contains(where: { $0.hash == hash }) {
                selectedCommit = hash
                scrollTarget = hash
            }
        }
    }

    // MARK: - Lazy loading

    /// Called when the last graph row appears; extends the log window.
    func loadMoreIfNeeded(_ row: GraphRow) {
        guard row.id == snapshot.graphRows.last?.id,
              snapshot.commits.count >= logLimit,
              !loadingMore
        else { return }
        loadingMore = true
        logLimit += 500
        Task {
            await refresh(quiet: true)
            loadingMore = false
        }
    }

    // MARK: - Solo / Hide

    func toggleSolo(_ branch: Branch) {
        soloRev = soloRev == branch.name ? nil : branch.name
        Task { await refresh(quiet: true) }
    }

    func toggleHidden(_ branch: Branch) {
        if hiddenRefs.contains(branch.refPath) {
            hiddenRefs.remove(branch.refPath)
        } else {
            hiddenRefs.insert(branch.refPath)
        }
        Task { await refresh(quiet: true) }
    }

    // MARK: - File history

    func showFileHistory(_ path: String) {
        Task {
            do {
                fileHistory = (path, try await git.fileHistory(path))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeFileHistory() {
        fileHistory = nil
    }

    /// From the history list: show this file's diff within that commit.
    func selectHistoryEntry(_ commit: Commit, path filePath: String) {
        selectedCommit = commit.hash
        selectedFile = FileChange(path: filePath, status: "M", area: .unstaged)
        diffCommit = commit.hash
        diffLines = []
        lfsPointer = nil
        Task {
            do {
                let text = try await git.commitFileDiff(commit.hash, path: filePath)
                lfsPointer = LFSParsers.pointerDiff(text)
                let parsed = DiffParser.parse(text)
                parsedDiff = parsed
                diffLines = parsed.lines
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Diff view

    func selectFile(_ file: FileChange) {
        selectedFile = file
        diffCommit = nil
        diffLines = []
        lfsPointer = nil
        Task {
            do {
                let parsed: ParsedDiff
                if file.status == "?" {
                    let content = (try? String(contentsOfFile: path + "/" + file.path, encoding: .utf8)) ?? ""
                    parsed = DiffParser.synthesizeAdded(content)
                } else {
                    let text = try await git.diff(path: file.path, staged: file.area == .staged)
                    lfsPointer = LFSParsers.pointerDiff(text)
                    parsed = DiffParser.parse(text)
                }
                parsedDiff = parsed
                diffLines = parsed.lines
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Stage (or unstage, from the staged view) a single hunk.
    func stageHunk(_ index: Int) {
        guard let file = selectedFile, diffCommit == nil,
              let patch = parsedDiff.patch(forHunk: index)
        else { return }
        let reverse = file.area == .staged
        Task {
            isBusy = true
            do {
                try await git.applyPatch(patch, reverse: reverse)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh(quiet: true)
            // Reload what's left of this file's diff; close when nothing remains.
            let all = snapshot.staged + snapshot.unstaged + snapshot.conflicted
            if all.contains(where: { $0.id == file.id }) {
                selectFile(file)
            } else {
                closeDiff()
            }
            isBusy = false
        }
    }

    func closeDiff() {
        selectedFile = nil
        diffCommit = nil
        diffLines = []
        lfsPointer = nil
        showRawPointer = false
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

    /// Merge a commit rather than a branch — the graph's version of the
    /// branch row's Merge. git takes any commit-ish, and a merge of a bare
    /// sha records it by hash, which is exactly what the row means.
    func merge(_ commit: Commit) {
        perform { try await $0.merge(commit.hash) }
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
