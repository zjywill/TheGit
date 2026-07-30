import AppKit
import SwiftUI

/// Top-level state: the repositories the user has added, and which of them
/// currently have a tab.
///
/// Two lists, deliberately. They used to be one, and closing a tab therefore
/// meant forgetting the repository: the path came off the restored list, its
/// card left the Dashboard, and getting back to it was another trip through
/// the open panel. A tab is a window onto a repo, not the record that it
/// exists — so `repos` is the library (persisted, what the Dashboard is a wall
/// of) and `openTabIDs` is the subset with a tab open, in tab order.
@MainActor
final class AppState: ObservableObject {
    /// Every repository the user has added, in the order they were added
    /// (which is the order the Dashboard's wall is laid out in).
    @Published var repos: [RepoState] = []
    /// The repos with a tab, in tab order. Ids, not objects: the tab strip is
    /// a view onto the library, and a second array of references is a second
    /// place for the same repo to be — or to fail to be.
    @Published var openTabIDs: [String] = []
    @Published var activeRepoID: String?
    /// A folder the user tried to open that isn't a git repository.
    @Published var nonGitPath: String?
    /// No usable git on the box (fresh Mac, no Command Line Tools). The
    /// empty state swaps its "open a repo" pitch for an install card while
    /// this is true; a background poll flips it back the moment the
    /// installer finishes.
    @Published var gitMissing = false

    /// The library. Keeps its old name: the build where tabs and library were
    /// the same thing wrote every repo it knew about here, so an upgrade finds
    /// its whole wall waiting.
    static let libraryKey = "TheGit.openRepos"
    /// Which of them had a tab. Absent on that same upgrade, which is why its
    /// default is "all of them" — see `init`.
    static let tabsKey = "TheGit.openTabs"

    /// True while the pointer is over a repo tab or the + button, so the
    /// title-bar double-click monitor leaves those clicks alone.
    static var pointerOverTopControl = false

    /// Hidden-title-bar windows have a dead zone at the top: clicks land in
    /// the hosting view, so neither SwiftUI gestures nor AppKit's native
    /// title-bar zoom ever see a double-click. Handle it at the event level.
    private func installTitleBarDoubleClick() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.styleMask.contains(.titled),
                  let content = window.contentView
            else { return event }

            // Title bar + toolbar + tab bar ≈ top 92 pt.
            let yFromTop = content.bounds.height - event.locationInWindow.y
            guard yFromTop >= 0, yFromTop <= 92 else { return event }
            guard !Self.pointerOverTopControl else { return event }
            if let hit = content.superview?.hitTest(event.locationInWindow),
               hit is NSControl {
                return event // toolbar button etc.
            }

            let pref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            if pref == "Minimize" {
                window.performMiniaturize(nil)
            } else if pref != "None" {
                window.performZoom(nil)
            }
            return nil
        }
    }

    /// The repos with a tab, in tab order — what the tab strip draws.
    /// Resolved from the library rather than stored, so a repo can never be
    /// in a tab and off the wall at the same time.
    var openRepos: [RepoState] {
        openTabIDs.compactMap { id in repos.first { $0.id == id } }
    }

    /// The tab on screen. Only ever a repo with a tab: the Dashboard's cards
    /// now include repos that have none, and clicking one has to open a tab
    /// rather than quietly show a repo the strip doesn't list.
    var activeRepo: RepoState? {
        guard let activeRepoID, openTabIDs.contains(activeRepoID) else { return nil }
        return repos.first { $0.id == activeRepoID }
    }

    /// No repo selected means the Dashboard, which is also where a window
    /// with nothing open lands. One selection, not two pieces of state that
    /// can disagree about what the window is showing — derived from
    /// `activeRepo` so a stale id can't leave the strip highlighting a tab
    /// that isn't there.
    var showingDashboard: Bool { activeRepo == nil }

    func showDashboard() { activeRepoID = nil }

    /// The Dashboard's Refresh: every card straight from git, in the order
    /// they're read in. Sequential for the same reason the first load is —
    /// one wall of cards must not fire twenty subprocesses at once.
    func refreshDashboard() {
        Task {
            for repo in repos { await repo.loadCard(force: true) }
            // After the cards, not with them: the cards are what the user is
            // looking at, and the grid is a year of history that hasn't
            // changed much in the time it took to read them.
            await loadActivity(force: true)
            // Last, because it's the only network in the pass — and forced,
            // because "did that PR land yet" is a reason this button gets
            // pressed.
            for repo in repos { await repo.loadCardPullRequests(force: true) }
        }
    }

    /// Commits per day across every open repository — the Dashboard's
    /// heatmap, which is the one thing on that screen no single card can
    /// say. Empty until the wall has been visited once.
    @Published private(set) var activity: [Int: Int] = [:]
    /// The same, per day, in words: which repositories a day's commits came
    /// from. See `ActivityGraph.detail`.
    @Published private(set) var activityDetail: [Int: String] = [:]
    /// Whether any repo's year has been read yet, so the grid can say it's
    /// reading rather than draw a confident empty year.
    @Published private(set) var activityLoaded = false
    /// The numbers stated beside the grid. Computed here, once per merge,
    /// rather than in the view: it's a walk over a year of days, and a view
    /// that derives it in `body` redoes that walk on every hover of every
    /// one of the grid's cells.
    @Published private(set) var activityStats = ActivityStats(counts: [:])

    /// The year's commits per repository, busiest first, over exactly the
    /// days `activityStats` covers — so the parts add up to the headline.
    ///
    /// This is what the summed grid trades away: one cell can be five repos,
    /// and the tooltips only ever say so one day at a time. Repos with
    /// nothing in the year are left out — a row with no bar on it is a name
    /// taking up space to say nothing.
    @Published private(set) var activityRanking: [RepoActivity] = []

    struct RepoActivity: Identifiable {
        let id: String
        let name: String
        let count: Int
        /// The same year in weekly buckets, oldest first — the shape behind
        /// the number. See `ActivitySparkline`.
        let weeks: [Int]
    }

    /// Kept per repo rather than as a running total, so re-reading one repo
    /// replaces its contribution instead of doubling it, and closing one
    /// takes its cells with it.
    private var activityByRepo: [String: [Int: Int]] = [:]

    /// Read every open repo's year and sum it. Sequential, and merging as
    /// each repo lands, for the reason `loadCard` is: a wall of nine repos
    /// must not fire nine `git log`s at once, and filling in from the top is
    /// also the order they're read in.
    func loadActivity(force: Bool = false) async {
        for repo in repos {
            activityByRepo[repo.id] = await repo.yearActivity(force: force)
            mergeActivity()
        }
    }

    /// Driven by `repos`, never by the cache's own keys: a removed repo drops
    /// out of the grid because it's no longer in the loop, not because
    /// anyone remembered to evict it. Its counts stay in the cache, which is
    /// what makes adding it back instant.
    private func mergeActivity() {
        var total: [Int: Int] = [:]
        var contributors: [Int: [(name: String, count: Int)]] = [:]
        // With one repo open the grid IS that repo, and naming it in every
        // tooltip only restates the count next to it.
        let worthNaming = repos.count > 1
        for repo in repos {
            guard let counts = activityByRepo[repo.id] else { continue }
            for (day, commits) in counts where commits > 0 {
                total[day, default: 0] += commits
                if worthNaming {
                    contributors[day, default: []].append((repo.displayName, commits))
                }
            }
        }
        activity = total
        let window = ActivityStats.windowKeys()
        activityStats = ActivityStats(counts: total, keys: window)
        let ranked = repos.enumerated().compactMap { position, repo -> (Int, RepoActivity)? in
            guard let counts = activityByRepo[repo.id] else { return nil }
            let commits = ActivityStats.total(of: counts, over: window)
            guard commits > 0 else { return nil }
            return (position, RepoActivity(
                id: repo.id,
                name: repo.displayName,
                count: commits,
                weeks: ActivityStats.weeklyTotals(of: counts, over: window)
            ))
        }
        // Busiest first, ties by tab order — `sorted` isn't stable, and a
        // list that reshuffles two equal rows on every refresh reads as data
        // changing when nothing has.
        activityRanking = ranked
            .sorted { ($0.1.count, -$0.0) > ($1.1.count, -$1.0) }
            .map(\.1)
        // Loaded means a repo ON THE WALL has been read, not that the cache
        // has ever held anything: a removed repo's counts stay cached, and a
        // wall of entirely new repos must say "Reading…" rather than claim a
        // confident zero off the back of a repo that isn't even open.
        activityLoaded = repos.contains { activityByRepo[$0.id] != nil }
        // Busiest first, and only the top few: a day that a dozen repos
        // touched is a tooltip too wide to read, and the tail of it is the
        // part nobody came for.
        activityDetail = contributors.mapValues { entries in
            let ranked = entries.sorted { $0.count > $1.count }
            let named = ranked.prefix(3).map { "\($0.name) \($0.count)" }
            let rest = ranked.count - named.count
            return (named + (rest > 0 ? ["+\(rest) more"] : [])).joined(separator: ", ")
        }
    }

    /// The one spelling of a path this app compares, stores and keys by.
    ///
    /// A repo's id IS its path, so "already on the wall" is a string
    /// comparison — and one working copy has more than one spelling. `/tmp`
    /// and `/var` are symlinks into `/private` on every Mac, `~` isn't a real
    /// directory, and a trailing slash is free to appear. The two callers of
    /// `open(path:)` disagree by construction: the open panel hands over what
    /// the user picked, while the sidebar's worktrees and submodules come from
    /// git, which always answers with the real path. Left uncanonicalized,
    /// `/tmp/x` and `/private/tmp/x` became two cards, two tabs and two file
    /// watchers over the same files, neither seeing the other's refreshes.
    ///
    /// Which of the two spellings wins doesn't matter, only that everything
    /// picks the same one: Foundation resolves symlinks and drops a leading
    /// `/private`, so both of those land on `/tmp/x`. Same call git's own paths
    /// go through — see `GitClient.resolved`.
    static func canonical(path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .path
    }

    init() {
        installTitleBarDoubleClick()
        let saved = UserDefaults.standard.stringArray(forKey: Self.libraryKey) ?? []
        // Canonicalized on the way in, which also folds any pair of spellings
        // an older build saved as two separate repos back into one. First
        // spelling wins: the wall keeps the order it had.
        var seen = Set<String>()
        for path in saved.map({ Self.canonical(path: $0) })
        where seen.insert(path).inserted
            && FileManager.default.fileExists(atPath: path + "/.git") {
            repos.append(RepoState(path: path))
        }
        // No tab list at all is the upgrade from the build where a tab WAS the
        // repo: everything it restored was a tab, so keep them as tabs rather
        // than reopening to a wall of cards and no tabs.
        let savedTabs = UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? saved
        let known = Set(repos.map(\.id))
        // Filtered from the saved order, not from the library's: the tab strip
        // has an order of its own and the user dragged it into place. Deduped
        // for the same reason the library is — two spellings of one repo were
        // two tabs, and they collapse into the first of them.
        var seenTabs = Set<String>()
        openTabIDs = savedTabs
            .map { Self.canonical(path: $0) }
            .filter { known.contains($0) && seenTabs.insert($0).inserted }
        activeRepoID = openTabIDs.first
        // The folding above can leave what's on disk out of date, and the next
        // write is whenever the user next opens or closes something.
        persist()
        Task { await watchForGit() }
    }

    /// One probe at launch; while git is missing, keep watching. The CLT
    /// installer runs out of process and tells us nothing, so a filesystem
    /// poll (a handful of stats every few seconds) is the completion
    /// signal — the card dismisses itself, no "recheck" button to find.
    private func watchForGit() async {
        guard Toolchain.installedGit() == nil else { return }
        gitMissing = true
        while Toolchain.installedGit() == nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        gitMissing = false
        // Any repos restored before git arrived sat there erroring; wake them
        // now that their commands can actually run. A full refresh only for
        // the ones with a tab — the rest are cards, and a card is two
        // subprocesses where a snapshot is nine.
        for repo in openRepos {
            Task { await repo.refresh() }
        }
        Task {
            for repo in repos where !openTabIDs.contains(repo.id) {
                await repo.loadCard(force: true)
            }
        }
    }

    /// Pops Apple's own installer dialog. No completion callback exists;
    /// `watchForGit` is already polling for the outcome.
    func installCommandLineTools() {
        Task { await Toolchain.installCommandLineTools() }
    }

    func openRepoPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(path: url.path)
    }

    func open(path: String) {
        // One spelling from here down — see `canonical`. The alert below is the
        // exception: it quotes the path back at the user, and that has to be
        // the folder they actually picked.
        let canonical = Self.canonical(path: path)
        var isDir: ObjCBool = false
        let gitPath = canonical + "/.git"
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            // Never auto-init: a novice picking their home folder would
            // turn it into a repo. Tell them how to do it themselves.
            nonGitPath = path
            return
        }
        // Already on the wall — with or without a tab. Opening it again is
        // the same gesture as clicking its card.
        if let existing = repos.first(where: { $0.path == canonical }) {
            openTab(existing)
            return
        }
        let repo = RepoState(path: canonical)
        repos.append(repo)
        openTab(repo)
        Task { await repo.refresh() }
    }

    /// Give a repo a tab and show it. Every route to a repo goes through here
    /// — the open panel, the Dashboard's cards, its context menu — so there is
    /// one place that keeps "showing" and "has a tab" in agreement.
    func openTab(_ repo: RepoState) {
        if !openTabIDs.contains(repo.id) {
            openTabIDs.append(repo.id)
        }
        activeRepoID = repo.id
        persist()
    }

    /// Close a tab. The repository stays on the Dashboard and in the restored
    /// list: getting back to it is a click on its card, not another trip
    /// through the open panel. Use `remove` to forget it altogether.
    func closeTab(repo: RepoState) {
        guard openTabIDs.contains(repo.id) else { return }
        openTabIDs.removeAll { $0 == repo.id }
        if activeRepoID == repo.id {
            activeRepoID = openTabIDs.first
        }
        // A tab used to be the only thing holding a RepoState alive, so
        // closing one stopped its watcher and its auto-fetch by deinit. The
        // repo outlives its tab now, so the background work has to be told.
        repo.tabClosed()
        persist()
    }

    /// Forget a repository: its tab, its card on the wall, and its line in the
    /// restored list. Nothing on disk is touched — this is the app's own list,
    /// not the working copy.
    func remove(repo: RepoState) {
        closeTab(repo: repo)
        repos.removeAll { $0.id == repo.id }
        // Removing from the Dashboard's own context menu leaves the user
        // looking at the grid, so it has to lose that repo's cells now
        // rather than on the next visit.
        mergeActivity()
        persist()
    }

    /// Move a tab to another slot, the others closing the gap behind it.
    /// Called repeatedly while a tab is dragged — once per slot it crosses,
    /// not once per frame — so the strip the user sees IS the order, and
    /// letting go commits nothing extra.
    ///
    /// Tab order only: the Dashboard's wall keeps the order repos were added
    /// in, so dragging tabs around never reshuffles the cards underneath.
    func moveTab(from: Int, to: Int) {
        guard from != to,
              openTabIDs.indices.contains(from),
              openTabIDs.indices.contains(to)
        else { return }
        openTabIDs.insert(openTabIDs.remove(at: from), at: to)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(repos.map(\.path), forKey: Self.libraryKey)
        UserDefaults.standard.set(openTabIDs, forKey: Self.tabsKey)
    }
}
