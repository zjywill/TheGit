import AIKit
import Foundation

/// TheGit's view of AIKit's bundled provider catalog.
///
/// AIKit ships the catalog and the loader; this is the short list of house
/// rules on top — which entries to hide, what to call a provider that has no
/// name, and which endpoints decide their own model list.
enum AIProviderCatalog {
    /// Entries the catalog carries that TheGit can't offer. Codex-style
    /// OAuth logins need a browser flow and a token refresh; a settings pane
    /// with one API Key field has nothing to put in them.
    private static let hidden: Set<String> = ["dimcode-api-oauth"]

    /// Anything the user points at by hand. Kept first in the list so an
    /// unlisted endpoint is one click away.
    static let custom: ProviderInfo = ProviderCatalog.provider("custom-provider")
        ?? ProviderInfo(id: "custom-provider", name: "Custom (OpenAI-compatible)", api: nil, speaking: .openAICompletions)

    /// The id the custom entry used to carry, before the catalog moved into
    /// AIKit. Settings written by an older build still name it.
    static let legacyCustomID = "custom"

    /// Endpoints for catalog entries that ship without one. Google's is
    /// the only gap today, and a provider on the chooser's front page has
    /// to work without the user pasting a URL in first. Drop an entry from
    /// here once AIKit's catalog carries it.
    private static let fallbackEndpoints: [String: String] = [
        "google": "https://generativelanguage.googleapis.com/v1beta",
    ]

    static let all: [ProviderInfo] = [custom] + ProviderCatalog.all
        .filter { !hidden.contains($0.id) && $0.id != custom.id }
        .map { provider in
            guard provider.api == nil, let url = fallbackEndpoints[provider.id] else { return provider }
            var patched = provider
            patched.api = url
            return patched
        }

    static func provider(id: String) -> ProviderInfo? {
        all.first { $0.id == (id == legacyCustomID ? custom.id : id) }
    }

    /// Whether the catalog actually loaded. `false` is a packaging problem
    /// in this app, not a problem with the catalog — see AIKit's
    /// `ProviderCatalog.diagnostics`.
    static var isLoaded: Bool { ProviderCatalog.isLoaded }
}

extension ProviderInfo {
    /// Every provider in the catalog has a name; one the user typed a URL
    /// for might not.
    var displayName: String { name ?? id }

    /// The catalog's endpoint, or "" for the providers configured per
    /// install — self-hosted gateways and local runtimes.
    var baseUrl: String { api ?? "" }

    var modelList: [ModelInfo] { models ?? [] }

    /// The model list has to come from the endpoint itself — Ollama, LM
    /// Studio, and the gateways whose catalogue changes daily.
    var needsModelLookup: Bool { modelList.isEmpty }

    /// The model to land on when this provider is chosen.
    var startingModelID: String { modelList.first?.id ?? "" }
}

extension ModelInfo {
    var displayName: String { name ?? id }
}
