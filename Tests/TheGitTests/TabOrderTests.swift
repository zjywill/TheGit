import XCTest
@testable import TheGit

@MainActor
final class TabOrderTests: XCTestCase {

    /// AppState reloads whatever tabs were open last; these tests care only
    /// about the order it is handed, so replace the list outright.
    private func appState(_ names: [String]) -> AppState {
        let state = AppState()
        state.repos = names.map { RepoState(path: "/tmp/" + $0) }
        return state
    }

    private func order(_ state: AppState) -> [String] {
        state.repos.map(\.displayName)
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
        state.activeRepoID = state.repos[2].id
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
