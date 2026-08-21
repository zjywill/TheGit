import XCTest
@testable import TheGit

final class CommitHoverTests: XCTestCase {

    // MARK: - details

    private func details(_ message: String, files: [ReviewFile] = []) -> CommitHoverDetails {
        CommitHoverDetails(message: message, files: files)
    }

    func testBodyIsEverythingUnderTheFirstBlankLine() {
        let d = details("fix(diff): stop flashing\n\nPicking a file cleared lines.\n\nCo-Authored-By: X")
        XCTAssertEqual(d.body, "Picking a file cleared lines.\n\nCo-Authored-By: X")
    }

    func testOneLineMessageHasNoBody() {
        XCTAssertEqual(details("init").body, "")
        XCTAssertEqual(details("init\n").body, "")
    }

    /// git folds a wrapped subject paragraph into `%s`; the body starts
    /// only at the first blank line, the same as git's `%b`.
    func testWrappedSubjectParagraphIsNotBody() {
        let d = details("a subject that\nwraps\n\nthe body")
        XCTAssertEqual(d.body, "the body")
    }

    func testLineCountsSumAcrossFiles() {
        let d = details("m", files: [
            ReviewFile(path: "a", status: "M", additions: 3, deletions: 1),
            ReviewFile(path: "b", status: "A", additions: 10),
            ReviewFile(path: "c", status: "D", deletions: 4),
        ])
        XCTAssertEqual(d.additions, 13)
        XCTAssertEqual(d.deletions, 5)
    }

    // MARK: - placement

    private let pane = CGSize(width: 900, height: 700)

    func testRowWithRoomBelowGetsCardBelowAtMessageColumn() {
        let row = CGRect(x: 8, y: 100, width: 884, height: 32)
        let p = CommitHoverPlacement(row: row, pane: pane, messageX: 220, zoom: 1)
        XCTAssertTrue(p.below)
        XCTAssertEqual(p.x, 220)
        XCTAssertEqual(p.width, 400)
        XCTAssertEqual(p.inset, 132 + CommitHoverPlacement.gap)
        XCTAssertEqual(p.maxHeight, 700 - 132 - CommitHoverPlacement.gap - CommitHoverPlacement.margin)
    }

    func testRowNearTheBottomGetsCardAbove() {
        let row = CGRect(x: 8, y: 600, width: 884, height: 32)
        let p = CommitHoverPlacement(row: row, pane: pane, messageX: 220, zoom: 1)
        XCTAssertFalse(p.below)
        // Anchored by the bottom edge: the card's bottom sits a gap over the row.
        XCTAssertEqual(p.inset, 700 - 600 + CommitHoverPlacement.gap)
        XCTAssertEqual(p.maxHeight, 600 - CommitHoverPlacement.gap - CommitHoverPlacement.margin)
    }

    /// A short pane has room for a full card on neither side; the one with
    /// more room wins rather than the default.
    func testShortPanePicksTheRoomierSide() {
        let short = CGSize(width: 900, height: 400)
        let upper = CommitHoverPlacement(
            row: CGRect(x: 0, y: 100, width: 900, height: 32), pane: short, messageX: 0, zoom: 1
        )
        let lower = CommitHoverPlacement(
            row: CGRect(x: 0, y: 300, width: 900, height: 32), pane: short, messageX: 0, zoom: 1
        )
        XCTAssertTrue(upper.below)
        XCTAssertFalse(lower.below)
    }

    func testCardStaysInsideANarrowPane() {
        let narrow = CGSize(width: 300, height: 700)
        let p = CommitHoverPlacement(
            row: CGRect(x: 0, y: 100, width: 300, height: 32), pane: narrow, messageX: 200, zoom: 1
        )
        XCTAssertEqual(p.width, 300 - CommitHoverPlacement.margin * 2)
        XCTAssertEqual(p.x, CommitHoverPlacement.margin)
    }

    func testMessageColumnFarRightSlidesCardLeftToFit() {
        let p = CommitHoverPlacement(
            row: CGRect(x: 0, y: 100, width: 900, height: 32), pane: pane, messageX: 700, zoom: 1
        )
        XCTAssertEqual(p.x, 900 - 400 - CommitHoverPlacement.margin)
    }

    func testZoomScalesWidthAndThreshold() {
        let p = CommitHoverPlacement(
            row: CGRect(x: 0, y: 100, width: 900, height: 32), pane: pane, messageX: 0, zoom: 1.5
        )
        XCTAssertEqual(p.width, 600)
    }
}
