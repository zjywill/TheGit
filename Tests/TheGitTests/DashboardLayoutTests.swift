import XCTest
@testable import TheGit

/// How the activity tiles divide a width. The bug this is here for: the tiles
/// were sized from a width they had themselves inflated, the row came out
/// wider than the window, and the wall hung off both edges of it. It looks
/// perfect in a screenshot right up until the window is dragged narrower.
final class DashboardLayoutTests: XCTestCase {
    /// Every width from a squeezed window to a maximised 5K one, in one-point
    /// steps: the row must never demand more than it was given. This is the
    /// property that failed, and it fails at specific widths rather than
    /// generally, which is why it's swept rather than sampled.
    func testTilesNeverDemandMoreThanTheyAreGiven() {
        for width in stride(from: 200.0, through: 3000.0, by: 1.0) {
            let layout = ActivityLayout(width: width)
            XCTAssertLessThanOrEqual(
                layout.demand, width,
                "tiles demand \(layout.demand) of \(width)"
            )
        }
    }

    /// And the grid tile in particular is never wider than the tiles it
    /// shares the row with can spare.
    func testGridLeavesRoomForTheTilesBesideIt() {
        for width in stride(from: 200.0, through: 3000.0, by: 1.0) {
            let layout = ActivityLayout(width: width)
            guard layout.isRow else { continue }
            let others = ActivityLayout.totalsWidth + ActivityLayout.repoWidth
                + 2 * ActivityLayout.gap
            XCTAssertLessThanOrEqual(layout.heatmap, width - others, "at \(width)pt")
        }
    }

    /// Narrower than a row, the grid drops to a line of its own and gets the
    /// whole width — the point of not being in the row, since a year is 52
    /// columns either way.
    func testNarrowGivesTheGridTheWholeWidth() {
        for width in [420.0, 600.0, ActivityLayout.rowFloor - 1] {
            let layout = ActivityLayout(width: width)
            XCTAssertFalse(layout.isRow, "at \(width)pt")
            XCTAssertEqual(layout.heatmap, width, "at \(width)pt")
        }
    }

    /// The two text tiles stay side by side as long as they both fit, so the
    /// section is two rows tall rather than three: three stacked tiles at the
    /// window's minimum height push the card wall off the screen.
    func testTextTilesPairUpBeforeTheyStack() {
        XCTAssertEqual(ActivityLayout(width: 600).mode, .split)
        XCTAssertEqual(ActivityLayout(width: ActivityLayout.splitFloor).mode, .split)
        XCTAssertEqual(ActivityLayout(width: ActivityLayout.splitFloor - 1).mode, .stack)
        // And the pair never demands more than it's given either.
        for width in stride(from: 200.0, through: ActivityLayout.rowFloor, by: 1.0) {
            let layout = ActivityLayout(width: width)
            guard layout.mode == .split else { continue }
            XCTAssertLessThanOrEqual(
                ActivityLayout.totalsWidth + ActivityLayout.repoWidth + ActivityLayout.gap,
                width, "at \(width)pt"
            )
        }
    }

    /// The row starts exactly where it can hold most of a year, and one point
    /// under it still stacks.
    func testRowStartsAtItsFloor() {
        XCTAssertTrue(ActivityLayout(width: ActivityLayout.rowFloor).isRow)
        XCTAssertFalse(ActivityLayout(width: ActivityLayout.rowFloor - 1).isRow)
        // And the floor is worth its name: 40 of the 52 columns, which is what
        // stops the row from being three tiles beside a stub of a grid.
        let atFloor = ActivityLayout(width: ActivityLayout.rowFloor)
        XCTAssertEqual(atFloor.cellSize, ActivityLayout.minCell)
        XCTAssertGreaterThanOrEqual(
            atFloor.heatmap - 2 * ActivityLayout.inset,
            ActivityGraph.blockWidth(weeks: 40, cellSize: ActivityLayout.minCell)
        )
    }

    /// Spare width becomes bigger squares, up to a point, and then stops:
    /// a maximised window must not hand the grid tile 600pt of margin.
    func testSpareWidthBecomesBiggerCellsUpToACap() {
        // Tight: the cell floors, and ActivityGraph drops columns instead.
        XCTAssertEqual(ActivityLayout(width: 1000).cellSize, ActivityLayout.minCell)
        // Roomy: somewhere in between, filling the tile exactly. Above about
        // 1300 the grid is already at its ideal and the cap has taken over.
        let roomy = ActivityLayout(width: 1200)
        XCTAssertGreaterThan(roomy.cellSize, ActivityLayout.minCell)
        XCTAssertLessThan(roomy.cellSize, ActivityLayout.maxCell)
        XCTAssertEqual(
            ActivityGraph.blockWidth(weeks: 52, cellSize: roomy.cellSize),
            roomy.heatmap - 2 * ActivityLayout.inset,
            accuracy: 0.001
        )
        // Maximised: capped, and so is the tile — the leftover goes to the
        // repo tile, whose sparklines can actually use it.
        let huge = ActivityLayout(width: 3000)
        XCTAssertEqual(huge.cellSize, ActivityLayout.maxCell)
        XCTAssertEqual(huge.heatmap, ActivityLayout.heatmapIdeal)
        XCTAssertLessThan(huge.demand, 3000)
    }

    /// Stacked in a narrow window, the cell still fills what it's given
    /// rather than leaving the tile half empty — a full year, wall to wall.
    func testStackedGridFillsItsTile() {
        let layout = ActivityLayout(width: 800)
        XCTAssertFalse(layout.isRow)
        XCTAssertEqual(
            ActivityGraph.blockWidth(weeks: 52, cellSize: layout.cellSize),
            800 - 2 * ActivityLayout.inset,
            accuracy: 0.001
        )
        // Past the cap it stops filling, which is the cap doing its job: a
        // 900pt stacked tile keeps 14pt cells and a little slack rather than
        // inflating its squares to swallow it.
        XCTAssertEqual(ActivityLayout(width: 900).cellSize, ActivityLayout.maxCell)
    }

    /// The first layout pass has no width yet, and a negative one (the
    /// scroller's width less its padding, before anything is measured) must
    /// not produce a negative tile or a nonsense cell.
    func testNoWidthYet() {
        for width in [-32.0, 0.0, 10.0] {
            let layout = ActivityLayout(width: width)
            XCTAssertFalse(layout.isRow)
            XCTAssertGreaterThanOrEqual(layout.heatmap, 0)
            XCTAssertEqual(layout.cellSize, ActivityLayout.minCell)
        }
    }

    /// The block-width arithmetic the tiles are laid out by, and its inverse.
    /// Everything above rests on these two agreeing.
    func testBlockWidthAndCellSizeAreInverses() {
        for weeks in [1, 26, 40, 52] {
            for cell in [8.0, 11.0, 14.0, 22.0] {
                let width = ActivityGraph.blockWidth(weeks: weeks, cellSize: cell)
                XCTAssertEqual(
                    ActivityGraph.cellSize(fitting: weeks, in: width), cell,
                    accuracy: 0.001,
                    "\(weeks) columns at \(cell)pt"
                )
            }
        }
    }
}
