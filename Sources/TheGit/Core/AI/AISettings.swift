import Foundation

/// AI configuration, persisted to UserDefaults — everything except the API
/// key, which lives in the keychain (`AICredentials`).
///
/// Off by default, and for the same reason avatars are: a git client should
/// not send anything anywhere the user didn't ask it to, and a diff is a lot
/// more of the user's work than an email hash.
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    enum Language: String, CaseIterable, Identifiable {
        case auto, english, chinese
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Match the repository"
            case .english: return "English"
            case .chinese: return "简体中文"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case conventional, plain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .conventional: return "Conventional Commits"
            case .plain: return "Plain summary"
            }
        }
    }

    /// How much diff text to send. Enough for a normal change; the cap is
    /// what keeps a 40-file refactor from timing out or costing real money.
    enum Budget: Int, CaseIterable, Identifiable {
        case small = 24_000, medium = 48_000, large = 96_000
        var id: Int { rawValue }
        var title: String { "\(rawValue / 1000)k characters" }
    }

    @Published var isEnabled: Bool { didSet { write(isEnabled, "enabled") } }
    @Published var providerID: String { didSet { write(providerID, "provider") } }
    @Published var modelID: String { didSet { write(modelID, "model") } }
    /// Empty means "use the provider's own endpoint".
    @Published var baseURLOverride: String { didSet { write(baseURLOverride, "baseURL") } }
    @Published var language: Language { didSet { write(language.rawValue, "language") } }
    @Published var style: Style { didSet { write(style.rawValue, "style") } }
    /// Feeds recent commit messages in as a style sample.
    @Published var matchRepoStyle: Bool { didSet { write(matchRepoStyle, "matchRepoStyle") } }
    @Published var extraInstructions: String { didSet { write(extraInstructions, "instructions") } }
    @Published var budget: Budget { didSet { write(budget.rawValue, "budget") } }
    /// The "your diff leaves this machine" alert is shown once.
    @Published var didConfirmSending: Bool { didSet { write(didConfirmSending, "confirmedSending") } }

    /// Cached, not read through to the keychain: `isReady` is evaluated in
    /// a view body on every keystroke in the commit box, and that is no
    /// place for a SecItemCopyMatching.
    @Published private(set) var apiKey: String

    private static let prefix = "TheGit.ai."
    private let defaults = UserDefaults.standard

    private init() {
        let read = { (key: String) in UserDefaults.standard.object(forKey: Self.prefix + key) }
        let provider = read("provider") as? String ?? "openai"
        isEnabled = read("enabled") as? Bool ?? false
        providerID = provider
        modelID = read("model") as? String ?? ""
        baseURLOverride = read("baseURL") as? String ?? ""
        language = Language(rawValue: read("language") as? String ?? "") ?? .auto
        style = Style(rawValue: read("style") as? String ?? "") ?? .conventional
        matchRepoStyle = read("matchRepoStyle") as? Bool ?? true
        extraInstructions = read("instructions") as? String ?? ""
        budget = Budget(rawValue: read("budget") as? Int ?? 0) ?? .medium
        didConfirmSending = read("confirmedSending") as? Bool ?? false
        apiKey = AICredentials.key(for: provider) ?? ""
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    // MARK: - Derived state

    var provider: AIProvider? { AIProviderCatalog.provider(id: providerID) }

    func setAPIKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != apiKey else { return }
        AICredentials.setKey(key, for: providerID)
        apiKey = key
    }

    /// Where requests actually go: the override if the user set one, else
    /// the catalog's endpoint.
    var baseURL: URL? {
        let override = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = override.isEmpty ? (provider?.baseUrl ?? "") : override
        guard !raw.isEmpty else { return nil }
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
    }

    /// Everything needed to send a request, or nil if something is missing.
    var endpoint: AIEndpoint? {
        guard let provider, let baseURL, !modelID.isEmpty else { return nil }
        guard !apiKey.isEmpty || isLocalEndpoint else { return nil }
        return AIEndpoint(
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            model: modelID,
            noThink: provider.models.first { $0.id == modelID }?.noThink
        )
    }

    /// Local servers don't authenticate, and demanding a key for one would
    /// make Ollama look broken.
    var isLocalEndpoint: Bool {
        ["localhost", "127.0.0.1", "::1"].contains(baseURL?.host ?? "")
    }

    var isReady: Bool { isEnabled && endpoint != nil }

    /// Why the ✨ button is off, in one line, for its tooltip.
    var notReadyReason: String? {
        if !isEnabled { return "Turn on AI in Settings (⌘,)" }
        if provider == nil { return "Pick an AI provider in Settings (⌘,)" }
        if baseURL == nil { return "Set a Base URL in Settings (⌘,)" }
        if modelID.isEmpty { return "Pick a model in Settings (⌘,)" }
        if endpoint == nil { return "Add an API key in Settings (⌘,)" }
        return nil
    }

    /// Switching providers keeps nothing from the old one — not the model,
    /// not the endpoint override, and not the key, which belongs to the
    /// provider it was issued by.
    func selectProvider(_ provider: AIProvider) {
        providerID = provider.id
        baseURLOverride = ""
        modelID = provider.defaultModelId ?? provider.models.first?.id ?? ""
        apiKey = AICredentials.key(for: provider.id) ?? ""
    }
}
