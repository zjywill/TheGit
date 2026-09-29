import XCTest
@testable import TheGit

/// Clone and Init (issue #11): the address handling as plain functions, and
/// the clone itself against a real repository on disk.
@MainActor
final class CloneTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-clone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A repository with one commit, to clone from.
    private func makeOrigin() async throws -> String {
        let path = root.appendingPathComponent("origin").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main", "."],
                     ["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-q",
                      "--allow-empty", "-m", "first"]] {
            try await Shell.run("/usr/bin/env", ["git", "-C", path] + args)
        }
        return path
    }

    // MARK: - The address

    func testFolderNameFollowsWhatGitWouldChoose() {
        let cases: [(String, String?)] = [
            ("https://github.com/zjywill/TheGit.git", "TheGit"),
            ("https://github.com/zjywill/TheGit", "TheGit"),
            ("https://github.com/zjywill/TheGit/", "TheGit"),
            ("git@github.com:zjywill/TheGit.git", "TheGit"),
            ("git@github.com:TheGit.git", "TheGit"),
            ("ssh://git@host:2222/team/app.git", "app"),
            ("/Users/me/Git/some-repo.git", "some-repo"),
            ("  https://host/a/b.git  ", "b"),
            ("", nil),
            ("///", nil),
            ("https://host/a/.git", nil),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(Clone.folderName(from: url), expected, url)
        }
    }

    /// `git clone --upload-pack=…` runs the command it is given. Nothing that
    /// starts with a dash is ever an address, and neither is anything with
    /// whitespace in it.
    func testAnOptionIsNeverAnAddress() {
        XCTAssertFalse(Clone.isUsable("--upload-pack=touch /tmp/x"))
        XCTAssertFalse(Clone.isUsable("-u"))
        XCTAssertFalse(Clone.isUsable("https://host/a b"))
        XCTAssertFalse(Clone.isUsable("   "))
        XCTAssertTrue(Clone.isUsable("https://host/a.git"))
        XCTAssertTrue(Clone.isUsable("/tmp/some/local/repo"))
    }

    func testOnlyAnAddressIsOfferedFromThePasteboard() {
        for text in ["https://github.com/a/b", "git@github.com:a/b.git", "ssh://git@h/a/b",
                     "  https://gitlab.com/g/p.git\n"] {
            XCTAssertTrue(Clone.looksLikeRemote(text), text)
        }
        for text in ["hello world", "fix the thing", "/Users/me/file.txt", "user@example.com",
                     "--upload-pack=x", ""] {
            XCTAssertFalse(Clone.looksLikeRemote(text), text)
        }
    }

    // MARK: - Progress

    func testProgressReadsTheNewestRedraw() {
        // git redraws in place with \r, so one read holds several.
        let chunk = "Receiving objects:  10% (100/1000)\rReceiving objects:  45% (450/1000), 1.2 MiB | 2.3 MiB/s\r"
        XCTAssertEqual(Clone.progress(in: chunk), Clone.Progress(phase: "Receiving objects", percent: 45))
        XCTAssertEqual(
            Clone.progress(in: "remote: Compressing objects: 100% (30/30), done.\n"),
            Clone.Progress(phase: "Compressing objects", percent: 100)
        )
        XCTAssertEqual(
            Clone.progress(in: "Resolving deltas:  7% (7/100)"),
            Clone.Progress(phase: "Resolving deltas", percent: 7)
        )
        XCTAssertEqual(
            Clone.progress(in: "Updating files: 100% (12/12), done.\n"),
            Clone.Progress(phase: "Updating files", percent: 100)
        )
    }

    func testLinesWithNoProgressSayNothing() {
        XCTAssertNil(Clone.progress(in: "Cloning into 'repo'...\n"))
        XCTAssertNil(Clone.progress(in: "warning: You appear to have cloned an empty repository.\n"))
        XCTAssertNil(Clone.progress(in: ""))
    }

    // MARK: - Failures, in words

    func testAuthenticationFailuresSayWhatToDoAboutIt() {
        let https = Clone.explain("fatal: could not read Username for 'https://github.com': terminal prompts disabled")
        XCTAssertTrue(https.contains("gh auth login"))
        let ssh = Clone.explain("git@github.com: Permission denied (publickey).")
        XCTAssertTrue(ssh.contains("SSH key"))
        let host = Clone.explain("Host key verification failed.")
        XCTAssertTrue(host.contains("ssh -T"))
        // Anything else is git's own sentence, untouched.
        XCTAssertEqual(Clone.explain("fatal: repository 'x' not found\n"), "fatal: repository 'x' not found")
    }

    // MARK: - Cloning

    func testCloneLandsInTheFolderItWasAskedFor() async throws {
        let origin = try await makeOrigin()
        let parent = root.appendingPathComponent("into").path

        let path = try await Clone.run(url: origin, into: parent, name: "copy") { _ in }

        XCTAssertEqual(path, parent + "/copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/.git"))
        let subject = try await Shell.run("/usr/bin/env", ["git", "-C", path, "log", "-1", "--format=%s"])
        XCTAssertEqual(subject.trimmingCharacters(in: .whitespacesAndNewlines), "first")
    }

    /// The transport that talks like a network one, so git has progress to say.
    func testCloneReportsProgress() async throws {
        let origin = try await makeOrigin()
        let seen = ProgressBox()

        _ = try await Clone.run(
            url: "file://" + origin, into: root.path, name: "with-progress"
        ) { seen.add($0) }

        XCTAssertFalse(seen.values.isEmpty, "git was told to report progress and reported none")
        XCTAssertTrue(seen.values.allSatisfy { (0...100).contains($0.percent) })
    }

    /// The clean-up on failure removes the folder git made — and must never be
    /// able to reach a folder that was already there.
    func testCloneNeverTouchesAFolderThatAlreadyExists() async throws {
        let origin = try await makeOrigin()
        let existing = root.appendingPathComponent("mine").path
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        try "keep me".write(toFile: existing + "/notes.txt", atomically: true, encoding: .utf8)

        do {
            _ = try await Clone.run(url: origin, into: root.path, name: "mine") { _ in }
            XCTFail("cloning over an existing folder should have been refused")
        } catch let failure as Clone.Failure {
            XCTAssertTrue(failure.message.contains("already exists"))
        }
        XCTAssertEqual(
            try String(contentsOfFile: existing + "/notes.txt", encoding: .utf8), "keep me"
        )
    }

    func testAFailedCloneLeavesNothingBehind() async throws {
        let missing = root.appendingPathComponent("no-such-origin").path
        do {
            _ = try await Clone.run(url: missing, into: root.path, name: "ghost") { _ in }
            XCTFail("cloning a repository that isn't there should fail")
        } catch is Clone.Failure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/ghost"))
    }

    func testACancelledCloneLeavesNothingBehind() async throws {
        let origin = try await makeOrigin()
        let task = Task { try await Clone.run(url: origin, into: root.path, name: "stopped") { _ in } }
        task.cancel()
        _ = await task.result
        // Either git never started or it was stopped mid-way; either way the
        // folder must be gone, or a retry under the same name would be refused.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/stopped/.git"))
    }

    // MARK: - Init

    func testInitMakesARepository() async throws {
        let folder = root.appendingPathComponent("fresh").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        try await Clone.initialize(at: folder)

        let inside = try await Shell.run(
            "/usr/bin/env", ["git", "-C", folder, "rev-parse", "--is-inside-work-tree"]
        )
        XCTAssertEqual(inside.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    /// A folder-picker slip on the home directory must not be one click from
    /// turning every file the user owns into an untracked one.
    func testHomeAndRootAreNeverOfferedForInit() {
        XCTAssertFalse(Clone.canInitialize(NSHomeDirectory()))
        XCTAssertFalse(Clone.canInitialize("/"))
        XCTAssertTrue(Clone.canInitialize(root.path))
    }

    // MARK: - The sheet's state

    func testFolderNameFollowsTheAddressUntilItIsTypedOver() {
        let model = CloneModel()
        model.url = "https://github.com/a/first.git"
        XCTAssertEqual(model.name, "first")
        model.url = "https://github.com/a/second.git"
        XCTAssertEqual(model.name, "second")

        model.setName("mine")
        model.url = "https://github.com/a/third.git"
        XCTAssertEqual(model.name, "mine", "a name chosen on purpose is not overwritten")
    }

    func testCloneIsOffUntilThereIsSomethingToClone() throws {
        let model = CloneModel()
        model.parent = root.path
        XCTAssertFalse(model.canStart)
        XCTAssertNil(model.problem, "an empty form shouldn't open already complaining")

        model.url = "--upload-pack=x"
        XCTAssertFalse(model.canStart)
        XCTAssertNotNil(model.problem)

        model.url = "https://github.com/a/repo.git"
        XCTAssertTrue(model.canStart)
        XCTAssertNil(model.problem)

        try FileManager.default.createDirectory(
            atPath: root.path + "/repo", withIntermediateDirectories: true
        )
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.problem, "“repo” already exists in that folder.")
    }
}

/// Progress arrives on a background thread; the test reads it afterwards.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Clone.Progress] = []
    var values: [Clone.Progress] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ p: Clone.Progress) { lock.lock(); stored.append(p); lock.unlock() }
}
