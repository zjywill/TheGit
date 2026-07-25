import XCTest
@testable import TheGit

final class GraphLayoutTests: XCTestCase {
    private func commit(_ hash: String, parents: [String], refs: [String] = []) -> Commit {
        Commit(hash: hash, parents: parents, author: "t", date: .init(timeIntervalSince1970: 0), refs: refs, subject: hash)
    }

    /// Linear history stays in lane 0.
    func testLinearHistory() {
        let rows = GraphLayout.layout(commits: [
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount).max(), 1)
    }

    /// A merge commit opens a second lane that closes at the fork point.
    ///
    ///   m (merge of b1, f1)
    ///   b1 -> base
    ///   f1 -> base
    ///   base
    func testMergeAndFork() {
        let rows = GraphLayout.layout(commits: [
            commit("m", parents: ["b1", "f1"]),
            commit("b1", parents: ["base"]),
            commit("f1", parents: ["base"]),
            commit("base", parents: []),
        ])
        // merge commit at lane 0, second parent gets lane 1
        XCTAssertEqual(rows[0].column, 0)
        XCTAssertEqual(rows[0].parentLanes.map(\.lane), [0, 1])
        // b1 continues in lane 0, f1 sits in lane 1
        XCTAssertEqual(rows[1].column, 0)
        XCTAssertEqual(rows[2].column, 1)
        // f1 keeps its own lane; both lines converge at base's row
        XCTAssertEqual(rows[2].parentLanes.map(\.lane), [1])
        // base collects both lanes at the top
        XCTAssertEqual(rows[3].column, 0)
        XCTAssertEqual(Set(rows[3].mergeSources.map(\.lane)), Set([0, 1]))
        // afterwards only one lane remains
        XCTAssertEqual(rows[3].parentLanes.map(\.lane), [])
    }

    /// Two independent branch tips share the graph without colliding.
    func testTwoTips() {
        let rows = GraphLayout.layout(commits: [
            commit("tip1", parents: ["a"]),
            commit("tip2", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(rows[0].column, 0)
        XCTAssertEqual(rows[1].column, 1)
        // tip2 keeps its lane; both lines converge at a's row
        XCTAssertEqual(rows[1].parentLanes.map(\.lane), [1])
        XCTAssertEqual(rows[2].column, 0)
        XCTAssertEqual(Set(rows[2].mergeSources.map(\.lane)), Set([0, 1]))
    }

    /// Freed lanes get reused instead of growing forever.
    func testLaneReuse() {
        let rows = GraphLayout.layout(commits: [
            commit("m1", parents: ["a", "x"]),
            commit("x", parents: ["a"]),
            commit("a", parents: ["z"]),
            commit("m2", parents: ["z", "y"]),
            commit("y", parents: ["z"]),
            commit("z", parents: []),
        ])
        // m2 must reuse lane 1 (freed when "a" collected it), not open a new one.
        XCTAssertEqual(rows[3].column, 1)
        XCTAssertLessThanOrEqual(GraphLayout.maxLanes(of: rows), 3)
    }
}
