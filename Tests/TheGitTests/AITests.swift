import XCTest
@testable import TheGit

/// Everything here is offline: request building and response parsing are
/// pure functions on strings, which is the whole reason they are separate
/// from AIClient.
final class AIProviderCatalogTests: XCTestCase {

    func testBundledCatalogDecodes() {
        let all = AIProviderCatalog.all
        XCTAssertGreaterThan(all.count, 10, "providers.json didn't make it into the bundle")
        XCTAssertEqual(all.first?.id, "custom", "the bring-your-own entry leads the list")
        XCTAssertNotNil(AIProviderCatalog.provider(id: "anthropic"))
    }

    /// Every entry has to be usable: an endpoint, and either models or a
    /// runtime lookup.
    func testEveryProviderIsUsable() {
        for provider in AIProviderCatalog.all where provider.id != "custom" {
            XCTAssertFalse(provider.baseUrl.isEmpty, "\(provider.id) has no endpoint")
            XCTAssertNotNil(URL(string: provider.baseUrl), "\(provider.id) has a bad endpoint")
            XCTAssertTrue(
                !provider.models.isEmpty || provider.needsModelLookup,
                "\(provider.id) offers no models and no way to find any"
            )
        }
    }

    func testUnknownAdapterFallsBackToOpenAI() throws {
        let json = """
        {"id":"x","name":"X","adapter":"openai-responses","auth":{"header":"Authorization","prefix":"Bearer "},"baseUrl":"https://x.test","models":[]}
        """
        let provider = try JSONDecoder().decode(AIProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.adapter, .openai)
    }
}

final class AIWireTests: XCTestCase {

    private func endpoint(
        _ adapter: AIAdapterKind,
        base: String,
        model: String = "m",
        header: String = "Authorization",
        prefix: String = "Bearer ",
        noThink: AIThinkingOff? = nil
    ) -> AIEndpoint {
        let provider = AIProvider(
            id: "p", name: "P", adapter: adapter,
            auth: .init(header: header, prefix: prefix),
            baseUrl: base, defaultModelId: nil, customModels: nil, models: []
        )
        return AIEndpoint(
            provider: provider, baseURL: URL(string: base)!, apiKey: "k",
            model: model, noThink: noThink
        )
    }

    private func body(_ wire: AIWireAdapter, _ endpoint: AIEndpoint) throws -> [String: Any] {
        let data = try wire.body(AIRequest(system: "s", user: "u"), endpoint)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - URLs

    func testOpenAIChatURL() {
        XCTAssertEqual(
            OpenAIWire().chatURL(endpoint(.openai, base: "https://api.openai.com/v1")).absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        // DeepSeek's endpoint carries no version segment and serves the
        // unversioned path too.
        XCTAssertEqual(
            OpenAIWire().chatURL(endpoint(.openai, base: "https://api.deepseek.com")).absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
    }

    /// MiniMax's Anthropic endpoint already ends in /v1; "v1/messages" on
    /// top of it would be /v1/v1/messages.
    func testAnthropicURLDoesNotDoubleTheVersion() {
        XCTAssertEqual(
            AnthropicWire().chatURL(endpoint(.anthropic, base: "https://api.anthropic.com")).absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            AnthropicWire().chatURL(endpoint(.anthropic, base: "https://api.minimax.io/anthropic/v1")).absoluteString,
            "https://api.minimax.io/anthropic/v1/messages"
        )
    }

    func testGeminiChatURLKeepsTheActionSuffix() {
        let url = GeminiWire().chatURL(
            endpoint(.gemini, base: "https://generativelanguage.googleapis.com/v1beta",
                     model: "gemini-3-flash")
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:streamGenerateContent?alt=sse"
        )
    }

    // MARK: - Requests

    func testOpenAIBodyOmitsTemperatureAndMaxTokens() throws {
        // gpt-5 and the o-series reject both outright.
        let data = try OpenAIWire().body(
            AIRequest(system: "s", user: "u"), endpoint(.openai, base: "https://x.test")
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    func testAnthropicBodyCarriesMaxTokensAndTopLevelSystem() throws {
        let data = try AnthropicWire().body(
            AIRequest(system: "s", user: "u", maxOutputTokens: 512),
            endpoint(.anthropic, base: "https://x.test")
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["system"] as? String, "s")
    }

    // MARK: - Thinking

    /// Writing a commit message is not a reasoning problem, so a model that
    /// thinks by default gets told not to — in its own provider's dialect.
    func testThinkingIsSwitchedOffInTheProvidersOwnDialect() throws {
        // deepseek-v4-flash and friends.
        let disabled = try body(
            OpenAIWire(),
            endpoint(.openai, base: "https://x.test", noThink: .init(off: "thinking_type", effort: "high"))
        )
        XCTAssertEqual(disabled["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertNil(disabled["reasoning_effort"], "the off switch wins over turning it down")

        let qwen = try body(
            OpenAIWire(),
            endpoint(.openai, base: "https://x.test", noThink: .init(off: "enable_thinking"))
        )
        XCTAssertEqual(qwen["enable_thinking"] as? Bool, false)

        // gpt-5: can't be off, so it goes as low as it goes.
        let effort = try body(
            OpenAIWire(),
            endpoint(.openai, base: "https://x.test", noThink: .init(effort: "minimal"))
        )
        XCTAssertEqual(effort["reasoning_effort"] as? String, "minimal")
    }

    /// A model the endpoint reported at runtime has no catalog entry, and a
    /// knob a server doesn't recognise is a 400.
    func testUnknownModelGetsNoThinkingKnobs() throws {
        let plain = try body(OpenAIWire(), endpoint(.openai, base: "https://x.test"))
        XCTAssertNil(plain["thinking"])
        XCTAssertNil(plain["reasoning_effort"])
        XCTAssertNil(plain["enable_thinking"])
    }

    func testGeminiOnlyZeroesTheBudgetWhenTheModelOffersAMinimalTier() throws {
        let minimal = try body(
            GeminiWire(),
            endpoint(.gemini, base: "https://g.test", noThink: .init(effort: "minimal"))
        )
        let config = try XCTUnwrap(minimal["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["thinkingConfig"] as? [String: Int], ["thinkingBudget": 0])

        // Pro tiers clamp to a floor and reject 0.
        let medium = try body(
            GeminiWire(),
            endpoint(.gemini, base: "https://g.test", noThink: .init(effort: "medium"))
        )
        XCTAssertNil((medium["generationConfig"] as? [String: Any])?["thinkingConfig"])
    }

    /// Extended thinking is opt-in on this API — the fix is to send nothing.
    func testAnthropicBodyHasNoThinkingBlock() throws {
        let body = try body(AnthropicWire(), endpoint(.anthropic, base: "https://x.test"))
        XCTAssertNil(body["thinking"])
    }

    func testCatalogCarriesTheThinkingSwitch() throws {
        let deepseek = try XCTUnwrap(AIProviderCatalog.provider(id: "deepseek"))
        let flash = try XCTUnwrap(deepseek.models.first { $0.id == "deepseek-v4-flash" })
        XCTAssertEqual(flash.noThink?.off, "thinking_type")
    }

    func testAuthHeaderFollowsTheProvider() {
        XCTAssertEqual(
            OpenAIWire().headers(endpoint(.openai, base: "https://x.test"))["Authorization"],
            "Bearer k"
        )
        let anthropic = AnthropicWire().headers(
            endpoint(.anthropic, base: "https://x.test", header: "x-api-key", prefix: "")
        )
        XCTAssertEqual(anthropic["x-api-key"], "k")
        XCTAssertEqual(anthropic["anthropic-version"], "2023-06-01")
    }

    /// A local endpoint has no key, and sending an empty Bearer header
    /// makes some servers reject the request outright.
    func testNoKeyMeansNoAuthHeader() {
        var local = endpoint(.openai, base: "http://localhost:11434/v1")
        local.apiKey = ""
        XCTAssertNil(OpenAIWire().headers(local)["Authorization"])
    }

    // MARK: - Streams

    func testSSEPayloadExtraction() {
        XCTAssertEqual(AIClient.ssePayload("data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(AIClient.ssePayload("data:{\"a\":1}"), "{\"a\":1}")
        XCTAssertNil(AIClient.ssePayload("event: content_block_delta"))
        XCTAssertNil(AIClient.ssePayload(""))
        XCTAssertNil(AIClient.ssePayload(": keep-alive"))
    }

    func testOpenAIStreamFrames() {
        let wire = OpenAIWire()
        XCTAssertEqual(
            wire.event(from: #"{"choices":[{"delta":{"content":"fix"}}]}"#),
            .delta("fix")
        )
        // The opening frame carries a role and no text.
        XCTAssertNil(wire.event(from: #"{"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertEqual(wire.event(from: "[DONE]"), .done)
        XCTAssertEqual(
            wire.event(from: #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
            .done
        )
        XCTAssertNil(wire.event(from: "not json"))
    }

    func testAnthropicStreamFrames() {
        let wire = AnthropicWire()
        XCTAssertEqual(
            wire.event(from: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"fix"}}"#),
            .delta("fix")
        )
        XCTAssertNil(wire.event(from: #"{"type":"message_start","message":{}}"#))
        XCTAssertEqual(wire.event(from: #"{"type":"message_stop"}"#), .done)
    }

    func testGeminiStreamFrames() {
        let wire = GeminiWire()
        XCTAssertEqual(
            wire.event(from: #"{"candidates":[{"content":{"parts":[{"text":"fix"}]}}]}"#),
            .delta("fix")
        )
        XCTAssertEqual(
            wire.event(from: #"{"candidates":[{"finishReason":"STOP","content":{"parts":[]}}]}"#),
            .done
        )
    }

    // MARK: - Model lists

    func testModelListShapes() throws {
        let openai = try OpenAIWire().models(
            from: Data(#"{"data":[{"id":"gpt-5"},{"id":"o3"}]}"#.utf8)
        )
        XCTAssertEqual(openai.map(\.id), ["gpt-5", "o3"])

        let gemini = try GeminiWire().models(
            from: Data(#"{"models":[{"name":"models/gemini-3-flash","displayName":"Gemini 3 Flash"}]}"#.utf8)
        )
        XCTAssertEqual(gemini.first?.id, "gemini-3-flash")
        XCTAssertEqual(gemini.first?.name, "Gemini 3 Flash")
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
}
