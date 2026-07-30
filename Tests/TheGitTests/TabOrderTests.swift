import XCTest
@testable import TheGit

@MainActor
final class TabOrderTests: XCTestCase {

    /// AppState reloads whatever tabs were open last; these tests care only
    /// about the order it is handed, so replace both lists outright — every
    /// repo on the wall, and a tab open on each of them.
    private func appState(_ names: [String]) -> AppState {
        let state = AppState()
        state.repos = names.map { RepoState(path: "/tmp/" + $0) }
        state.openTabIDs = state.repos.map(\.id)
        return state
    }

    private func order(_ state: AppState) -> [String] {
        state.openRepos.map(\.displayName)
    }

    /// Moving rightwards, everything the tab passes closes up behind it.
    /// This is the direction the index maths gets wrong: removing the tab
    /// first shifts every slot past it down by one before the insert.
    func testMovingRightwards() {
        let state = appState(["a", "b", "c", "d"])
        state.moveTab(from: 0, to: 2)
        XCTAssertEqual(order(state), ["b", "c", "a", "d"])
    }

    func testMovingLeftwards() {
        let state = appState(["a", "b", "c", "d"])
        state.moveTab(from: 3, to: 1)
        XCTAssertEqual(order(state), ["a", "d", "b", "c"])
    }

    func testMovingToTheEnd() {
        let state = appState(["a", "b", "c"])
        state.moveTab(from: 0, to: 2)
        XCTAssertEqual(order(state), ["b", "c", "a"])
    }

    func testMovingNowhereChangesNothing() {
        let state = appState(["a", "b", "c"])
        state.moveTab(from: 1, to: 1)
        XCTAssertEqual(order(state), ["a", "b", "c"])
    }

    /// A drag is a stream of updates and the list can change under it, so
    /// an index that no longer exists must be ignored rather than trapped.
    func testOutOfRangeIsIgnored() {
        let state = appState(["a", "b"])
        state.moveTab(from: 0, to: 7)
        state.moveTab(from: -1, to: 1)
        XCTAssertEqual(order(state), ["a", "b"])
    }

    /// Which tab is showing is a separate thing from where it sits — a
    /// reorder must never switch tabs under the user.
    func testReorderKeepsTheActiveTab() {
        let state = appState(["a", "b", "c"])
        state.openTab(state.repos[2])
        state.moveTab(from: 0, to: 1)
        XCTAssertEqual(state.activeRepo?.displayName, "c")
    }
}

final class TabStripTests: XCTestCase {

    /// Widths 100, 60, 200 with 2pt gaps: slots start at 0, 102 and 164.
    private let widths: [CGFloat] = [100, 60, 200]
    private var centers: [CGFloat] { TabStrip.centers(widths: widths, spacing: 2) }

    func testCentersAccountForSpacing() {
        XCTAssertEqual(centers, [50, 132, 264])
    }

    /// Held still, or barely moved, nothing gives way.
    func testStayingPutWhileInsideItsOwnSlot() {
        XCTAssertEqual(TabStrip.slot(holding: 50, current: 0, centers: centers), 0)
        XCTAssertEqual(TabStrip.slot(holding: 131, current: 0, centers: centers), 0)
    }

    /// The neighbour yields at its own centre, not at the point of contact:
    /// tab 0 has to be dragged past 132, well beyond where the two overlap.
    func testNeighbourYieldsAtItsCentre() {
        XCTAssertEqual(TabStrip.slot(holding: 133, current: 0, centers: centers), 1)
    }

    /// Passing a wide tab takes its full width — 264, not 164 where it starts.
    func testWideNeighbourTakesItsWholeWidth() {
        XCTAssertEqual(TabStrip.slot(holding: 200, current: 1, centers: centers), 1)
        XCTAssertEqual(TabStrip.slot(holding: 265, current: 1, centers: centers), 2)
    }

    /// One update of a fast drag can cross several slots at once.
    func testCrossingSeveralSlotsInOneStep() {
        XCTAssertEqual(TabStrip.slot(holding: 400, current: 0, centers: centers), 2)
        XCTAssertEqual(TabStrip.slot(holding: -100, current: 2, centers: centers), 0)
    }

    /// Dragged off either end it stops at the end, it doesn't wrap or trap.
    func testClampsAtBothEnds() {
        XCTAssertEqual(TabStrip.slot(holding: 9999, current: 2, centers: centers), 2)
        XCTAssertEqual(TabStrip.slot(holding: -9999, current: 0, centers: centers), 0)
    }

    /// Widths arrive from a preference key one layout pass late, so the
    /// first drag update can run against nothing at all.
    func testEmptyStripIsSafe() {
        XCTAssertEqual(TabStrip.centers(widths: [], spacing: 2), [])
        XCTAssertEqual(TabStrip.slot(holding: 10, current: 0, centers: []), 0)
    }
}

/// A tab is a window onto a repository, not the record that it exists. These
/// are the two staying apart: closing every tab must leave the wall alone, and
/// only Remove takes a repo off it.
@MainActor
final class RepoLibraryTests: XCTestCase {

    private func appState(_ names: [String]) -> AppState {
        let state = AppState()
        state.repos = names.map { RepoState(path: "/tmp/" + $0) }
        state.openTabIDs = state.repos.map(\.id)
        return state
    }

    /// The whole point: a closed tab leaves the repo where it was, so getting
    /// back to it is a click on its card and not another trip through the
    /// open panel.
    func testClosingATabKeepsTheRepo() {
        let state = appState(["a", "b"])
        state.closeTab(repo: state.repos[0])

        XCTAssertEqual(state.repos.map(\.displayName), ["a", "b"])
        XCTAssertEqual(state.openRepos.map(\.displayName), ["b"])
    }

    /// Closing the last tab lands on the Dashboard rather than on a repo the
    /// tab strip no longer lists.
    func testClosingTheLastTabShowsTheDashboard() {
        let state = appState(["a"])
        state.closeTab(repo: state.repos[0])

        XCTAssertTrue(state.showingDashboard)
        XCTAssertNil(state.activeRepo)
        XCTAssertFalse(state.repos.isEmpty)
    }

    /// Reopening from the wall is the same call the open panel makes, and it
    /// must not add a second tab for a repo that already has one.
    func testReopeningIsIdempotent() {
        let state = appState(["a", "b"])
        state.closeTab(repo: state.repos[0])
        state.openTab(state.repos[0])
        state.openTab(state.repos[0])

        XCTAssertEqual(state.openRepos.map(\.displayName), ["b", "a"])
        XCTAssertEqual(state.activeRepo?.displayName, "a")
    }

    /// Remove is the one that forgets it — tab and card both.
    func testRemoveTakesTheCardToo() {
        let state = appState(["a", "b"])
        state.remove(repo: state.repos[0])

        XCTAssertEqual(state.repos.map(\.displayName), ["b"])
        XCTAssertEqual(state.openRepos.map(\.displayName), ["b"])
    }

    /// Dragging tabs about is a fact about the strip, not about the wall: the
    /// cards keep the order the repos were added in.
    func testReorderingTabsLeavesTheWallAlone() {
        let state = appState(["a", "b", "c"])
        state.moveTab(from: 0, to: 2)

        XCTAssertEqual(state.openRepos.map(\.displayName), ["b", "c", "a"])
        XCTAssertEqual(state.repos.map(\.displayName), ["a", "b", "c"])
    }

    /// A repo on the wall with no tab is not the tab on screen: the card's
    /// click has to open one, and until it does the window is on the Dashboard.
    func testARepoWithNoTabIsNeverTheActiveTab() {
        let state = appState(["a"])
        state.closeTab(repo: state.repos[0])
        state.activeRepoID = state.repos[0].id

        XCTAssertNil(state.activeRepo)
        XCTAssertTrue(state.showingDashboard)
    }
}

/// A repo's id is its path, so "already on the wall" is a string comparison —
/// and one working copy has several spellings. These are the ones that used to
/// get through: `/tmp` and `/var` are symlinks into `/private` on every Mac, a
/// trailing slash is free, and `~` isn't a real directory. Each of them once
/// bought a second card, a second tab and a second file watcher over the same
/// files, neither copy seeing the other's refreshes.
@MainActor
final class RepoPathIdentityTests: XCTestCase {

    /// A directory with a `.git` in it, which is all `open(path:)` checks for.
    /// Under the temporary directory on purpose: that lives beneath `/var`,
    /// which is exactly the symlink this is about.
    private func makeRepoDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "TheGitPathTests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path + "/.git",
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// The state each test starts from, with whatever the last session saved
    /// cleared out of the way.
    private func appState() -> AppState {
        let state = AppState()
        state.repos = []
        state.openTabIDs = []
        return state
    }

    /// Which spelling wins doesn't matter — only that every spelling of one
    /// directory lands on the same one. Foundation's choice is the
    /// `/private`-stripped form, which is why these assert convergence rather
    /// than a particular prefix.
    func testEverySpellingLandsOnOne() throws {
        let path = try makeRepoDirectory()
        let resolved = AppState.canonical(path: path)

        // The panel's spelling and git's, which is the pair that used to make
        // two cards. The temporary directory is under /var on macOS, so this is
        // the real thing rather than a constructed case.
        XCTAssertTrue(path.hasPrefix("/var/"), path)
        XCTAssertEqual(AppState.canonical(path: "/private" + path), resolved)
        XCTAssertEqual(AppState.canonical(path: path + "/"), resolved)
        XCTAssertEqual(AppState.canonical(path: path + "/./"), resolved)
        XCTAssertEqual(AppState.canonical(path: "~"), NSHomeDirectory())
    }

    /// And an ordinary symlink to a repo resolves to the repo, so opening the
    /// shortcut and opening the folder are the same repo.
    func testASymlinkIsItsTarget() throws {
        let path = try makeRepoDirectory()
        let link = NSTemporaryDirectory() + "TheGitPathLink-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: link) }

        XCTAssertEqual(AppState.canonical(path: link), AppState.canonical(path: path))

        let state = appState()
        state.open(path: link)
        state.open(path: path)
        XCTAssertEqual(state.repos.count, 1)
        XCTAssertEqual(state.openTabIDs.count, 1)
    }

    /// Two spellings of one repo: the open panel's and git's. One card, one
    /// tab, and the second attempt just switches to it.
    func testTwoSpellingsAreOneRepo() throws {
        let path = try makeRepoDirectory()
        let state = appState()

        state.open(path: path)
        state.open(path: AppState.canonical(path: path))
        state.open(path: path + "/")

        XCTAssertEqual(state.repos.count, 1)
        XCTAssertEqual(state.openTabIDs.count, 1)
        XCTAssertEqual(state.repos[0].path, AppState.canonical(path: path))
    }

    /// Reopening the other spelling after closing the tab has to find the card
    /// that's already on the wall — the whole reason the two lists came apart.
    func testTheOtherSpellingReopensTheSameCard() throws {
        let path = try makeRepoDirectory()
        let state = appState()

        state.open(path: path)
        let repo = state.repos[0]
        state.closeTab(repo: repo)
        state.open(path: AppState.canonical(path: path))

        XCTAssertEqual(state.repos.count, 1)
        XCTAssertTrue(state.repos[0] === repo)
        XCTAssertEqual(state.openRepos.count, 1)
    }

    /// A folder with no `.git` is still refused, and the alert quotes back the
    /// path the user actually picked rather than its resolved form.
    func testANonRepoIsRefusedInTheUsersOwnWords() throws {
        let path = NSTemporaryDirectory() + "TheGitPathTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let state = appState()

        state.open(path: path)

        XCTAssertTrue(state.repos.isEmpty)
        XCTAssertEqual(state.nonGitPath, path)
    }
}

/// What launch does with what the last session saved. The interesting case is
/// the upgrade: the build where a tab WAS the repo saved one list, and it could
/// hold the same working copy twice under two spellings.
@MainActor
final class RepoRestoreTests: XCTestCase {
    private var savedLibrary: [String]?
    private var savedTabs: [String]?
    private var directories: [String] = []

    override func setUp() {
        savedLibrary = UserDefaults.standard.stringArray(forKey: AppState.libraryKey)
        savedTabs = UserDefaults.standard.stringArray(forKey: AppState.tabsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLibrary, forKey: AppState.libraryKey)
        UserDefaults.standard.set(savedTabs, forKey: AppState.tabsKey)
        for path in directories { try? FileManager.default.removeItem(atPath: path) }
        directories = []
    }

    private func makeRepoDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "TheGitRestoreTests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path + "/.git",
            withIntermediateDirectories: true
        )
        directories.append(path)
        return path
    }

    private func restore(library: [String], tabs: [String]?) -> AppState {
        UserDefaults.standard.set(library, forKey: AppState.libraryKey)
        if let tabs {
            UserDefaults.standard.set(tabs, forKey: AppState.tabsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppState.tabsKey)
        }
        return AppState()
    }

    /// No saved tab list is the upgrade from the build that had no such thing:
    /// everything it restored was a tab, so it stays a tab.
    func testAnUpgradeKeepsEveryRestoredRepoAsATab() throws {
        let one = try makeRepoDirectory()
        let two = try makeRepoDirectory()
        let state = restore(library: [one, two], tabs: nil)

        XCTAssertEqual(state.repos.count, 2)
        XCTAssertEqual(state.openTabIDs.count, 2)
        XCTAssertEqual(state.activeRepo?.path, AppState.canonical(path: one))
    }

    /// A saved tab list is a subset, in its own order, and the repos left out of
    /// it come back as cards with no tab.
    func testTabsComeBackInTheirOwnOrder() throws {
        let one = try makeRepoDirectory()
        let two = try makeRepoDirectory()
        let three = try makeRepoDirectory()
        let state = restore(library: [one, two, three], tabs: [three, one])

        XCTAssertEqual(state.repos.count, 3)
        XCTAssertEqual(
            state.openRepos.map(\.path),
            [three, one].map { AppState.canonical(path: $0) }
        )
    }

    /// Two spellings of one repo saved by an older build come back as one card
    /// and one tab — and the folded list is written straight back out, so the
    /// duplicate is gone for good rather than only for this session.
    func testDuplicateSpellingsFoldOnLaunch() throws {
        let path = try makeRepoDirectory()
        let other = "/private" + path
        let state = restore(library: [path, other], tabs: [other, path])

        XCTAssertEqual(state.repos.map(\.path), [AppState.canonical(path: path)])
        XCTAssertEqual(state.openTabIDs, [AppState.canonical(path: path)])
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: AppState.libraryKey),
            [AppState.canonical(path: path)]
        )
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: AppState.tabsKey),
            [AppState.canonical(path: path)]
        )
    }

    /// A repo that has since been deleted or moved doesn't come back at all —
    /// and it must not take its tab with it into a list of tabs for repos that
    /// aren't there.
    func testAVanishedRepoIsDropped() throws {
        let alive = try makeRepoDirectory()
        let gone = NSTemporaryDirectory() + "TheGitRestoreTests-gone-" + UUID().uuidString
        let state = restore(library: [gone, alive], tabs: [gone, alive])

        XCTAssertEqual(state.repos.map(\.path), [AppState.canonical(path: alive)])
        XCTAssertEqual(state.openTabIDs, [AppState.canonical(path: alive)])
    }
}
