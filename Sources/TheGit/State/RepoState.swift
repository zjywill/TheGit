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
    /// The merge draft last prefilled into `commitMessage`, so it can be
    /// taken back out when the merge ends without it being committed.
    private var mergeDraft: String?
    @Published var panelMode: PanelMode = .commit
    @Published var searchText = ""
    @Published var amend = false
    @Published var isBusy = false
    /// Separate from `isBusy`: a generation runs for seconds and must not
    /// disable staging or the commit button while it does.
    @Published var isGeneratingMessage = false
    private var generateTask: Task<Void, Never>?
    /// Set when a commit or stash consumed the draft while a generation
    /// was still in flight. A stream can look finished in the box while
    /// the task waits on the final SSE frame; committing in that window
    /// used to let the task's epilogue refill the just-cleared box with
    /// the message that was already pushed. Once discarded, nothing from
    /// that task may touch `commitMessage` again.
    private var discardGeneration = false

    /// Cancel an in-flight generation *and* disown its result — unlike
    /// the user's own cancel, which keeps whatever already streamed in.
    private func abandonMessageGeneration() {
        guard generateTask != nil else { return }
        discardGeneration = true
        generateTask?.cancel()
    }
    /// The last failure, shown as a toast over the graph rather than in an
    /// alert in front of it. A dialog for a failed command stops the hands of
    /// someone who has already read it, over news they can only say OK to —
    /// and the refresh loop and the file watcher can raise the same failure
    /// again a second later, which stacks dialogs on top of each other.
    @Published var errorNotice: ErrorNotice?

    /// The string way in, for the failures we word ourselves. Reads back the
    /// verbatim text, so `errorMessage == nil` still means "nothing failed".
    var errorMessage: String? {
        get { errorNotice?.detail }
        set { errorNotice = newValue.map(ErrorNotice.init(text:)) }
    }

    /// The way in for a thrown failure: `GitError` knows which command it
    /// was, and the toast can only use that if it isn't already glued to the
    /// front of the message.
    func report(_ error: Error) {
        errorNotice = ErrorNotice(error)
    }

    /// Loading the commit's file list hangs off the property itself rather
    /// than off an .onChange in the view: the commit pane is shared between
    /// tabs now, so a view-level observer also fires when the *repo* under
    /// it changes — and would close a diff the other tab had left open.
    @Published var selectedCommit: String? {
        didSet {
            if oldValue != selectedCommit {
                commitSelectionChanged()
                updateLineage()
            }
        }
    }

    /// Lineage of the selected commit — its ancestors and descendants
    /// within the loaded window, itself included. While non-nil, the graph
    /// dims everything outside it, so "did this fix make the release?" is
    /// answered by a click. Nil when nothing is selected.
    @Published private(set) var lineageSet: Set<String>?
    /// Branch-line color ids that connect lineage commits: a line stays
    /// bright only where it actually carries the selected commit's history.
    @Published private(set) var lineageColors: Set<Int>?

    /// Recompute the lineage sets for the current selection. Called on
    /// selection changes and after every graph rebuild — rows (and their
    /// color ids) are new objects after a refresh.
    func updateLineage() {
        guard let sel = selectedCommit,
              snapshot.graphRows.contains(where: { $0.commit.hash == sel })
        else {
            if lineageSet != nil { lineageSet = nil; lineageColors = nil }
            return
        }
        // Includes the synthetic rows (WIP, stashes): they carry real
        // parent links, so a stash taken on a lineage commit stays bright.
        let commits = snapshot.graphRows.map(\.commit)
        var parents: [String: [String]] = [:]
        var children: [String: [String]] = [:]
        parents.reserveCapacity(commits.count)
        for c in commits {
            parents[c.hash] = c.parents
            for p in c.parents { children[p, default: []].append(c.hash) }
        }
        var set: Set<String> = [sel]
        var queue = [sel]
        while let h = queue.popLast() {
            for p in parents[h] ?? [] where set.insert(p).inserted { queue.append(p) }
        }
        queue = [sel]
        while let h = queue.popLast() {
            for c in children[h] ?? [] where set.insert(c).inserted { queue.append(c) }
        }
        // A parent-lane edge stays bright only when the parent it leads to
        // is itself in the lineage — color ids alone would keep a shared
        // line bright past the fork where the lineage leaves it.
        var colors: Set<Int> = []
        for row in snapshot.graphRows where set.contains(row.commit.hash) {
            colors.insert(row.columnColor)
            for (i, edge) in row.parentLanes.enumerated()
            where i < row.commit.parents.count && set.contains(row.commit.parents[i]) {
                colors.insert(edge.color)
            }
        }
        lineageSet = set
        lineageColors = colors
    }
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

    /// The branch this repo last auto-revealed in the sidebar, so the
    /// reveal happens once per checkout — a folder the user collapses
    /// afterwards must stay collapsed across background refreshes.
    private var lastRevealedBranch: String?

    /// A current branch living inside collapsed folders ("feature/x/y")
    /// is invisible in the sidebar — expand its ancestor folders whenever
    /// the checked-out branch changes (including the first load).
    private func revealCurrentBranch() {
        guard let name = snapshot.currentBranch, name != lastRevealedBranch else { return }
        lastRevealedBranch = name
        // Folder node ids are cumulative "/"-terminated path prefixes.
        let folders = name.split(separator: "/").dropLast()
        guard !folders.isEmpty else { return }
        var prefix = ""
        for segment in folders {
            prefix += segment + "/"
            expandedNodes.insert(prefix)
        }
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
    /// The host is a forge we know, but its CLI isn't installed. Mutually
    /// exclusive with `forge`; drives the sidebar's install hint.
    @Published var missingForgeCLI: Forge?
    @Published var pullRequests: [PullRequest] = []
    /// Open issues on the forge, for the Dashboard card's badge. nil until
    /// a fetch succeeds — a repo with issues disabled keeps erroring and
    /// therefore keeps showing nothing, which is right: no feature, no
    /// count. Capped at `ForgeClient.issueCountLimit`.
    @Published private(set) var openIssueCount: Int?
    @Published var forgeError: ForgeFailure?
    /// Set once forge detection has concluded, however it concluded — a
    /// GitHub remote, a missing CLI, a host that is no forge at all. Avatars
    /// wait on this rather than on `forge`, which stays nil in three of
    /// those four outcomes.
    @Published private(set) var forgeChecked = false

    /// Which avatar sources this repo can offer. Telling "not known yet"
    /// apart from "nothing to ask" is the whole point: a lookup that gives
    /// up during the first gives up on the instance holding the answer.
    var avatarForge: AvatarStore.ForgeContext {
        if forge == .gitlab { return .gitlab(repoPath: path) }
        // No remote means no forge — nothing to wait for.
        if forgeChecked || snapshot.remoteNames.isEmpty { return .none }
        return .unknown
    }
    @Published var loadingPullRequests = false
    /// The "New Pull Request" sheet. Its fields live here, CleanupView-style,
    /// so the sheet survives a sidebar rebuild without losing a draft.
    @Published var showCreatePR = false
    @Published var prSource = ""
    @Published var prTarget = ""
    @Published var prTitle = ""
    @Published var prBody = ""
    @Published var prDraft = false
    @Published var isGeneratingPR = false
    @Published var isCreatingPR = false
    /// Errors stay inside the sheet — an alert over a sheet is two layers
    /// of modal for one mistake.
    @Published var prError: String?
    private var prGenerateTask: Task<Void, Never>?

    nonisolated var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    init(path: String) {
        self.path = path
        self.git = GitClient(repoPath: path)
        self.forgeClient = ForgeClient(repoPath: path)
    }

    /// What the Dashboard needs to draw this repo's card, and nothing more.
    ///
    /// Deliberately not the snapshot: the Dashboard shows every open repo at
    /// once, and a full `refresh()` is nine subprocesses each — nine repos
    /// would be eighty processes to draw a wall of cards. This is two, and
    /// only for repos whose tab hasn't been opened yet.
    struct Card: Equatable {
        var branch: String?
        var head: String?
        var ahead = 0
        var behind = 0
        var changed = 0
        var conflicted = 0
        var commits: [Commit] = []

        var isClean: Bool { changed == 0 && conflicted == 0 }

        /// A month without a commit — the point where "quiet" starts to
        /// read as "forgotten" and the card is worth a marker.
        static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

        /// True when HEAD's newest commit is older than `staleAfter`.
        /// A repo with no commits at all isn't stale: brand new is the
        /// opposite of abandoned.
        func isStale(now: Date = Date()) -> Bool {
            guard let newest = commits.first?.date else { return false }
            return now.timeIntervalSince(newest) > Self.staleAfter
        }
    }

    @Published private(set) var card: Card?
    private var cardLoadedAt: Date?

    /// Load (or refresh) the card. Cheap enough to call on every visit to
    /// the Dashboard: a repo whose tab is already open answers from the
    /// snapshot it already has, and everyone else is cached for `freshFor`.
    ///
    /// `force` is the Dashboard's own Refresh: it goes to git for every
    /// repo, including the ones with a snapshot, because the reason to press
    /// it is that something outside the app has changed.
    func loadCard(force: Bool = false) async {
        if !force, let snapshotCard = cardFromSnapshot() {
            card = snapshotCard
            cardLoadedAt = lastRefreshedAt
            return
        }
        if !force, cardLoadedAt.map({ Date().timeIntervalSince($0) < Self.freshFor }) == true {
            return
        }
        // HEAD's own history, not the all-refs log the graph draws: a card
        // answers "where is this repo standing", and a commit from an
        // unrelated branch at the top of it answers something else.
        async let log = git.log(limit: 6, solo: "HEAD")
        async let status = git.status()
        guard let s = try? await status else { return }
        card = Card(
            branch: s.branch,
            head: s.head,
            ahead: s.ahead,
            behind: s.behind,
            changed: Set((s.staged + s.unstaged).map(\.path)).count,
            conflicted: s.conflicted.count,
            commits: (try? await log) ?? []
        )
        cardLoadedAt = Date()
    }

    /// The same card, free, for a repo the user has already visited.
    private func cardFromSnapshot() -> Card? {
        guard !snapshot.commits.isEmpty else { return nil }
        let head = snapshot.headBranch
        return Card(
            branch: snapshot.currentBranch,
            head: snapshot.headHash,
            ahead: head?.ahead ?? 0,
            behind: head?.behind ?? 0,
            changed: Set((snapshot.staged + snapshot.unstaged).map(\.path)).count,
            conflicted: snapshot.conflicted.count,
            // HEAD's line only, taken from rows the graph has already laid
            // out — the snapshot's log spans every ref.
            commits: snapshot.commits
                .filter { !$0.isWip && !$0.isStash && snapshot.reachableFromHead.contains($0.hash) }
                .prefix(6)
                .map { $0 }
        )
    }

    /// How many PRs/MRs the card may claim: nil until a real answer has
    /// come back — 0 must mean "none open", never "haven't looked yet" or
    /// "the last look failed".
    var knownOpenPRCount: Int? {
        guard forge != nil, prsLoadedAt != nil, forgeError == nil else { return nil }
        return pullRequests.count
    }

    /// The card's PR count, from the same list the sidebar shows. Called by
    /// the Dashboard after the cards land, one repo at a time — it's the
    /// only network on that screen, so it goes last and is cached harder
    /// than a tab visit (`prsFreshFor` vs the sidebar's 60s): a wall of N
    /// repos is N CLI calls against a rate-limited API.
    ///
    /// `force` is the Dashboard's own Refresh, same contract as `loadCard`.
    func loadCardPullRequests(force: Bool = false) async {
        await detectForge()
        guard forge != nil else { return }
        if !force, let at = prsLoadedAt,
           Date().timeIntervalSince(at) < Self.prsFreshFor { return }
        await loadPullRequests()
    }

    private static let prsFreshFor: TimeInterval = 300

    /// A year of this repo's commits per day, for the Dashboard's summed
    /// heatmap. Not the snapshot's histogram: that one covers half a year
    /// (see `ActivityDay.windowWeeks`), and summing a year of one repo with
    /// half a year of the next would draw the difference as a quiet spell
    /// in the older half of the grid.
    ///
    /// Returned rather than published, because the sum belongs to the wall
    /// and not to any one repo — AppState is what holds it. Cached for
    /// `freshFor` like the card is, and for the same reason: coming back to
    /// the Dashboard shouldn't re-read every open repo's year.
    func yearActivity(force: Bool = false) async -> [Int: Int] {
        if !force, let cached = yearActivityCache,
           Date().timeIntervalSince(cached.at) < Self.freshFor {
            return cached.counts
        }
        // A failed read isn't cached — an empty repo answers [:] and means
        // it, a repo that lost its git for a moment doesn't.
        guard let counts = try? await git.activity(weeks: ActivityDay.yearWeeks) else {
            return yearActivityCache?.counts ?? [:]
        }
        yearActivityCache = (counts, Date())
        return counts
    }

    private var yearActivityCache: (counts: [Int: Int], at: Date)?

    private var hasLoaded = false
    /// When the snapshot was last read from git — see `appeared()`.
    private var lastRefreshedAt: Date?
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

    /// A repo is considered current for this long after a refresh. Only
    /// reached when nothing has touched the working tree or .git since —
    /// the watcher resets it on any change.
    private static let freshFor: TimeInterval = 60

    /// Called when the repo tab appears. First time: full load with busy
    /// indicator. Subsequent tab switches show cached data instantly and
    /// only freshen quietly in the background — switching tabs is a
    /// many-times-a-day action and must never flash a spinner.
    func appeared() async {
        startAutoFetch()
        startWatching()
        if hasLoaded {
            // The watcher and the auto-fetch have been live on this repo
            // since its first appearance — whatever tab you were on. A tab
            // you left a moment ago is therefore already current, and
            // re-reading nine git commands on the way in bought nothing but
            // a second full re-layout landing a few hundred ms after the
            // switch: the graph settled, then visibly hitched again.
            if Date().timeIntervalSince(lastRefreshedAt ?? .distantPast) > Self.freshFor {
                await refresh(quiet: true)
            }
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
            // Stashes first, and serially: their base commits feed the log as
            // extra start points, so a stash taken on a since-rebased branch
            // still has a row in the graph to anchor and locate to.
            //
            // Folding this read into the concurrent group below saves ~20ms
            // and costs correctness. It moves `git status` to the very first
            // instant of every refresh, and `git status` takes index.lock to
            // write back its stat cache — so a refresh landing on the same
            // instant as a merge or a stash push makes one of them fail with
            // "Unable to create .git/index.lock". Reproduced as intermittent
            // failures across the merge and stash tests; the serial read is
            // what staggers them apart. The 20ms was on the full refresh,
            // which staging no longer goes through anyway.
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
            async let activity = git.activity()

            var snap = RepoSnapshot()
            snap.commits = try await commits
            // A repo with no commits yet has no histogram and isn't an
            // error — the heatmap simply has nothing to draw.
            snap.activity = (try? await activity) ?? [:]
            let s0 = try await status
            snap.reachableFromHead = Self.reachableSet(
                from: snap.headHash,
                commits: snap.commits
            )
            let g = Self.graph(
                commits: snap.commits,
                headHash: snap.headHash,
                dirty: !(s0.staged.isEmpty && s0.unstaged.isEmpty && s0.conflicted.isEmpty),
                reachable: snap.reachableFromHead,
                stashes: stashList
            )
            snap.graphRows = g.rows
            snap.brightColors = g.bright
            let b = try await branches
            snap.localBranches = b.local
            snap.remoteBranches = b.remote
            snap.worktrees = try await worktrees
            snap.submodules = try await submodules
            snap.lfs = await lfs
            snap.stashes = stashList
            snap.tags = try await tags
            snap.staged = s0.staged
            snap.unstaged = s0.unstaged
            snap.conflicted = s0.conflicted
            snap.currentBranch = s0.branch
            snap.operation = try await operation
            if snap.operation == .merge {
                snap.mergeMessage = try? await git.mergeMessage()
            }
            // Publish only real changes: replacing an identical snapshot
            // still makes List re-diff and visibly nudges the scroll
            // position right after scrolling stops.
            if snap != snapshot { snapshot = snap }
            lastRefreshedAt = Date()
            updateLineage()
            revealCurrentBranch()
            syncMergeDraft()
            // Close the diff if its file no longer has changes — but only
            // for working-tree diffs. A commit's diff (diffCommit set) is
            // historical and must survive background refreshes.
            if diffCommit == nil, let file = selectedFile {
                let all = snap.staged + snap.unstaged + snap.conflicted
                if !all.contains(where: { $0.id == file.id }) { closeDiff() }
            }
        } catch {
            report(error)
        }
    }

    /// GitKraken lands you on git's own prepared message mid-merge instead
    /// of an empty box. Prefill only an untouched box, and take the draft
    /// back out once the merge ends without it being committed — Continue
    /// uses MERGE_MSG directly, and a stale "Merge branch..." left in the
    /// box would head the next unrelated commit.
    private func syncMergeDraft() {
        if snapshot.operation == .merge, let draft = snapshot.mergeCommitDraft {
            if commitMessage.isEmpty {
                commitMessage = draft
                mergeDraft = draft
            }
        } else if let draft = mergeDraft {
            if commitMessage == draft { commitMessage = "" }
            mergeDraft = nil
        }
    }

    /// Re-read only what an index or working-tree change can affect. One
    /// subprocess instead of nine, and no relayout of a 500-commit graph to
    /// move one file between two lists.
    ///
    /// Valid only for actions that touch the index and the working tree and
    /// nothing else — staging, unstaging, hunks, resolving a conflict.
    /// Anything that can move a ref, a stash, a tag, a worktree or a
    /// submodule has to go through the full `refresh()`.
    func refreshStatus() async {
        do {
            let s = try await git.status()
            var snap = snapshot
            snap.staged = s.staged
            snap.unstaged = s.unstaged
            snap.conflicted = s.conflicted
            snap.currentBranch = s.branch
            // The WIP row exists only while the working tree is dirty, so
            // the graph has to be rebuilt exactly when that flips — staging
            // one of five changed files doesn't flip it, and that's the case
            // this path exists for.
            // Read off the file lists, not off the rows: this is the same
            // predicate that decided the layout in the first place, and it
            // doesn't assume where in the row order the WIP node landed.
            let wasDirty = !(
                snapshot.staged.isEmpty
                    && snapshot.unstaged.isEmpty
                    && snapshot.conflicted.isEmpty
            )
            let isDirty = !(s.staged.isEmpty && s.unstaged.isEmpty && s.conflicted.isEmpty)
            if wasDirty != isDirty {
                let g = Self.graph(
                    commits: snap.commits,
                    headHash: snap.headHash,
                    dirty: isDirty,
                    reachable: snap.reachableFromHead,
                    stashes: snap.stashes
                )
                snap.graphRows = g.rows
                snap.brightColors = g.bright
            }
            if snap != snapshot {
                snapshot = snap
                updateLineage()
                revealCurrentBranch()
            }
            if diffCommit == nil, let file = selectedFile {
                let all = snap.staged + snap.unstaged + snap.conflicted
                if !all.contains(where: { $0.id == file.id }) { closeDiff() }
            }
        } catch {
            report(error)
        }
    }

    /// Graph rows and the bright-line set, both derived from the commits and
    /// from whether the working tree is dirty. Shared by the full refresh and
    /// the status-only one so the two can never draw the graph differently.
    nonisolated static func graph(
        commits: [Commit],
        headHash: String?,
        dirty: Bool,
        reachable: Set<String>,
        stashes: [Stash] = []
    ) -> (rows: [GraphRow], bright: Set<Int>) {
        // WIP is a synthetic commit whose parent is HEAD: the lane algorithm
        // then routes its line to HEAD's lane correctly, wherever HEAD sits
        // in date-order.
        var layoutCommits = commits
        if dirty {
            let wip = Commit(
                hash: Commit.wipHash,
                parents: headHash.map { [$0] } ?? [],
                author: "",
                date: Date.distantFuture,
                refs: [],
                subject: "// WIP"
            )
            layoutCommits = [wip] + commits
        }
        // Each stash is a synthetic commit too, inserted directly above its
        // base so its dashed line spans exactly one row — GitKraken's
        // layout. Inserting keeps children-before-parents order intact for
        // the lane algorithm; a stash whose base fell outside the loaded
        // window simply isn't drawn, same as any other unloaded commit.
        if !stashes.isEmpty {
            let byBase = Dictionary(
                grouping: stashes.filter { !$0.baseHash.isEmpty },
                by: \.baseHash
            )
            var withStashes: [Commit] = []
            withStashes.reserveCapacity(layoutCommits.count + stashes.count)
            for commit in layoutCommits {
                // stash list order is stash@{0} first — newest on top.
                for stash in byBase[commit.hash] ?? [] {
                    withStashes.append(Commit(
                        hash: Commit.stashHashPrefix + stash.ref,
                        parents: [stash.baseHash],
                        author: "",
                        date: stash.date,
                        refs: [],
                        subject: stash.message
                    ))
                }
                withStashes.append(commit)
            }
            layoutCommits = withStashes
        }
        let rows = GraphLayout.layout(commits: layoutCommits)
        // A line is "on the current branch" when it carries a reachable
        // commit or leads to its parents (also reachable by definition).
        // Synthetic rows count when what they hang off is reachable: WIP
        // always (its parent is HEAD), a stash when its base is.
        var bright: Set<Int> = []
        for row in rows {
            let onBranch = row.commit.isWip
                || reachable.contains(row.commit.hash)
                || (row.commit.isStash
                    && reachable.contains(row.commit.parents.first ?? ""))
            guard onBranch else { continue }
            bright.insert(row.columnColor)
            for edge in row.parentLanes { bright.insert(edge.color) }
        }
        return (rows, bright)
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

    /// Run a mutating git action, then re-read the repo. When the repo has
    /// submodules, keep them updated after every action (GitKraken's "Keep
    /// submodules up to date" default).
    func perform(_ action: @escaping (GitClient) async throws -> Void) {
        Task {
            isBusy = true
            do {
                try await action(git)
                if !snapshot.submodules.isEmpty {
                    try? await git.updateSubmodules()
                }
            } catch {
                report(error)
            }
            await refresh()
        }
    }

    /// `perform` for actions that only move things in and out of the index.
    /// Three things differ, and all three are the point:
    ///
    /// - `refreshStatus()` instead of `refresh()` — one `git status`.
    /// - No `updateSubmodules()`: staging a file cannot change a submodule,
    ///   and that call is a recursive network-capable command.
    /// - No `isBusy`. The round trip is a few tens of milliseconds; a
    ///   spinner that appears and vanishes inside one frame or two is worse
    ///   than no spinner, and it disables the Commit button as it goes.
    func performIndexOnly(_ action: @escaping (GitClient) async throws -> Void) {
        Task {
            do {
                try await action(git)
            } catch {
                report(error)
            }
            await refreshStatus()
        }
    }

    // MARK: - Convenience actions

    func stage(_ file: FileChange) { performIndexOnly { try await $0.stage(file.path) } }
    func unstage(_ file: FileChange) { performIndexOnly { try await $0.unstage(file.path) } }
    func stageAll() { performIndexOnly { try await $0.stageAll() } }
    func unstageAll() { performIndexOnly { try await $0.unstageAll() } }

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
                abandonMessageGeneration()
                commitMessage = "" // only clear once the commit actually succeeded
            } catch {
                report(error)
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
        discardGeneration = false

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
                    guard !discardGeneration else { return }
                    commitMessage = CommitMessageGenerator.clean(answer)
                }
                // A commit may have consumed the draft while the stream
                // was closing; its message is history now, not a draft.
                guard !discardGeneration else { return }
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
                guard !discardGeneration else { return }
                commitMessage = draft
                report(error)
            }
        }
    }

    /// Stops the stream but keeps whatever already landed in the box.
    func cancelMessageGeneration() { generateTask?.cancel() }

    /// HEAD commit's subject, used to prefill the amend message.
    var headSubject: String? {
        snapshot.commits.first { $0.refs.contains { $0.hasPrefix("HEAD") } }?.subject
    }

    /// The amend checkbox owns the message box: ticking it loads HEAD's
    /// message, unticking it empties the box. Unconditional in both
    /// directions, which is what the checkbox means — "the text below is
    /// the previous commit's" — and it's the only way to ask for that text
    /// back after editing it. Only filling an empty box instead turns a
    /// stray keystroke into a state with no way out.
    func amendChanged(_ amending: Bool) {
        // A stream that's still running would type over whatever we put
        // in the box a second later.
        abandonMessageGeneration()
        guard amending else {
            commitMessage = ""
            return
        }
        // The subject is already in the snapshot, so the box fills on the
        // click rather than a git call later. It's only the first line,
        // though — amending with it would drop the body — so the full
        // message replaces it as soon as it lands.
        let subject = headSubject ?? ""
        commitMessage = subject
        guard let head = snapshot.commits.first(where: { c in
            c.refs.contains { $0.hasPrefix("HEAD") }
        }) else { return }
        Task {
            guard let full = try? await git.commitMessage(head.hash) else { return }
            // Only if nothing has changed under us: the box still holds
            // exactly the stand-in, and amend is still on.
            guard amend, commitMessage == subject else { return }
            commitMessage = full
        }
    }

    /// `paths` empty means the whole working tree. A subset goes through a
    /// pathspec rather than `git stash push --staged`: --staged refuses any
    /// file that has both staged and unstaged changes, and it fails *after*
    /// writing the stash entry, leaving a stash whose changes are still in
    /// the working tree. A pathspec push takes those files whole, which is
    /// what picking them in the panel means anyway.
    func stashChanges(only paths: [String] = []) {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            isBusy = true
            do {
                try await git.stashPush(message: message.isEmpty ? nil : message, paths: paths)
                abandonMessageGeneration()
                commitMessage = ""
                panelMode = .commit
            } catch {
                report(error)
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
    /// Bare `git push` fails in two everyday states, and the toolbar button
    /// has to cover both (the way GitKraken does):
    /// - no upstream (a branch created locally): push and set one.
    /// - upstream named differently (a branch created off origin/main keeps
    ///   tracking it): push.default=simple refuses outright, so push the
    ///   branch under its own name and re-point the tracking there.
    func push() {
        guard let current = snapshot.localBranches.first(where: \.isCurrent) else {
            perform { try await $0.push() }
            return
        }
        if let upstream = current.upstream {
            let remote = remote(for: current)
            let sameName = upstream == "\(remote)/\(current.name)"
            if sameName {
                perform { try await $0.push() }
            } else {
                perform { try await $0.push(remote: remote, branch: current.name, setUpstream: true) }
            }
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
        // Forced: the sidebar's dialog already says the folder and anything
        // uncommitted in it are going.
        perform { try await $0.removeWorktree(wt.path, force: true) }
    }

    func fetchRemoteOnly(_ name: String) {
        perform { try await $0.fetchRemote(name) }
    }

    func copyRemoteURL(_ name: String) {
        Task {
            do {
                Self.copyToPasteboard(try await git.remoteURL(name))
            } catch {
                report(error)
            }
        }
    }

    func copyCommitMessage(_ commit: Commit) {
        Task {
            do {
                Self.copyToPasteboard(try await git.commitMessage(commit.hash))
            } catch {
                report(error)
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
    /// The remote's host, kept so a failure can name the place we couldn't
    /// reach ("gitlab.acme.com") instead of the CLI that failed to reach it.
    private var forgeHost: String?

    /// One-shot: the remote host decides the CLI, and the CLI has to be
    /// installed. Nothing here is shown or logged when it comes back nil.
    private func detectForge() async {
        guard !forgeDetected, forge == nil else { return }
        // The snapshot knows the remotes of a repo whose tab has been
        // opened; the Dashboard asks about repos that never have, so fall
        // back to git's own answer — one subprocess, the same price as the
        // card that's asking.
        var remotes = snapshot.remoteNames
        if remotes.isEmpty { remotes = (try? await git.remotes()) ?? [] }
        guard !remotes.isEmpty else { return } // no remote yet — try again later
        forgeDetected = true
        // `Snapshot.defaultRemote`'s rule, over whichever list answered.
        let defaultRemote = remotes.contains("origin") ? "origin" : remotes[0]
        let url = try? await git.remoteURL(defaultRemote)
        if let url { forgeHost = ForgeParsers.host(of: url) }
        switch url.flatMap({ ForgeClient.detect(remoteURL: $0) }) {
        case .ready(let found):
            forge = found
            missingForgeCLI = nil
        case .missingCLI(let found):
            missingForgeCLI = found
        case nil:
            break
        }
        // Published before the pull-request load, not after: avatars are
        // waiting on this, and they have no business waiting on a network
        // round trip for merge requests.
        forgeChecked = true
        if forge != nil { await loadPullRequests() }
    }

    /// The sidebar's "check again" after the user installs gh/glab: run
    /// detection over from scratch.
    func recheckForgeCLI() {
        guard missingForgeCLI != nil else { return }
        missingForgeCLI = nil
        forgeDetected = false
        Task { await detectForge() }
    }

    /// What tapping the install-hint row does: put the brew one-liner on
    /// the pasteboard, or open the tool's site when there's no brew to
    /// paste it into.
    func forgeInstallHintTapped() {
        guard let missing = missingForgeCLI else { return }
        switch Toolchain.hint(for: missing.cliTool) {
        case .command(let line): Self.copyToPasteboard(line)
        case .website(let url): if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }
    }

    /// Deliberately not animated. Fading the arriving rows in was tried and
    /// reverted: thirty rows appearing is a ~500pt layout change, and inside
    /// an animated transaction every section below (worktrees, tags, stashes)
    /// slides that whole distance and cross-fades through the PR list on the
    /// way. For the length of the animation the sidebar shows two overlapping
    /// versions of itself, which is a worse jolt than the pop it was meant to
    /// soften. The pop is one frame; the reflow was visible.
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
        // The issue count rides along on the PR list's schedule and cache.
        // Its own `try?`, not the `do` above: a repo with issues disabled
        // must not read as "can't reach the forge" when the PRs loaded fine.
        openIssueCount = try? await forgeClient.openIssueCount(forge)
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
                errorMessage = forgeFailure(error).alertText
            }
            await refresh()
        }
    }

    /// The list already carries the web URL, and opening it ourselves is
    /// instant; `gh pr view --web` is only the fallback for a CLI version
    /// that didn't give us one.
    func openPullRequestInBrowser(_ pr: PullRequest) {
        guard let forge else { return }
        if let url = URL(string: pr.url), !pr.url.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            do {
                try await forgeClient.openInBrowser(pr, forge: forge)
            } catch {
                errorMessage = forgeFailure(error).alertText
            }
        }
    }

    /// Opens the compose sheet with sensible branches already picked:
    /// the given branch (or HEAD) against the repo's mainline.
    func createPullRequest(from branch: Branch? = nil) {
        guard forge != nil else { return }
        prSource = branch?.shortName ?? snapshot.currentBranch ?? ""
        prTitle = ""
        prBody = ""
        prDraft = false
        prError = nil
        showCreatePR = true
        Task {
            prTarget = await git.defaultBranch(remote: snapshot.defaultRemote)
            // The obvious degenerate default (main → main): fall back to
            // HEAD so the picker never opens pre-broken.
            if prTarget == prSource, let head = snapshot.currentBranch, head != prSource {
                prSource = head
            }
        }
    }

    /// Streams title and description into the sheet's fields. Whatever the
    /// user already typed rides along as intent, like the commit box does.
    func generatePullRequestMessage() {
        guard let forge, let endpoint = AISettings.shared.endpoint, !isGeneratingPR else { return }
        let settings = AISettings.shared
        let (source, target) = (prSource, prTarget)
        let draft = [prTitle, prBody].filter { !$0.isEmpty }.joined(separator: "\n\n")
        isGeneratingPR = true

        prGenerateTask = Task {
            defer {
                isGeneratingPR = false
                prGenerateTask = nil
            }
            do {
                // Two dots for the log (this branch's commits), three for
                // the diff (against the merge base) — asymmetric on
                // purpose, so target-only commits appear in neither.
                let commits = (try? await git.commitMessages(in: "\(target)..\(source)")) ?? []
                let stat = try await git.rangeDiff("\(target)...\(source)", stat: true)
                let diff = try await git.rangeDiff("\(target)...\(source)", stat: false)
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    prError = "No difference between \(source) and \(target)."
                    return
                }

                var user = PullRequestGenerator.userPrompt(
                    source: source,
                    target: target,
                    commits: commits,
                    summary: CommitMessageGenerator.summarize(
                        stat: stat, diff: diff, budget: settings.budget.rawValue
                    )
                )
                if !draft.isEmpty {
                    user = "The author already started writing this — keep its intent:\n\(draft)\n\n" + user
                }
                let request = AIRequest(
                    system: PullRequestGenerator.systemPrompt(
                        forge: forge,
                        language: settings.language,
                        extra: settings.extraInstructions
                    ),
                    user: user
                )

                prError = nil
                var answer = ""
                for try await delta in AIClient.stream(request, endpoint: endpoint) {
                    answer += delta
                    (prTitle, prBody) = PullRequestGenerator.parse(answer)
                }
                if PullRequestGenerator.parse(answer).title.isEmpty, !Task.isCancelled {
                    prError = "The model returned nothing."
                }
            } catch {
                prError = error.localizedDescription
            }
        }
    }

    func cancelPullRequestGeneration() { prGenerateTask?.cancel() }

    /// Push (the forge can only see what the remote has), create, open the
    /// new page in the browser. The sheet stays up on failure with the
    /// draft intact — a 401 must not eat a written description.
    func submitPullRequest() {
        guard let forge, !isCreatingPR else { return }
        let (source, target) = (prSource, prTarget)
        let title = prTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, source != target else { return }
        isCreatingPR = true

        Task {
            defer { isCreatingPR = false }
            do {
                let remote = snapshot.defaultRemote
                if let branch = snapshot.localBranches.first(where: { $0.name == source }) {
                    if branch.upstream == nil || branch.upstreamGone {
                        try await git.push(remote: remote, branch: source, setUpstream: true)
                    } else if branch.ahead > 0 {
                        try await git.push(remote: remote, branch: source, setUpstream: false)
                    }
                }
                let url = try await forgeClient.createPullRequest(
                    source: source,
                    target: target,
                    title: title,
                    body: prBody,
                    draft: prDraft,
                    forge: forge
                )
                showCreatePR = false
                if let url, let link = URL(string: url) {
                    NSWorkspace.shared.open(link)
                }
                await loadPullRequests()
                await refresh()
            } catch {
                prError = forgeFailure(error).alertText
            }
        }
    }

    /// Raw CLI stderr is a Go networking sentence; the sidebar gets one
    /// plain line out of it and keeps the original for the tooltip.
    private func forgeFailure(_ error: Error) -> ForgeFailure {
        let text = error.localizedDescription
        guard let forge else { return ForgeFailure(summary: text, detail: text) }
        return ForgeFailure.describe(error, forge: forge, host: forgeHost)
    }

    // MARK: - Clean up

    /// A branch we deleted and can put back, because we kept its tip.
    struct UndoableDelete: Identifiable, Hashable {
        let name: String
        let tip: String
        var id: String { name }
    }

    /// One clean, however many rows it covered. Undo works in the units the
    /// user acted in: a batch delete comes back as a batch, not one branch
    /// per click.
    struct CleanBatch: Hashable {
        var deletes: [UndoableDelete]
    }

    /// What a confirm dialog is currently asking about. One case per shape
    /// of question, so the sheet needs exactly one alert — SwiftUI only
    /// honours a single `.alert` per view.
    enum PendingClean: Equatable {
        case single(CleanupCandidate)
        case batch([CleanupCandidate])

        var candidates: [CleanupCandidate] {
            switch self {
            case .single(let candidate): return [candidate]
            case .batch(let candidates): return candidates
            }
        }
    }

    @Published var showCleanup = false
    @Published var cleanupCandidates: [CleanupCandidate] = []
    @Published var scanningCleanup = false
    @Published var cleanupError: String?
    @Published var cleanToConfirm: PendingClean?
    @Published var cleanupUndo: [CleanBatch] = []
    /// Row ids ticked for a batch delete. Ids, not candidates, so a rescan
    /// that returns fresh structs keeps the ticks.
    @Published var cleanupSelection: Set<String> = []
    /// A delete is running. A batch is many git calls, and clicking the
    /// button twice while it works would ask git to delete gone branches.
    @Published var cleaning = false

    var selectedCleanupCandidates: [CleanupCandidate] {
        cleanupCandidates.filter { cleanupSelection.contains($0.id) }
    }

    func openCleanup() {
        showCleanup = true
        cleanupUndo = []
        cleanupSelection = []
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
        // A row that no longer exists must not keep a tick alive — the
        // count on the button has to match what a delete would touch.
        cleanupSelection.formIntersection(cleanupCandidates.map(\.id))
    }

    func toggleCleanupSelection(_ candidate: CleanupCandidate) {
        if cleanupSelection.contains(candidate.id) {
            cleanupSelection.remove(candidate.id)
        } else {
            cleanupSelection.insert(candidate.id)
        }
    }

    func selectAllCleanup(_ selected: Bool) {
        cleanupSelection = selected ? Set(cleanupCandidates.map(\.id)) : []
    }

    /// Batch deletes always ask, even when every row is safe. One click for
    /// twenty rows is exactly the case where the user hasn't read them one
    /// by one, so the dialog is where the stakes get stated.
    func requestClean(_ candidates: [CleanupCandidate]) {
        guard !candidates.isEmpty else { return }
        cleanToConfirm = .batch(candidates)
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
        where !worktree.locked && !worktree.prunable && !worktree.isMain {
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

        // The main worktree is never a candidate: git can't remove it, and
        // offering a row that can only ever fail is worse than no row.
        for worktree in snapshot.worktrees where !worktree.locked && !worktree.isMain {
            if worktree.prunable {
                found.append(CleanupCandidate(
                    target: .worktree(path: worktree.path, prunable: true),
                    reason: .worktreeGone
                ))
            } else if let branch = worktree.branch, let reason = reasons[branch] {
                var candidate = CleanupCandidate(
                    target: .worktree(path: worktree.path, prunable: false),
                    reason: reason
                )
                // Counted here rather than at the click, so the row can name
                // what's at stake before the user decides.
                candidate.dirtyEntries = await GitClient.dirtyEntryCount(at: worktree.path)
                found.append(candidate)
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
    /// in `cleanToConfirm` first and arrive after the user says yes.
    func clean(_ candidate: CleanupCandidate) {
        clean([candidate])
    }

    /// Clean any number of rows in one pass. Worktrees go first — removing
    /// one frees the branch it pinned — and a row that fails never stops
    /// the rows behind it, so a locked worktree can't strand a whole batch.
    func clean(_ candidates: [CleanupCandidate]) {
        guard !candidates.isEmpty, !cleaning else { return }
        cleaning = true
        Task {
            defer { cleaning = false }

            // `worktree prune` is all-or-nothing, so the prunable rows are
            // one git call between them rather than one call each.
            let stale = candidates.filter {
                if case .worktree(_, true) = $0.target { return true }
                return false
            }
            let folders = candidates.filter {
                if case .worktree(_, false) = $0.target { return true }
                return false
            }
            let branches = candidates.filter { !$0.isWorktree }

            var cleaned: Set<String> = []
            var undone: [UndoableDelete] = []
            var failures: [(name: String, message: String)] = []
            var prunedStale = false
            var touchedWorktrees = false

            if !stale.isEmpty {
                do {
                    try await git.pruneWorktrees()
                    prunedStale = true
                    touchedWorktrees = true
                } catch {
                    failures.append((stale[0].name, error.localizedDescription))
                }
            }
            for candidate in folders {
                guard case .worktree(let path, _) = candidate.target else { continue }
                do {
                    // Forced only for the folders the dialog listed as dirty.
                    try await git.removeWorktree(
                        path, force: candidate.dirtyEntries > 0
                    )
                    cleaned.insert(candidate.id)
                    touchedWorktrees = true
                } catch {
                    failures.append((candidate.name, error.localizedDescription))
                }
            }
            for candidate in branches {
                guard case .branch(let name, let tip) = candidate.target else { continue }
                do {
                    try await git.deleteLocalBranch(name)
                    undone.append(UndoableDelete(name: name, tip: tip))
                    cleaned.insert(candidate.id)
                } catch {
                    failures.append((candidate.name, error.localizedDescription))
                }
            }

            if !undone.isEmpty { cleanupUndo.append(CleanBatch(deletes: undone)) }
            // One failure reads as itself; several would overflow the footer,
            // so they collapse to the names and the count.
            cleanupError = failures.isEmpty ? nil
                : failures.count == 1 ? failures[0].message
                : "Couldn't clean \(failures.count) items: "
                    + failures.map(\.name).joined(separator: ", ")

            withAnimation(.easeOut(duration: 0.16)) {
                cleanupCandidates.removeAll { candidate in
                    if cleaned.contains(candidate.id) { return true }
                    // Every stale entry went with the prune, including any
                    // the user left unticked — git offers no finer grain.
                    if prunedStale, case .worktree(_, true) = candidate.target { return true }
                    return false
                }
                cleanupSelection.formIntersection(cleanupCandidates.map(\.id))
            }
            await refresh(quiet: true)
            if touchedWorktrees { await scanCleanup() }
        }
    }

    func confirmPendingClean() {
        guard let pending = cleanToConfirm else { return }
        cleanToConfirm = nil
        clean(pending.candidates)
    }

    /// Puts the branches from the last clean back at exactly the tips they
    /// had — all of them, however many that click deleted.
    func undoLastClean() {
        guard let last = cleanupUndo.popLast() else { return }
        Task {
            var failures: [String] = []
            for delete in last.deletes {
                do {
                    try await git.createBranch(delete.name, at: delete.tip, checkout: false)
                } catch {
                    failures.append(delete.name)
                }
            }
            cleanupError = failures.isEmpty ? nil
                : "Couldn't restore " + failures.joined(separator: ", ")
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
                report(error)
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
                report(error)
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
    private func commitSelectionChanged() {
        if diffCommit != nil { closeDiff() }
        commitFiles = []
        guard let hash = selectedCommit else { return }
        Task {
            do {
                let files = try await git.commitFiles(hash)
                // Selection may have moved on while we loaded.
                if selectedCommit == hash { commitFiles = files }
            } catch {
                report(error)
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
                report(error)
            }
        }
    }

    /// Graph scroll request (commit hash); consumed by GraphView.
    @Published var scrollTarget: String?

    /// How far the graph's lane column has been slid sideways. On the repo
    /// rather than in GraphView because the graph pane is no longer rebuilt
    /// per tab — view-local, it would follow you from one repo into the
    /// next. Here each repo keeps the offset it had when you left it.
    @Published var graphScrollX: CGFloat = 0

    /// Select a commit and scroll the graph to it. If it's deeper than the
    /// loaded window, extend the window far enough first.
    func locate(_ hash: String) {
        guard !hash.isEmpty else { return }
        // A search filters the graph to a flat list, and the commit asked
        // for is usually not in it — the jump would silently do nothing.
        // Asking to go somewhere outranks the filter that hides it.
        searchText = ""
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

    /// Jump the graph back to HEAD — the current branch's tip, or the
    /// commit itself when HEAD is detached.
    func locateHead() {
        if let tip = snapshot.headBranch?.tipHash, !tip.isEmpty {
            locate(tip)
        } else if let head = snapshot.headHash {
            locate(head)
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
                report(error)
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
                report(error)
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
                report(error)
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
            do {
                try await git.applyPatch(patch, reverse: reverse)
            } catch {
                report(error)
            }
            await refreshStatus()
            // Reload what's left of this file's diff; close when nothing remains.
            let all = snapshot.staged + snapshot.unstaged + snapshot.conflicted
            if all.contains(where: { $0.id == file.id }) {
                selectFile(file)
            } else {
                closeDiff()
            }
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

    // All three only write the index and the file on disk. The merge or
    // rebase itself is still in progress either way, so `operationState`
    // cannot have changed — only `status` has.
    func acceptOurs(_ file: FileChange) {
        performIndexOnly { try await $0.acceptSide(file.path, ours: true) }
    }

    func acceptTheirs(_ file: FileChange) {
        performIndexOnly { try await $0.acceptSide(file.path, ours: false) }
    }

    func markResolved(_ file: FileChange) {
        performIndexOnly { try await $0.stage(file.path) }
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
                report(error)
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
                report(error)
            }
        }
    }
}
