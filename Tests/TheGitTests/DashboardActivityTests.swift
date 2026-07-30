import XCTest
@testable import TheGit

/// The Dashboard's heatmap sums repositories, which is the part a single
/// repo's grid never had to get right: a day's cell is now a claim about
/// several histories at once, and the ways that goes wrong — double-counted
/// reloads, a closed repo's commits left on the grid — all look like a
/// perfectly plausible green square.
@MainActor
final class DashboardActivityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-activity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Noon rather than midnight, so a commit's day is the same day in every
    /// timezone the histogram might be rendered in — `git log` prints it
    /// with `--date=short-local`, and a midnight stamp lands on either side
    /// of the boundary depending on where the Mac is.
    private func noon(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let midday = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
        return calendar.date(byAdding: .day, value: -daysAgo, to: midday) ?? midday
    }

    private func key(daysAgo: Int) -> Int {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day], from: noon(daysAgo: daysAgo)
        )
        return ActivityDay.key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// `commits` commits, all stamped `daysAgo` days back.
    private func makeRepo(_ name: String, commits: Int, daysAgo: Int = 0) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: noon(daysAgo: daysAgo))
        try await git(path, ["init", "-q", "-b", "main", "."], at: stamp)
        for index in 1...max(1, commits) {
            try "line \(index)\n".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
            try await git(path, ["add", "-A"], at: stamp)
            try await git(path, ["commit", "-qm", "commit \(index)"], at: stamp)
        }
        return path
    }

    @discardableResult
    private func git(_ dir: String, _ args: [String], at stamp: String) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_DATE": stamp,
                "GIT_COMMITTER_DATE": stamp,
            ]
        )
    }

    /// AppState restores whatever tabs were open last; these tests hand it
    /// their own wall, the same way the tab-order tests do.
    private func appState(_ paths: [String]) -> AppState {
        let state = AppState()
        state.repos = paths.map { RepoState(path: $0) }
        return state
    }

    /// One cell, two repositories, and the count is both of them — the whole
    /// point of the grid being on this screen rather than in a sidebar.
    func testADayIsEveryRepoThatTouchedIt() async throws {
        let state = appState([
            try await makeRepo("alpha", commits: 3),
            try await makeRepo("beta", commits: 2),
        ])
        await state.loadActivity()

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 5)
        XCTAssertTrue(state.activityLoaded)
        // Busiest first, because the tooltip is cut off after three repos and
        // the ones that did the work are the ones worth keeping.
        XCTAssertEqual(state.activityDetail[key(daysAgo: 0)], "alpha 3, beta 2")
    }

    /// Commits land on the day they were authored, not on the day they were
    /// read — the year window is what makes the older columns real.
    func testDaysKeepTheirOwnDates() async throws {
        let state = appState([
            try await makeRepo("today", commits: 1),
            try await makeRepo("older", commits: 4, daysAgo: 40),
        ])
        await state.loadActivity()

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 1)
        XCTAssertEqual(state.activity[key(daysAgo: 40)], 4)
        XCTAssertEqual(state.activity.values.reduce(0, +), 5)
    }

    /// Reading a repo again replaces its contribution. Adding to a running
    /// total instead would double every count on the Dashboard's Refresh,
    /// which is the one button on that screen whose whole job is accuracy.
    func testRereadingARepoDoesNotDoubleIt() async throws {
        let state = appState([try await makeRepo("alpha", commits: 3)])
        await state.loadActivity()
        await state.loadActivity(force: true)

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 3)
    }

    /// Removing a repo takes its cells with it, and it happens now rather
    /// than on the next visit: the Dashboard's own context menu can remove a
    /// repo while the user is looking at the grid. (Closing its tab does not
    /// — the card stays on the wall, so the grid keeps counting it.)
    func testRemovingARepoLeavesTheGrid() async throws {
        let state = appState([
            try await makeRepo("alpha", commits: 3),
            try await makeRepo("beta", commits: 2),
        ])
        await state.loadActivity()
        state.remove(repo: state.repos[1])

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 3)
        // One repo left, so the tooltips stop naming it — see below.
        XCTAssertNil(state.activityDetail[key(daysAgo: 0)])
    }

    /// With one repo open the grid IS that repo, and "3 commits · alpha 3"
    /// spends half a tooltip restating the number next to it.
    func testASingleRepoIsNotNamed() async throws {
        let state = appState([try await makeRepo("alpha", commits: 3)])
        await state.loadActivity()

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 3)
        XCTAssertTrue(state.activityDetail.isEmpty)
    }

    /// A day busier than the tooltip can hold says how much it left out,
    /// rather than trailing off as if three repos were all of them.
    func testCrowdedDaysCountWhatTheyDropped() async throws {
        var paths: [String] = []
        for (index, name) in ["a", "b", "c", "d", "e"].enumerated() {
            paths.append(try await makeRepo(name, commits: 5 - index))
        }
        let state = appState(paths)
        await state.loadActivity()

        XCTAssertEqual(state.activity[key(daysAgo: 0)], 5 + 4 + 3 + 2 + 1)
        XCTAssertEqual(state.activityDetail[key(daysAgo: 0)], "a 5, b 4, c 3, +2 more")
    }

    /// Nothing read yet is not the same fact as a quiet year, and the caption
    /// under the grid says two different things about them.
    func testNothingReadYetIsNotAQuietYear() async throws {
        let state = appState([try await makeRepo("alpha", commits: 1)])
        XCTAssertFalse(state.activityLoaded)
        await state.loadActivity()
        XCTAssertTrue(state.activityLoaded)
    }

    /// Loaded is a fact about the wall, not about the cache: a removed repo's
    /// counts stay cached (that's what makes reopening it instant), but a
    /// wall of entirely new repos hasn't been read, and saying it has puts
    /// "0 commits in the last year" on screen where "Reading…" belongs.
    func testANewWallIsNotLoadedByARemovedReposCache() async throws {
        let state = appState([try await makeRepo("alpha", commits: 3)])
        await state.loadActivity()
        state.remove(repo: state.repos[0])
        XCTAssertFalse(state.activityLoaded)

        state.repos = [RepoState(path: try await makeRepo("beta", commits: 2))]
        await state.loadActivity()
        XCTAssertTrue(state.activityLoaded)
        XCTAssertEqual(state.activity[key(daysAgo: 0)], 2)
    }
}
