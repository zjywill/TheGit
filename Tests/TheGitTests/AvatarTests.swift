import XCTest
@testable import TheGit

final class AvatarTests: XCTestCase {

    // MARK: - log parsing with the email field

    /// The format is hash/parents/author/email/date/refs/subject. Adding a
    /// field shifted every index after it, so this pins the whole row.
    func testParseLogReadsEmail() {
        let line = [
            "abc123", "p1 p2", "Junyi Zhang", "zjywill@gmail.com",
            "1700000000", "HEAD -> main, origin/main", "feat: add avatars",
        ].joined(separator: "\t")
        let commits = GitParsers.parseLog(line)
        XCTAssertEqual(commits.count, 1)
        let commit = commits[0]
        XCTAssertEqual(commit.hash, "abc123")
        XCTAssertEqual(commit.parents, ["p1", "p2"])
        XCTAssertEqual(commit.author, "Junyi Zhang")
        XCTAssertEqual(commit.email, "zjywill@gmail.com")
        XCTAssertEqual(commit.date.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(commit.refs, ["HEAD -> main", "origin/main"])
        XCTAssertEqual(commit.subject, "feat: add avatars")
    }

    /// The subject is last precisely because it can contain tabs.
    func testParseLogKeepsTabsInSubject() {
        let line = "h\t\tA\ta@b.c\t1\t\tsubject\twith\ttabs"
        XCTAssertEqual(GitParsers.parseLog(line).first?.subject, "subject\twith\ttabs")
    }

    func testParseLogSkipsShortLines() {
        XCTAssertTrue(GitParsers.parseLog("h\tp\tA\ta@b.c").isEmpty)
    }

    // MARK: - Gravatar key

    /// Gravatar hashes the trimmed, lower-cased address; verified against
    /// `printf %s zjywill@gmail.com | md5`.
    func testGravatarKey() {
        XCTAssertEqual(
            AvatarStore.key(for: "zjywill@gmail.com"),
            "365d67d1aaaac03a98a27ce402309b04"
        )
        XCTAssertEqual(
            AvatarStore.key(for: "  ZJYWill@Gmail.COM \n"),
            "365d67d1aaaac03a98a27ce402309b04"
        )
    }

    /// git allows a bare name as the author email; there's nothing to hash.
    func testNoKeyWithoutAnAddress() {
        XCTAssertNil(AvatarStore.key(for: ""))
        XCTAssertNil(AvatarStore.key(for: "not-an-email"))
    }

    // MARK: - GitHub noreply fallback

    func testGitHubUsernameFromNoreplyAddress() {
        XCTAssertEqual(
            AvatarStore.githubUsername(from: "1234567+octocat@users.noreply.github.com"),
            "octocat"
        )
        // Older accounts have no numeric prefix.
        XCTAssertEqual(
            AvatarStore.githubUsername(from: "octocat@users.noreply.github.com"),
            "octocat"
        )
        XCTAssertNil(AvatarStore.githubUsername(from: "octocat@example.com"))
        XCTAssertNil(AvatarStore.githubUsername(from: "@users.noreply.github.com"))
    }

    /// Gravatar first, GitHub only as a fallback and only when the address
    /// says so — a normal address must not trigger a GitHub lookup.
    func testSourceOrderAndScope() {
        let key = AvatarStore.key(for: "1+octocat@users.noreply.github.com")!
        let both = AvatarStore.sources(key: key, email: "1+octocat@users.noreply.github.com")
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[0].host, "www.gravatar.com")
        // d=404 is what makes a miss a miss instead of a stranger's face.
        XCTAssertTrue(both[0].absoluteString.contains("d=404"))
        XCTAssertEqual(both[1].host, "avatars.githubusercontent.com")
        XCTAssertTrue(both[1].absoluteString.contains("octocat"))

        let onlyGravatar = AvatarStore.sources(key: key, email: "someone@example.com")
        XCTAssertEqual(onlyGravatar.count, 1)
    }

    // MARK: - Forge-provided URLs

    /// The forge is the authority: its identicon choice is what its own web
    /// UI shows, so it passes through untouched apart from the size.
    func testForgeURLIsUsedVerbatimApartFromSize() {
        let url = AvatarStore.normalizedAvatarURL(
            "https://secure.gravatar.com/avatar/abc?s=128&d=identicon"
        )!
        XCTAssertTrue(url.absoluteString.contains("d=identicon"))
        XCTAssertTrue(url.absoluteString.contains("s=64"))
        XCTAssertFalse(url.absoluteString.contains("s=128"))
    }

    /// A self-hosted GitLab upload has no query to rewrite.
    func testSelfHostedAvatarURLPassesThrough() {
        let raw = "https://gitlab.example.com/uploads/-/system/user/avatar/84/avatar.png"
        XCTAssertEqual(AvatarStore.normalizedAvatarURL(raw)?.absoluteString, raw)
    }

    /// Guessing at Gravatar from an email is the one path that must insist
    /// on a real avatar — otherwise every unknown author gets a stranger's
    /// generated pattern instead of readable initials.
    func testEmailGuessDemandsARealAvatar() {
        let key = AvatarStore.key(for: "someone@example.com")!
        let guessed = AvatarStore.sources(key: key, email: "someone@example.com")
        XCTAssertTrue(guessed[0].absoluteString.contains("d=404"))
    }

    // MARK: - The "never render a broken image" guarantee

    func testOnlyRealImagesPassTheDecodeCheck() {
        XCTAssertFalse(AvatarStore.isDecodableImage(Data()))
        // What a proxy or captive portal actually returns on failure.
        XCTAssertFalse(AvatarStore.isDecodableImage(Data("<html>404</html>".utf8)))
        // A truncated PNG: right magic bytes, no decodable image.
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        XCTAssertFalse(AvatarStore.isDecodableImage(truncated))

        XCTAssertTrue(AvatarStore.isDecodableImage(Self.onePixelPNG))
    }

    /// Smallest valid PNG: 1x1, opaque.
    private static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
        IQAAAABJRU5ErkJggg==
        """)!
}
