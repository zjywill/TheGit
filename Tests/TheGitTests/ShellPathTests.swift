import XCTest
@testable import TheGit

/// Finding a binary ourselves only gets the first process started. git runs
/// `git-lfs` as a filter and a pre-push hook, `gh` and `glab` shell out to
/// git, and every one of those searches PATH — so the PATH we hand a child
/// has to be the same list `which` searched, not launchd's bare one.
final class ShellPathTests: XCTestCase {

    /// What a child actually got, with the newline `printf` doesn't add.
    private func childPATH(env: [String: String] = [:]) async throws -> String {
        try await Shell.run("/bin/sh", ["-c", "printf %s \"$PATH\""], env: env)
    }

    func testChildGetsTheSearchPath() async throws {
        let path = try await childPATH()
        XCTAssertEqual(path, Shell.childPath())
    }

    /// The Homebrew prefixes are the whole point: a double-clicked .app
    /// inherits a PATH without them, and git-lfs lives in one of them.
    func testSearchPathCarriesTheInstallPrefixes() async throws {
        let dirs = Shell.searchDirs()
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "missing from \(dirs)")
        XCTAssertTrue(dirs.contains("/usr/local/bin"), "missing from \(dirs)")
    }

    /// The three lists overlap heavily — a PATH repeating /usr/bin four
    /// times is a slower lookup and an unreadable one in a bug report.
    func testSearchPathHasNoDuplicates() {
        let dirs = Shell.searchDirs()
        XCTAssertEqual(dirs.count, Set(dirs).count, "duplicates in \(dirs)")
    }

    /// Callers pass env for git's sake (GIT_PAGER and friends); handing one
    /// over must not cost the child its PATH.
    func testCallerEnvironmentKeepsThePath() async throws {
        let path = try await childPATH(env: ["GIT_PAGER": "cat"])
        XCTAssertEqual(path, Shell.childPath())
    }
}
