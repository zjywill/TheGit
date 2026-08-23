import AIKit
import XCTest
@testable import TheGit

/// The wire protocols themselves live in AIKit, which replays recorded
/// traffic from every vendor against them. What is left here is TheGit's
/// own half of the seam: which catalog entries it offers, how it asks, and
/// what it says when a provider says no. All offline.
final class AIProviderCatalogTests: XCTestCase {

    func testBundledCatalogDecodes() {
        let all = AIProviderCatalog.all
        XCTAssertTrue(AIProviderCatalog.isLoaded, ProviderCatalog.diagnostics)
        XCTAssertGreaterThan(all.count, 10, "AIKit's catalog bundle didn't make it into the build")
        XCTAssertEqual(all.first?.id, "custom-provider", "the bring-your-own entry leads the list")
        // The chooser's front page compactMaps these, so a renamed id
        // upstream would quietly leave a hole in it.
        for id in ["openai", "anthropic", "google", "deepseek", "openrouter", "ollama"] {
            XCTAssertNotNil(AIProviderCatalog.provider(id: id), "\(id) is missing from the catalog")
        }
    }

    /// Only one entry per id, and the bring-your-own one isn't listed twice.
    func testCatalogHasNoDuplicates() {
        let ids = AIProviderCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// A settings pane with one API Key field can't drive a browser login,
    /// so the OAuth-only entries stay out of the list.
    func testOAuthOnlyProvidersAreHidden() {
        XCTAssertNil(AIProviderCatalog.provider(id: "dimcode-api-oauth"))
        XCTAssertFalse(AIProviderCatalog.all.contains { $0.id == "dimcode-api-oauth" })
    }

    /// Settings written before the catalog moved into AIKit still name the
    /// hand-configured endpoint "custom".
    func testLegacyCustomIDStillResolves() {
        XCTAssertEqual(
            AIProviderCatalog.provider(id: AIProviderCatalog.legacyCustomID)?.id,
            AIProviderCatalog.custom.id
        )
    }

    /// Every entry has to be usable: an endpoint, and either models or a
    /// runtime lookup.
    func testEveryProviderIsUsable() {
        for provider in AIProviderCatalog.all where provider.id != AIProviderCatalog.custom.id {
            XCTAssertFalse(provider.baseUrl.isEmpty, "\(provider.id) has no endpoint")
            XCTAssertNotNil(URL(string: provider.baseUrl), "\(provider.id) has a bad endpoint")
            XCTAssertNotNil(provider.wireProtocol, "\(provider.id) speaks a protocol AIKit can't")
            XCTAssertTrue(
                !provider.modelList.isEmpty || provider.needsModelLookup,
                "\(provider.id) offers no models and no way to find any"
            )
        }
    }

    /// The endpoints that decide their own model list — the "fetch models"
    /// button exists for these.
    func testLocalRuntimesAskTheEndpointForModels() throws {
        for id in ["ollama", "lm-studio", AIProviderCatalog.custom.id] {
            let provider = try XCTUnwrap(AIProviderCatalog.provider(id: id))
            XCTAssertTrue(provider.needsModelLookup, "\(id) should look its models up at runtime")
        }
    }

    func testChoosingAProviderLandsOnAModel() throws {
        let anthropic = try XCTUnwrap(AIProviderCatalog.provider(id: "anthropic"))
        XCTAssertFalse(anthropic.startingModelID.isEmpty)
        XCTAssertTrue(anthropic.modelList.contains { $0.id == anthropic.startingModelID })
        // Nothing to land on for an endpoint whose models aren't known yet.
        XCTAssertEqual(AIProviderCatalog.custom.startingModelID, "")
    }
}

final class AIGatewayTests: XCTestCase {

    private func endpoint(_ id: String = "openai", model: String = "m", key: String = "k") -> AIEndpoint {
        AIEndpoint(
            provider: AIProviderCatalog.provider(id: id)
                ?? ProviderInfo(id: id, name: "P", api: "https://x.test", speaking: .openAICompletions),
            baseURL: URL(string: "https://x.test")!,
            apiKey: key,
            model: model
        )
    }

    // MARK: - Requests

    /// Writing a commit message is not a reasoning problem. AIKit turns the
    /// request into whichever dialect the provider speaks; asking for it at
    /// all is TheGit's decision, and this is the one that proves it.
    func testThinkingIsAlwaysOff() {
        let options = AIGateway.callOptions(AIRequest(system: "s", user: "u"), endpoint())
        XCTAssertEqual(options.thinking, .off)
    }

    func testPromptIsOneSystemAndOneUserTurn() {
        let options = AIGateway.callOptions(AIRequest(system: "s", user: "u"), endpoint(model: "gpt-5"))
        XCTAssertEqual(options.model, "gpt-5")
        XCTAssertEqual(options.prompt.map(\.role), [.system, .user])
        XCTAssertEqual(options.prompt.map(\.text), ["s", "u"])
    }

    /// gpt-5 and the o-series reject a cap they weren't asked for, so an
    /// unset budget has to stay unset all the way down.
    func testNoOutputCapUnlessOneWasAskedFor() {
        XCTAssertNil(AIGateway.callOptions(AIRequest(system: "s", user: "u"), endpoint()).maxOutputTokens)
        XCTAssertEqual(
            AIGateway.callOptions(AIRequest(system: "s", user: "u", maxOutputTokens: 16), endpoint())
                .maxOutputTokens,
            16
        )
    }

    // MARK: - Errors

    private func message(_ error: Error) -> String {
        (error as? AIError)?.message ?? error.localizedDescription
    }

    /// A status code alone tells the user nothing about which of the four
    /// settings fields is wrong. Each one names the thing to go fix.
    func testHTTPFailuresNameTheProviderAndTheFix() {
        let target = endpoint("anthropic", model: "claude-x")
        // AIKit's own error type can't be built from outside the package,
        // so the translation is exercised where it lives.
        func said(_ status: Int, _ body: String) -> String {
            message(AIGateway.statusError(status, body: AIErrorBody.message(Data(body.utf8)), endpoint: target))
        }

        let rejected = said(401, #"{"error":{"message":"invalid x-api-key"}}"#)
        XCTAssertTrue(rejected.contains("rejected the API key"))
        XCTAssertTrue(rejected.contains("invalid x-api-key"), "the provider's own words survive")

        XCTAssertTrue(said(404, "").contains("claude-x"))
        XCTAssertTrue(said(429, "").contains("rate limiting"))
        XCTAssertTrue(said(503, "").contains("HTTP 503"))
    }

    func testNetworkFailuresReadAsSentences() {
        let target = endpoint("ollama")
        XCTAssertEqual(
            message(AIGateway.friendly(URLError(.timedOut), endpoint: target)),
            "The request timed out."
        )
        XCTAssertTrue(
            message(AIGateway.friendly(URLError(.cannotConnectToHost), endpoint: target))
                .contains("local server is running")
        )
    }

    func testErrorBodyReadsTheProviderMessage() {
        XCTAssertEqual(
            AIErrorBody.message(Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)),
            "Incorrect API key"
        )
        // A proxy answering with HTML still has to say something useful.
        XCTAssertEqual(AIErrorBody.message(Data("<html>502</html>".utf8)), "<html>502</html>")
        XCTAssertNil(AIErrorBody.message(Data()))
    }
}

final class CommitMessageGeneratorTests: XCTestCase {

    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 111..222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,2 +1,2 @@
    -let a = 1
    +let a = 2
    diff --git a/package-lock.json b/package-lock.json
    index 333..444 100644
    --- a/package-lock.json
    +++ b/package-lock.json
    @@ -1,2 +1,2 @@
    -"version": "1.0.0"
    +"version": "1.0.1"
    diff --git a/Resources/AppIcon.png b/Resources/AppIcon.png
    index 555..666 100644
    Binary files a/Resources/AppIcon.png and b/Resources/AppIcon.png differ
    """

    func testSplitsPerFile() {
        let files = CommitMessageGenerator.files(in: diff)
        XCTAssertEqual(
            files.map(\.path),
            ["Sources/App.swift", "package-lock.json", "Resources/AppIcon.png"]
        )
        XCTAssertTrue(files[0].text.contains("+let a = 2"))
    }

    func testRenameHeaderUsesTheNewPath() {
        XCTAssertEqual(
            CommitMessageGenerator.path(fromHeader: "diff --git a/old.swift b/new.swift"),
            "new.swift"
        )
    }

    func testLockAndBinaryBodiesAreLeftOut() {
        let summary = CommitMessageGenerator.summarize(
            stat: " 3 files changed", diff: diff, budget: 100_000
        )
        XCTAssertTrue(summary.contains("+let a = 2"))
        XCTAssertFalse(summary.contains("\"version\": \"1.0.1\""))
        XCTAssertTrue(summary.contains("package-lock.json (generated or locked file)"))
        XCTAssertTrue(summary.contains("AppIcon.png (binary)"))
    }

    func testNoiseDetection() {
        XCTAssertTrue(CommitMessageGenerator.isNoise(path: "app/pnpm-lock.yaml"))
        XCTAssertTrue(CommitMessageGenerator.isNoise(path: "TheGit.xcodeproj/project.pbxproj"))
        XCTAssertTrue(CommitMessageGenerator.isNoise(path: "web/node_modules/x/index.js"))
        XCTAssertFalse(CommitMessageGenerator.isNoise(path: "Sources/Lock.swift"))
    }

    /// The stat always survives — it is the one part that describes the
    /// whole change — and what got dropped is stated, not hidden.
    func testBudgetKeepsTheStatAndOwnsUpToWhatItDropped() {
        let big = (0..<400).map { "+line \($0)" }.joined(separator: "\n")
        let huge = """
        diff --git a/Big.swift b/Big.swift
        @@ -0,0 +1,400 @@
        \(big)
        """
        let summary = CommitMessageGenerator.summarize(
            stat: " 1 file changed", diff: huge, budget: 200
        )
        XCTAssertTrue(summary.hasPrefix("1 file changed"))
        XCTAssertTrue(summary.contains("Big.swift (over the size budget)"))
        XCTAssertLessThan(summary.count, 400)
    }

    func testPerFileCapCutsOnALineBoundary() {
        let long = (0..<200).map { "+line \($0)" }.joined(separator: "\n")
        let one = "diff --git a/A.swift b/A.swift\n\(long)"
        let summary = CommitMessageGenerator.summarize(
            stat: "", diff: one, budget: 100_000, perFile: 300
        )
        XCTAssertTrue(summary.contains("rest of A.swift truncated"))
        for line in summary.split(separator: "\n") where line.hasPrefix("+line") {
            XCTAssertTrue(line.hasSuffix(String(line.split(separator: " ").last!)))
        }
    }

    // MARK: - Prompt

    func testSystemPromptFollowsTheStyleAndLanguage() {
        let conventional = CommitMessageGenerator.systemPrompt(
            style: .conventional, language: .chinese, extra: "Always mention the ticket."
        )
        XCTAssertTrue(conventional.contains("type(scope): summary"))
        XCTAssertTrue(conventional.contains("简体中文"))
        XCTAssertTrue(conventional.contains("Always mention the ticket."))

        let plain = CommitMessageGenerator.systemPrompt(
            style: .plain, language: .english, extra: ""
        )
        XCTAssertFalse(plain.contains("type(scope)"))
        XCTAssertTrue(plain.contains("Write in English."))
    }

    func testUserPromptCarriesTheDraftAndTheStyleSample() {
        let prompt = CommitMessageGenerator.userPrompt(
            summary: "SUMMARY", recentMessages: ["feat: a", "fix: b"], draft: "wip: caching"
        )
        XCTAssertTrue(prompt.contains("wip: caching"))
        XCTAssertTrue(prompt.contains("feat: a"))
        XCTAssertTrue(prompt.contains("SUMMARY"))
    }

    func testUserPromptOmitsEmptySections() {
        let prompt = CommitMessageGenerator.userPrompt(
            summary: "SUMMARY", recentMessages: [], draft: "   "
        )
        XCTAssertFalse(prompt.contains("statement of intent"))
        XCTAssertFalse(prompt.contains("Recent commit messages"))
    }

    // MARK: - Answer

    func testCleanStripsFencesAndPreamble() {
        XCTAssertEqual(
            CommitMessageGenerator.clean("```\nfix: crash on launch\n```"),
            "fix: crash on launch"
        )
        XCTAssertEqual(
            CommitMessageGenerator.clean("```text\nfix: crash\n\nBody line.\n```"),
            "fix: crash\n\nBody line."
        )
        XCTAssertEqual(
            CommitMessageGenerator.clean("Commit message:\nfix: crash"),
            "fix: crash"
        )
        // A message that legitimately contains a fence keeps it.
        XCTAssertEqual(
            CommitMessageGenerator.clean("fix: crash\n\nSee ```swift``` below."),
            "fix: crash\n\nSee ```swift``` below."
        )
    }

    // MARK: - Pull request generator

    func testPRParseSplitsTitleAndBody() {
        let (title, body) = PullRequestGenerator.parse(
            "Add drag to reorder tabs\n\nTabs now move like browser tabs.\n- detail"
        )
        XCTAssertEqual(title, "Add drag to reorder tabs")
        XCTAssertEqual(body, "Tabs now move like browser tabs.\n- detail")
    }

    func testPRParseStripsLabelsHeadingsAndFences() {
        let fenced = PullRequestGenerator.parse(
            "```markdown\nTitle: Fix the crash\n\nDescription:\nIt crashed.\n```"
        )
        XCTAssertEqual(fenced.title, "Fix the crash")
        XCTAssertEqual(fenced.body, "It crashed.")

        let heading = PullRequestGenerator.parse("# Fix the crash\n\nIt crashed.")
        XCTAssertEqual(heading.title, "Fix the crash")

        // A body whose first line merely *contains* a colon keeps it.
        let plain = PullRequestGenerator.parse("Fix crash\n\nNote: see below.")
        XCTAssertEqual(plain.body, "Note: see below.")
    }

    func testPRParseTitleOnlyAndEmpty() {
        let solo = PullRequestGenerator.parse("Fix the crash")
        XCTAssertEqual(solo.title, "Fix the crash")
        XCTAssertEqual(solo.body, "")

        // Leading blank lines don't become the title.
        let padded = PullRequestGenerator.parse("\n\nFix the crash\n\nBody.")
        XCTAssertEqual(padded.title, "Fix the crash")

        let empty = PullRequestGenerator.parse("")
        XCTAssertEqual(empty.title, "")
        XCTAssertEqual(empty.body, "")
    }

    func testPRSystemPromptNamesTheForgeNoun() {
        let gh = PullRequestGenerator.systemPrompt(forge: .github, language: .english, extra: "")
        XCTAssertTrue(gh.contains("pull request"))
        let gl = PullRequestGenerator.systemPrompt(forge: .gitlab, language: .chinese, extra: "No emoji.")
        XCTAssertTrue(gl.contains("merge request"))
        XCTAssertTrue(gl.contains("简体中文"))
        XCTAssertTrue(gl.hasSuffix("No emoji."))
    }

    func testPRUserPromptCarriesCommitsAndDiff() {
        let prompt = PullRequestGenerator.userPrompt(
            source: "feature/x",
            target: "main",
            commits: ["feat: one", "fix: two"],
            summary: "2 files changed"
        )
        XCTAssertTrue(prompt.contains("`feature/x`"))
        XCTAssertTrue(prompt.contains("`main`"))
        XCTAssertTrue(prompt.contains("feat: one"))
        XCTAssertTrue(prompt.contains("2 files changed"))

        let bare = PullRequestGenerator.userPrompt(
            source: "a", target: "b", commits: [], summary: "diff"
        )
        XCTAssertFalse(bare.contains("commit messages"))
    }
}
