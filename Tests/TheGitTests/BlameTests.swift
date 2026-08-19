import XCTest
@testable import TheGit

/// `GitParsers.parseBlame` over verbatim `git blame --line-porcelain` output —
/// the form TheGit's blame column is built from. The fixture mirrors what a
/// real repo emits: each group is a header line (`<hash> <orig> <final>
/// [count]`), property lines, and a tab-prefixed content line. A group of
/// several identical lines (a comment block or a repeated import) carries a
/// fourth field with the run length; each line still repeats the whole
/// record, so a parser never needs to decode the run itself.
final class BlameTests: XCTestCase {

    /// Minimal one-line-per-group output from a normal (non-boundary) file.
    private func plainFixture() -> String {
        """
        007bd1aab30b0943ad3ce7f145e7bd69f62a5f80 1 1
        author zjywill
        author-mail <zjywill@hotmail.com>
        author-time 1786688371
        author-tz +0800
        committer zjywill
        committer-mail <zjywill@hotmail.com>
        committer-time 1786688371
        committer-tz +0800
        summary docs(release): update cask references and install troubleshooting
        filename Sources/TheGit/Core/Models.swift
        \timport Foundation
        007bd1aab30b0943ad3ce7f145e7bd69f62a5f80 2 2
        author zjywill
        author-mail <zjywill@hotmail.com>
        author-time 1786688371
        author-tz +0800
        committer zjywill
        committer-mail <zjywill@hotmail.com>
        committer-time 1786688371
        committer-tz +0800
        summary docs(release): update cask references and install troubleshooting
        filename Sources/TheGit/Core/Models.swift
        \t
        """
    }

    func testParsesEachLineGroup() {
        let blamed = GitParsers.parseBlame(plainFixture())
        XCTAssertEqual(blamed.count, 2)
        guard let first = blamed[1], let second = blamed[2] else {
            return XCTFail("expected lines 1 and 2")
        }
        XCTAssertEqual(first.commitHash, "007bd1aab30b0943ad3ce7f145e7bd69f62a5f80")
        XCTAssertEqual(first.author, "zjywill")
        XCTAssertEqual(first.summary, "docs(release): update cask references and install troubleshooting")
        XCTAssertEqual(first.lineNumber, 1)
        XCTAssertEqual(second.lineNumber, 2)
        // Author-time 1786688371 → a known instant.
        XCTAssertEqual(
            second.date.timeIntervalSince1970, 1786688371,
            accuracy: 1
        )
    }

    /// A four-field header (`… final count`) must not confuse line-number
    /// parsing: the final line number is always the third field.
    func testGroupHeaderWithRunCount() {
        let output = """
        007bd1aab30b0943ad3ce7f145e7bd69f62a5f80 3 3 6
        author zjywill
        author-time 1786688371
        summary block comment
        \ta
        """
        let blamed = GitParsers.parseBlame(output)
        XCTAssertEqual(blamed.count, 1)
        XCTAssertEqual(blamed[3]?.lineNumber, 3)
        XCTAssertEqual(blamed[3]?.commitHash, "007bd1aab30b0943ad3ce7f145e7bd69f62a5f80")
    }

    /// Uncommitted working-tree content carries the all-zeros hash and no
    /// author — the parser must keep it as a real record so the column can
    /// say "not committed" instead of blank.
    func testUncommittedLine() {
        let output = """
        0000000000000000000000000000000000000000 1 1 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1786688371
        author-tz +0800
        committer Not Committed Yet
        summary ?
        filename foo.swift
        \tlet freshlyWritten = true
        """
        let blamed = GitParsers.parseBlame(output)
        XCTAssertEqual(blamed.count, 1)
        guard let line = blamed[1] else { return XCTFail("expected line 1") }
        XCTAssertTrue(line.isUncommitted)
        XCTAssertEqual(
            line.commitHash,
            "0000000000000000000000000000000000000000"
        )
    }

    /// A boundary commit names a real hash but no author — the record stays
    /// attributable by hash alone, and the view renders it as unknown.
    func testBoundaryCommitKeepsHash() {
        let output = """
        aaaa00000000000000000000000000000000000000 1 1 1
        summary irrelevant
        \tfirst line
        """
        let blamed = GitParsers.parseBlame(output)
        XCTAssertEqual(blamed.count, 1)
        guard let line = blamed[1] else { return XCTFail("expected line 1") }
        XCTAssertFalse(line.isUncommitted)
        XCTAssertEqual(line.commitHash, "aaaa00000000000000000000000000000000000000")
        XCTAssertEqual(line.author, "")
    }

    func testEmptyAndGarbageOutput() {
        XCTAssertTrue(GitParsers.parseBlame("").isEmpty)
        XCTAssertTrue(GitParsers.parseBlame("\n\n").isEmpty)
        // A content line with no preceding header is skipped entirely.
        XCTAssertTrue(GitParsers.parseBlame("\torphan\n").isEmpty)
    }

    func testShortHash() {
        let line = BlameLine(
            lineNumber: 1,
            commitHash: "007bd1aab30b0943ad3ce7f145e7bd69f62a5f80",
            author: "zjywill",
            date: Date(),
            summary: "s"
        )
        XCTAssertEqual(line.shortHash, "007bd1a")
        XCTAssertFalse(line.isUncommitted)
        XCTAssertFalse(line.isBoundary)
    }
}
