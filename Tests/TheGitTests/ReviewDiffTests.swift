import XCTest
@testable import TheGit

/// `GitParsers.reviewFiles` over verbatim `git diff -z` output — the file
/// list the review panel is built on. Every fixture here was produced by a
/// real `git diff`, renames included: the `-z` numstat shape for a rename
/// (empty third field, then two path records) is the one thing about this
/// format that cannot be guessed.
final class ReviewDiffTests: XCTestCase {

    func testPlainAddModifyDelete() {
        let numstat = "1\t0\tadded.txt\u{0}4\t0\tkeep.txt\u{0}0\t3\tgone.txt\u{0}"
        let nameStatus = "A\u{0}added.txt\u{0}M\u{0}keep.txt\u{0}D\u{0}gone.txt\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files.map(\.path), ["added.txt", "keep.txt", "gone.txt"])
        XCTAssertEqual(files.map(\.status), ["A", "M", "D"])
        XCTAssertEqual(files[1].additions, 4)
        XCTAssertEqual(files[2].deletions, 3)
        XCTAssertFalse(files.contains { $0.isBinary })
        XCTAssertNil(files[0].oldPath)
    }

    /// A rename: numstat sends "0\t0\t" and then the two paths as records of
    /// their own, name-status sends "R100" with both. The row must land under
    /// the new path and remember the old one — without it, the file's diff
    /// can't be asked for.
    func testRenameCarriesBothPaths() {
        let numstat = "1\t0\tadded.txt\u{0}0\t0\t\u{0}old.txt\u{0}new.txt\u{0}"
        let nameStatus = "A\u{0}added.txt\u{0}R100\u{0}old.txt\u{0}new.txt\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files.map(\.path), ["added.txt", "new.txt"])
        let renamed = files[1]
        XCTAssertEqual(renamed.status, "R")
        XCTAssertEqual(renamed.oldPath, "old.txt")
        XCTAssertEqual(renamed.diffPaths, ["old.txt", "new.txt"])
        XCTAssertEqual(renamed.additions, 0)
    }

    /// A rename that also changed lines — same shape, real counts.
    func testRenameWithEdits() {
        let numstat = "3\t1\t\u{0}src/a.swift\u{0}src/b.swift\u{0}"
        let nameStatus = "R087\u{0}src/a.swift\u{0}src/b.swift\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "src/b.swift")
        XCTAssertEqual(files[0].oldPath, "src/a.swift")
        XCTAssertEqual(files[0].additions, 3)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[0].directory, "src/")
        XCTAssertEqual(files[0].fileName, "b.swift")
    }

    /// "-\t-" is git saying binary. No counts to show, and nothing for a
    /// diff view to render either.
    func testBinaryFile() {
        let numstat = "-\t-\tdocs/icon.png\u{0}2\t2\tREADME.md\u{0}"
        let nameStatus = "M\u{0}docs/icon.png\u{0}M\u{0}README.md\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertEqual(files[0].additions, 0)
        XCTAssertFalse(files[1].isBinary)
    }

    /// A copy behaves like a rename, and paths holding spaces or a tab
    /// survive because the stream is NUL-separated, not line-based.
    func testCopyAndAwkwardPaths() {
        let numstat = "0\t0\t\u{0}a b.txt\u{0}c\td.txt\u{0}5\t0\tplain file.txt\u{0}"
        let nameStatus = "C100\u{0}a b.txt\u{0}c\td.txt\u{0}A\u{0}plain file.txt\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files.map(\.path), ["c\td.txt", "plain file.txt"])
        XCTAssertEqual(files[0].status, "C")
        XCTAssertEqual(files[0].oldPath, "a b.txt")
    }

    /// A mode-only change is counted nowhere by numstat but named by
    /// name-status. Dropping it would hide a real change from the review.
    func testFileOnlyInNameStatusStillAppears() {
        let numstat = "1\t1\tkeep.txt\u{0}"
        let nameStatus = "M\u{0}keep.txt\u{0}T\u{0}script.sh\u{0}"
        let files = GitParsers.reviewFiles(numstat: numstat, nameStatus: nameStatus)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.last?.path, "script.sh")
        XCTAssertEqual(files.last?.status, "T")
        XCTAssertEqual(files.last?.additions, 0)
    }

    /// A counted file with no letter is still a change: shown as modified
    /// rather than dropped for want of a status.
    func testFileOnlyInNumstatDefaultsToModified() {
        let files = GitParsers.reviewFiles(numstat: "2\t0\tsolo.txt\u{0}", nameStatus: "")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, "M")
        XCTAssertEqual(files[0].additions, 2)
    }

    /// An empty diff is an empty list, not a crash — and neither is a
    /// truncated stream, which a killed git can produce.
    func testEmptyAndTruncatedInput() {
        XCTAssertTrue(GitParsers.reviewFiles(numstat: "", nameStatus: "").isEmpty)
        XCTAssertTrue(GitParsers.reviewFiles(numstat: "\u{0}", nameStatus: "\u{0}").isEmpty)
        // A rename record whose paths never arrived.
        XCTAssertTrue(GitParsers.reviewFiles(numstat: "0\t0\t\u{0}", nameStatus: "").isEmpty)
        // A status letter with no path at all.
        XCTAssertTrue(GitParsers.reviewFiles(numstat: "", nameStatus: "M\u{0}").isEmpty)
    }

    /// The same path twice (which a broken or doubled stream can produce)
    /// must not yield two rows — the list is keyed by path.
    func testDuplicatePathsCollapse() {
        let files = GitParsers.reviewFiles(
            numstat: "1\t0\tx.txt\u{0}9\t9\tx.txt\u{0}", nameStatus: "A\u{0}x.txt\u{0}"
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].additions, 1)
    }

    /// A tab in a path. `-z` promises no NULs, not no tabs, so only the two
    /// counts may be split off — the rest of the record is the path,
    /// verbatim. (Fixture from a real `git diff` over a file named
    /// "ta<tab>b.txt".) Splitting on every tab used to truncate it to "ta",
    /// whose diff can't be fetched, and the real path then arrived a second
    /// time out of the name-status pass.
    func testPathContainingTab() {
        let files = GitParsers.reviewFiles(
            numstat: "1\t0\tta\tb.txt\u{0}",
            nameStatus: "A\u{0}ta\tb.txt\u{0}"
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "ta\tb.txt")
        XCTAssertEqual(files[0].status, "A")
        XCTAssertEqual(files[0].additions, 1)
    }

    /// Where the local ref for a review lives — under refs/thegit, which the
    /// graph doesn't walk, so a fetched request draws no badges and adds no
    /// rows.
    func testReviewRefNamespace() {
        XCTAssertEqual(GitClient.reviewRef(number: 30, forge: .github), "refs/thegit/pr/30")
        XCTAssertEqual(GitClient.reviewRef(number: 42, forge: .gitlab), "refs/thegit/mr/42")
    }
}
