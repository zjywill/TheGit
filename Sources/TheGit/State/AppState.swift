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
    @Published var activeRepoID: String? {
        didSet {
            persistActiveRepo()
            persistHome()
        }
    }
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
    /// The tab that was on screen at quit. Restoring it matters more than it
    /// sounds: without it every launch lands on the leftmost tab, which for
    /// anyone with a few repos open is never the one they were working in.
    static let activeKey = "TheGit.activeRepo"
    /// Which home screen was showing at quit, absent while a repo tab was —
    /// see `persistHome`.
    static let homeKey = "TheGit.homeScreen"
    /// The catalog: every repository on this Mac the user has told the app
    /// about, whether or not it has ever been opened. A superset of the wall
    /// above — see the catalog section below.
    static let catalogKey = "TheGit.repoCatalog"
    static let sectionsKey = "TheGit.repoSections"

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

    /// The two screens that aren't a repository, both pinned at the head of
    /// the tab strip. Which of them is showing only matters while no repo is
    /// selected — `activeRepo` still decides that, so there is still one
    /// selection and it can't disagree with itself.
    enum Home: String {
        /// Every repository this Mac knows about — see `RepositoriesView`.
        case repositories
        /// The wall of cards for the repos the user has added.
        case dashboard
    }

    /// Where a window with no repo selected lands. Dashboard by default: it's
    /// about the work in progress, and the catalog is where you go when what
    /// you want isn't on the wall yet.
    @Published private(set) var home: Home = .dashboard

    /// No repo selected means one of the two home screens, which is also where
    /// a window with nothing open lands. Derived from `activeRepo` so a stale
    /// id can't leave the strip highlighting a tab that isn't there.
    var showingDashboard: Bool { activeRepo == nil && home == .dashboard }
    var showingRepositories: Bool { activeRepo == nil && home == .repositories }

    func showDashboard() {
        activeRepoID = nil
        home = .dashboard
        persistHome()
    }

    func showRepositories() {
        activeRepoID = nil
        home = .repositories
        persistHome()
        // Branches move while a folder sits in the catalog, and this is the
        // moment that list is about to be read.
        refreshCatalog()
    }

    /// What a launch opens on. Pure, and separate from `init`, because it is
    /// the one decision at startup with four cases and the only way to check
    /// them is to state them.
    ///
    /// `homeKey` present means a home screen was showing at quit, and it wins:
    /// the remembered tab is still remembered — it just isn't what was on
    /// screen. Otherwise the remembered tab, if it still has one, and the
    /// leftmost tab when it doesn't (which is also what an upgrade from the
    /// build that saved neither gets).
    static func restoredScreen(home: String?, active: String?, tabs: [String]) -> Screen {
        if let home, let saved = Home(rawValue: home) { return .home(saved) }
        if let active, tabs.contains(active) { return .tab(active) }
        if let first = tabs.first { return .tab(first) }
        return .home(.dashboard)
    }

    enum Screen: Equatable {
        case home(Home)
        case tab(String)
    }

    /// Which screen a window comes back to, in one key: it holds a home
    /// screen's name while one is showing and is absent while a repo is, so
    /// "was I on a home screen at quit" and "which one" are one fact and
    /// can't contradict each other. The tab itself is `activeKey`'s job.
    private func persistHome() {
        if activeRepoID == nil {
            UserDefaults.standard.set(home.rawValue, forKey: Self.homeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.homeKey)
        }
    }

    /// A Dashboard refresh in flight, so the button that started it can say
    /// so. This is the slowest thing on the screen — N repos of git, then a
    /// year of history, then N CLI calls over the network — and without this
    /// the whole pass was silent while the cards changed under the pointer
    /// one at a time.
    @Published private(set) var refreshingDashboard = false

    /// The Dashboard's Refresh: every card straight from git, in the order
    /// they're read in. Sequential for the same reason the first load is —
    /// one wall of cards must not fire twenty subprocesses at once.
    func refreshDashboard() {
        // ⌘R held down must not stack a second pass on top of the first: the
        // whole point of the sequencing above is one subprocess at a time.
        guard !refreshingDashboard else { return }
        refreshingDashboard = true
        Task {
            defer { refreshingDashboard = false }
            for repo in repos { await repo.loadCard(force: true) }
            // After the cards, not with them: the cards are what the user is
            // looking at, and the grid is a year of history that hasn't
            // changed much in the time it took to read them.
            await loadActivity(force: true)
            // Last, because it's the only network in the pass — and forced,
            // because "did that PR land yet" is a reason this button gets
            // pressed.
            //
            // Also the only phase worth overlapping. The two git phases above
            // measure 0.05s and 0.02s per repo and stay sequential, because
            // the reason they are is a subprocess storm. This one is 2.5s of
            // waiting on a network per repo, spends almost no CPU doing it,
            // and each repo owns its own `ForgeClient` actor — so N repos in
            // series was N round trips of dead time. Bounded rather than
            // unbounded for the original reason: a wall of forty repos must
            // still not launch forty `gh` processes at once. Same number of
            // requests either way, and GitHub's limit is per hour, so
            // overlapping them costs no quota.
            await withTaskGroup(of: Void.self) { group in
                var pending = repos[...]
                var running = 0
                while running < Self.forgeFanOut, let repo = pending.popFirst() {
                    group.addTask { await repo.loadCardPullRequests(force: true) }
                    running += 1
                }
                while running > 0 {
                    _ = await group.next()
                    running -= 1
                    if let repo = pending.popFirst() {
                        group.addTask { await repo.loadCardPullRequests(force: true) }
                        running += 1
                    }
                }
            }
        }
    }

    /// How many repos may be waiting on their forge at once. Each one runs two
    /// `gh` processes now that the PR and issue fetches leave together, so this
    /// is half the real process ceiling.
    private static let forgeFanOut = 4

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
        switch Self.restoredScreen(
            home: UserDefaults.standard.string(forKey: Self.homeKey),
            active: UserDefaults.standard.string(forKey: Self.activeKey)
                .map { Self.canonical(path: $0) },
            tabs: openTabIDs
        ) {
        case .home(let saved):
            home = saved
            activeRepoID = nil
        case .tab(let id):
            activeRepoID = id
        }
        // The folding above can leave what's on disk out of date, and the next
        // write is whenever the user next opens or closes something.
        persist()
        // Everything on the wall is in the catalog by definition, which is
        // also what fills it on the first launch that has one.
        loadCatalog(seededWith: repos.map(\.path))
        refreshCatalog()
        Task { await hydrate() }
        Task { await watchForGit() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushCaches() }
        }
    }

    /// Fill the wall from last launch's cache before any git command runs:
    /// each card, and each repo's year in the summed heatmap. The tab that
    /// opens hydrates its own three panes — see `RepoState.appeared`.
    ///
    /// One repo at a time, in wall order, for the same reason `loadActivity`
    /// is sequential: filling in from the top reads as loading, while a wall
    /// that pops in at random reads as flicker.
    private func hydrate() async {
        // An empty library is not evidence that every cached file is
        // orphaned — it's also what a first launch, a cleared preference or
        // a test host looks like, and pruning on that would delete a cache
        // its owner is still using.
        guard !repos.isEmpty else { return }
        RepoCache.prune(keeping: repos.map(\.path))
        for repo in repos {
            await repo.hydrateSummary()
            guard let counts = repo.cachedYearActivity else { continue }
            activityByRepo[repo.id] = counts
            mergeActivity()
        }
    }

    /// Quitting is the one moment a debounced write would be dropped, and
    /// it is also the moment the cache exists for.
    private func flushCaches() {
        for repo in repos { repo.flushCache() }
    }

    // MARK: - Catalog

    /// Every repository this Mac knows about, grouped by project — see
    /// `RepoCatalog`. Three widening circles: a tab is what you're editing,
    /// the wall (`repos`) is what you're working on, and this is every
    /// repository you've told the app exists. A scan of `~/Git` puts forty
    /// folders in here and not one card on the wall — which is the point, since
    /// a card costs two subprocesses and a row costs two file reads.
    @Published private(set) var catalog: [RepoCatalog.Project] = []

    /// The user's own bands over that list. Empty until they make one, and the
    /// list draws no section chrome at all while it is.
    @Published private(set) var catalogSections: [RepoCatalog.Section] = []

    /// A scan in flight, so the screen can say so rather than look empty for
    /// two seconds while a home directory is walked.
    @Published private(set) var scanning = false
    /// What the last scan added, for one line of feedback. Cleared by the next.
    @Published var scanResult: String?

    private var catalogEntries: [RepoCatalog.Entry] = []

    /// True for a folder with a tab open right now — the one thing a catalog
    /// row can't read off the disk.
    func isOpen(path: String) -> Bool {
        openTabIDs.contains(Self.canonical(path: path))
    }

    /// Note that a folder was actually opened, adding it if it's new. The
    /// timestamp is what orders the clones inside a project.
    private func recordOpened(path: String) {
        let path = Self.canonical(path: path)
        if let index = catalogEntries.firstIndex(where: { $0.path == path }) {
            catalogEntries[index].lastOpened = Date()
        } else {
            catalogEntries.append(RepoCatalog.Entry(path: path, addedAt: Date(), lastOpened: Date()))
        }
        persistCatalog()
        refreshCatalog()
    }

    /// Add folders without opening any of them — what a scan does, and what
    /// dropping folders from Finder does. Returns how many were new, since
    /// "scanned 38, added 0" and "added 38" are different answers.
    @discardableResult
    func addToCatalog(paths: [String]) -> Int {
        let known = Set(catalogEntries.map(\.path))
        let now = Date()
        var seen = Set<String>()
        let fresh = paths
            .map { Self.canonical(path: $0) }
            .filter { !known.contains($0) && seen.insert($0).inserted }
        for path in fresh {
            catalogEntries.append(RepoCatalog.Entry(path: path, addedAt: now))
        }
        guard !fresh.isEmpty else { return 0 }
        persistCatalog()
        refreshCatalog()
        return fresh.count
    }

    /// Forget a folder entirely: out of the catalog, off the wall, and its tab
    /// closed. Nothing on disk is touched — this is the app's own list, not the
    /// working copy.
    func removeFromCatalog(path: String) {
        let path = Self.canonical(path: path)
        catalogEntries.removeAll { $0.path == path }
        if let repo = repos.first(where: { $0.path == path }) { remove(repo: repo) }
        persistCatalog()
        refreshCatalog()
    }

    /// Folders in the catalog that are no longer repositories — deleted,
    /// renamed, or on a disk that isn't plugged in. Read off the last refresh
    /// rather than the filesystem, so asking is free.
    var missingClones: [RepoCatalog.Clone] {
        catalog.flatMap(\.clones).filter { !$0.exists }
    }

    /// Forget every folder that isn't there any more. Offered as one action
    /// because that's how they arrive — a `rm -rf` of a work directory takes
    /// out six at once, and removing them one context menu at a time is the
    /// kind of chore an app should do for you.
    func removeMissingFromCatalog() {
        let gone = Set(missingClones.map(\.path))
        guard !gone.isEmpty else { return }
        catalogEntries.removeAll { gone.contains($0.path) }
        for repo in repos where gone.contains(repo.path) { remove(repo: repo) }
        persistCatalog()
        refreshCatalog()
    }

    /// Point a catalogued folder at where it went. A repository that was moved
    /// rather than deleted keeps its origin, so it lands back in the same
    /// project and the same section — the row is the only thing that changes.
    func relocatePanel(for path: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        panel.message = "Where is “\((path as NSString).lastPathComponent)” now?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = Self.canonical(path: url.path)
        guard RepoCatalog.facts(ofRepoAt: target).exists else {
            nonGitPath = url.path
            return
        }
        removeFromCatalog(path: path)
        addToCatalog(paths: [target])
    }

    /// Point at `~/Git` and take everything under it. This is the only way a
    /// list of forty repositories gets built without forty trips through a file
    /// picker — see `RepoCatalog.scan`.
    func scanFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder — every Git repository inside it is added"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        scan(roots: panel.urls.map(\.path))
    }

    /// The walk itself, off the main actor: pointing this at a home directory
    /// is thousands of `stat`s, and the window has to stay live while it runs.
    func scan(roots: [String]) {
        guard !scanning else { return }
        scanning = true
        scanResult = nil
        Task.detached(priority: .utility) {
            let found = roots.flatMap { RepoCatalog.scan(root: $0) }
            await MainActor.run {
                let added = self.addToCatalog(paths: found)
                self.scanning = false
                self.scanResult = Self.scanSummary(found: found.count, added: added)
            }
        }
    }

    /// Always says what happened, including when nothing did: a scan that found
    /// forty repositories already in the list must not read the same as one
    /// that found none.
    static func scanSummary(found: Int, added: Int) -> String {
        if found == 0 { return "No Git repositories found in that folder." }
        if added == 0 { return "All \(found) repositories there were already in the list." }
        let rest = found - added
        let head = "Added \(added) repositor\(added == 1 ? "y" : "ies")"
        return rest > 0 ? head + " · \(rest) already listed" : head + "."
    }

    /// A catalogue re-read the user asked for, as opposed to the several that
    /// happen on their own. Only the asked-for ones spin the button: this runs
    /// on every visit to the screen and on every app activation, and a control
    /// nobody touched turning itself is noise, not feedback.
    @Published private(set) var refreshingCatalog = false

    /// Re-read the `.git` of every catalogued folder and regroup. Off the main
    /// actor because it's two file reads per entry and the list can be long; no
    /// subprocesses either way — see `RepoCatalog`.
    func refreshCatalog(userInitiated: Bool = false) {
        let entries = catalogEntries
        if userInitiated { refreshingCatalog = true }
        Task.detached(priority: .utility) {
            let grouped = RepoCatalog.group(entries)
            await MainActor.run {
                self.catalog = grouped
                // Unconditional: an automatic pass that overlapped a manual
                // one must still clear it, or the button spins forever.
                self.refreshingCatalog = false
            }
        }
    }

    // MARK: - Catalog sections

    /// The catalog as it's drawn: the user's sections in their order, then
    /// everything not in one.
    var catalogShelves: [RepoCatalog.Shelf] {
        RepoCatalog.arrange(catalog, sections: catalogSections)
    }

    @discardableResult
    func addCatalogSection(name: String = "New Section") -> String {
        let section = RepoCatalog.Section(name: name)
        catalogSections.append(section)
        persistSections()
        return section.id
    }

    func renameCatalogSection(id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = catalogSections.firstIndex(where: { $0.id == id })
        else { return }
        catalogSections[index].name = clean
        persistSections()
    }

    /// Delete the band, not its contents: the projects fall back into the
    /// unsectioned bucket, which is the only behaviour that makes this safe
    /// enough not to need a confirmation.
    func deleteCatalogSection(id: String) {
        catalogSections.removeAll { $0.id == id }
        persistSections()
    }

    func moveCatalogSection(id: String, by offset: Int) {
        guard let from = catalogSections.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard catalogSections.indices.contains(to) else { return }
        catalogSections.insert(catalogSections.remove(at: from), at: to)
        persistSections()
    }

    /// Move a project into a section, or out of every section when `sectionID`
    /// is nil. Removed from all of them first: the arrangement is a partition,
    /// and a project listed twice would appear twice.
    func assignProject(_ projectID: String, toSection sectionID: String?) {
        for index in catalogSections.indices {
            catalogSections[index].projectIDs.removeAll { $0 == projectID }
        }
        if let sectionID, let index = catalogSections.firstIndex(where: { $0.id == sectionID }) {
            catalogSections[index].projectIDs.append(projectID)
        }
        persistSections()
    }

    private func persistSections() {
        guard let data = try? JSONEncoder().encode(catalogSections) else { return }
        UserDefaults.standard.set(data, forKey: Self.sectionsKey)
    }

    private func persistCatalog() {
        guard let data = try? JSONEncoder().encode(catalogEntries) else { return }
        UserDefaults.standard.set(data, forKey: Self.catalogKey)
    }

    private func loadCatalog(seededWith wallPaths: [String]) {
        if let data = UserDefaults.standard.data(forKey: Self.catalogKey),
           let saved = try? JSONDecoder().decode([RepoCatalog.Entry].self, from: data) {
            catalogEntries = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.sectionsKey),
           let saved = try? JSONDecoder().decode([RepoCatalog.Section].self, from: data) {
            catalogSections = saved
        }
        let known = Set(catalogEntries.map(\.path))
        let now = Date()
        for path in wallPaths where !known.contains(path) {
            catalogEntries.append(RepoCatalog.Entry(path: path, addedAt: now, lastOpened: now))
        }
        persistCatalog()
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
        recordOpened(path: canonical)
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
        // Forgetting a repo means forgetting it: its cached snapshot is a
        // copy of a working tree the user just told us they're done with.
        RepoCache.forget(path: repo.path)
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
        persistActiveRepo()
    }

    /// Its own function because `activeRepoID` changes on every tab click,
    /// which is far more often than the two lists do.
    private func persistActiveRepo() {
        // Only ever a repo. Both home screens select nothing, so writing the
        // nil through would mean that ending a session on the Dashboard — or
        // on the Repositories list, which is now one click from every window —
        // erased the very thing this key exists to remember. A stale id costs
        // nothing: `init` only restores one that still has a tab.
        guard let activeRepoID else { return }
        UserDefaults.standard.set(activeRepoID, forKey: Self.activeKey)
    }
}
