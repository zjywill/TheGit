import XCTest
@testable import TheGit

final class LFSParserTests: XCTestCase {

    // MARK: - ls-files

    /// Verbatim `git lfs ls-files`: "<oid> <*|-> <path>", where `-` means
    /// the object was never downloaded.
    func testParseLsFiles() {
        let output = """
        2bff8d8255 * art.psd
        812fa82227 - assets/big model.blend
        """
        let files = LFSParsers.lsFiles(output)
        XCTAssertEqual(files.map(\.path), ["art.psd", "assets/big model.blend"])
        XCTAssertEqual(files.map(\.downloaded), [true, false])
        XCTAssertEqual(files[0].oid, "2bff8d8255")
        XCTAssertEqual(files[1].fileName, "big model.blend")
    }

    func testLsFilesIgnoresShortLines() {
        XCTAssertTrue(LFSParsers.lsFiles("garbage\n\n").isEmpty)
    }

    func testNotDownloadedCount() {
        let status = LFSStatus(patterns: ["*.psd"], files: LFSParsers.lsFiles("""
        a * one.psd
        b - two.psd
        c - three.psd
        """))
        XCTAssertEqual(status.notInLocalStore.count, 2)
        XCTAssertTrue(status.isEnabled)
        XCTAssertFalse(LFSStatus().isEnabled)
    }

    // MARK: - .gitattributes

    /// The line `git lfs track` writes, plus lines that are none of our
    /// business.
    func testTrackedPatterns() {
        let attributes = """
        # comments are skipped
        *.psd filter=lfs diff=lfs merge=lfs -text
        *.md text
        assets/**/*.bin filter=lfs diff=lfs merge=lfs -text
        *.png -filter
        """
        XCTAssertEqual(
            LFSParsers.trackedPatterns(gitattributes: attributes),
            ["*.psd", "assets/**/*.bin"]
        )
    }

    /// git escapes a space in a pattern; show it back as a space.
    func testTrackedPatternWithSpace() {
        XCTAssertEqual(
            LFSParsers.trackedPatterns(
                gitattributes: "my[[:space:]]assets/*.bin filter=lfs diff=lfs merge=lfs -text"
            ),
            ["my assets/*.bin"]
        )
    }

    func testNoLFSPatterns() {
        XCTAssertTrue(LFSParsers.trackedPatterns(gitattributes: "* text=auto\n").isEmpty)
    }

    // MARK: - Pointer diffs

    /// A modified LFS file: `version` stays context, oid and size move.
    func testPointerDiffOfAModifiedFile() {
        let diff = """
        diff --git a/art.psd b/art.psd
        index df915ff..721938f 100644
        --- a/art.psd
        +++ b/art.psd
        @@ -1,3 +1,3 @@
         version https://git-lfs.github.com/spec/v1
        -oid sha256:2bff8d825500aae74df372b167f4b025ac962b100cdd0229ce3245ae824d89fc
        -size 200000
        +oid sha256:812fa82227414e6cf4f2882a0b0387a2d2d09d033dc56c75012d5ab3b09288b7
        +size 150000
        """
        let parsed = LFSParsers.pointerDiff(diff)
        XCTAssertEqual(parsed?.old?.size, 200_000)
        XCTAssertEqual(parsed?.new?.size, 150_000)
        XCTAssertEqual(parsed?.old?.shortOID, "2bff8d825500")
        XCTAssertEqual(parsed?.sizeDelta, -50_000)
    }

    func testPointerDiffOfANewFile() {
        let diff = """
        diff --git a/art.psd b/art.psd
        new file mode 100644
        index 0000000..df915ff
        --- /dev/null
        +++ b/art.psd
        @@ -0,0 +1,3 @@
        +version https://git-lfs.github.com/spec/v1
        +oid sha256:2bff8d8255
        +size 200000
        """
        let parsed = LFSParsers.pointerDiff(diff)
        XCTAssertNil(parsed?.old)
        XCTAssertEqual(parsed?.new?.size, 200_000)
        XCTAssertNil(parsed?.sizeDelta)
    }

    /// An ordinary text diff is not a pointer diff, even one that talks
    /// about sizes and versions.
    func testOrdinaryDiffIsNotAPointer() {
        let diff = """
        diff --git a/notes.txt b/notes.txt
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1,2 +1,2 @@
        -size 42
        +size 43
         version 2
        """
        XCTAssertNil(LFSParsers.pointerDiff(diff))
    }

    func testEmptyDiffIsNotAPointer() {
        XCTAssertNil(LFSParsers.pointerDiff(""))
    }

    /// Every textual diff the app opens is offered to this parser, so a
    /// large one must be refused before it is walked line by line rather
    /// than after — that pass is main-thread work proportional to the
    /// diff, spent to answer "no" about a file that was never LFS.
    func testLargeDiffIsRefusedWithoutBeingWalked() {
        let body = (1...5000).map { "+line \($0)" }.joined(separator: "\n")
        let diff = """
        diff --git a/big.txt b/big.txt
        --- a/big.txt
        +++ b/big.txt
        @@ -0,0 +1,5000 @@
        \(body)
        """
        XCTAssertGreaterThan(diff.utf8.count, 8192)
        XCTAssertNil(LFSParsers.pointerDiff(diff))
    }

    /// The refusal must not reach a real pointer diff. A rename repeats
    /// the path six times over the headers, and a path can run to 1024
    /// bytes — the longest pointer diff that can exist still parses.
    func testLongestPossiblePointerDiffStillParses() {
        let deep = (1...30).map { _ in String(repeating: "d", count: 30) }
            .joined(separator: "/")
        let oldPath = deep + "/before.psd"
        let newPath = deep + "/after.psd"
        let diff = """
        diff --git a/\(oldPath) b/\(newPath)
        similarity index 88%
        rename from \(oldPath)
        rename to \(newPath)
        index df915ff..721938f 100644
        --- a/\(oldPath)
        +++ b/\(newPath)
        @@ -1,3 +1,3 @@
         version https://git-lfs.github.com/spec/v1
        -oid sha256:2bff8d825500aae74df372b167f4b025ac962b100cdd0229ce3245ae824d89fc
        -size 200000
        +oid sha256:812fa82227414e6cf4f2882a0b0387a2d2d09d033dc56c75012d5ab3b09288b7
        +size 150000
        """
        XCTAssertGreaterThan(oldPath.utf8.count, 900)
        XCTAssertEqual(LFSParsers.pointerDiff(diff)?.old?.size, 200_000)
        XCTAssertEqual(LFSParsers.pointerDiff(diff)?.new?.size, 150_000)
    }

    // MARK: - Presentation

    func testShortOIDAndSize() {
        let pointer = LFSPointer(
            oid: "sha256:2bff8d825500aae74df372b167f4b025ac962b100cdd0229ce3245ae824d89fc",
            size: 200_000
        )
        XCTAssertEqual(pointer.shortOID, "2bff8d825500")
        XCTAssertFalse(pointer.formattedSize.isEmpty)
    }
}
