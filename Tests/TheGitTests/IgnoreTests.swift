import XCTest
@testable import TheGit

final class IgnoreTests: XCTestCase {

    // MARK: - Pattern building

    func testFilePatternIsAnchoredToRepoRoot() {
        XCTAssertEqual(GitIgnore.filePattern("src/build.log"), "/src/build.log")
    }

    func testDirectoryPatternEndsWithOneSlash() {
        // FileChange.directory already carries a trailing slash.
        XCTAssertEqual(GitIgnore.directoryPattern("src/gen/"), "/src/gen/")
        XCTAssertEqual(GitIgnore.directoryPattern("src/gen"), "/src/gen/")
    }

    func testExtensionPatternMatchesAnywhere() {
        XCTAssertEqual(GitIgnore.extensionPattern("log"), "*.log")
    }

    /// A path with glob characters must still match only itself —
    /// "notes[draft].md" unescaped is a character class, not a file.
    func testGlobCharactersAreEscaped() {
        XCTAssertEqual(GitIgnore.filePattern("notes[draft].md"), "/notes\\[draft].md")
        XCTAssertEqual(GitIgnore.filePattern("a*b?c.txt"), "/a\\*b\\?c.txt")
        XCTAssertEqual(GitIgnore.filePattern("back\\slash"), "/back\\\\slash")
    }

    /// Leading '#' is a comment and leading '!' a negation, so an
    /// extension that starts with one has to be escaped.
    func testLeadingCommentAndNegationMarkersAreEscaped() {
        XCTAssertEqual(GitIgnore.escape("#temp"), "\\#temp")
        XCTAssertEqual(GitIgnore.escape("!important"), "\\!important")
        // Not at the front: nothing special about them.
        XCTAssertEqual(GitIgnore.escape("a#b"), "a#b")
    }

    /// git strips unescaped trailing whitespace from a pattern.
    func testTrailingSpaceIsEscaped() {
        XCTAssertEqual(GitIgnore.escape("weird name "), "weird name\\ ")
    }

    // MARK: - Appending to the ignore file

    func testAppendAddsMissingNewlineFirst() {
        XCTAssertEqual(GitIgnore.append("/b", to: "/a"), "/a\n/b\n")
        XCTAssertEqual(GitIgnore.append("/b", to: "/a\n"), "/a\n/b\n")
        XCTAssertEqual(GitIgnore.append("/b", to: ""), "/b\n")
    }

    /// Ignoring the same thing twice is a no-op, not a duplicate line.
    func testAppendSkipsPatternsAlreadyListed() {
        XCTAssertNil(GitIgnore.append("*.log", to: "# build\n*.log\n/dist/\n"))
        // Whitespace around an existing line still counts as listed.
        XCTAssertNil(GitIgnore.append("*.log", to: "  *.log  \n"))
    }

    /// A .gitignore written on Windows: every line ends \r\n, and the
    /// pattern is still already there.
    func testAppendSeesPatternsInACRLFFile() {
        XCTAssertNil(GitIgnore.append("*.log", to: "# build\r\n*.log\r\n"))
    }

    func testAppendKeepsUnrelatedSimilarPatterns() {
        XCTAssertEqual(GitIgnore.append("*.log", to: "*.logs\n"), "*.logs\n*.log\n")
    }
}

@MainActor
final class SubmodulePathTests: XCTestCase {

    /// The folder git itself would clone into, for each URL shape.
    func testDefaultPathFromURL() {
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "https://github.com/me/lib.git"), "lib")
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "https://github.com/me/lib"), "lib")
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "git@github.com:me/lib.git"), "lib")
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "https://github.com/me/lib/"), "lib")
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "  /local/path/lib  "), "lib")
        // scp-style without a directory: everything after the colon.
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: "git@host:lib.git"), "lib")
        XCTAssertEqual(RepoState.defaultSubmodulePath(for: ""), "")
    }
}
