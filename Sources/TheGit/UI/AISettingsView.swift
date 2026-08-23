import AIKit
import SwiftUI

/// The Settings window (⌘,). One screen: which model to talk to, and how
/// it should write.
struct AISettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @Environment(\.uiZoom) private var zoom

    @State private var keyDraft = ""
    /// Models the endpoint reported, merged over the catalog's list.
    @State private var fetched: [ModelInfo] = []
    @State private var status: Status?
    @State private var probe: Task<Void, Never>?
    /// The chooser is a mode, not a popover: picking who to talk to is the
    /// decision, and it deserves the whole pane while it's being made.
    @State private var choosingProvider = false
    @State private var providerFilter = ""

    private enum Status {
        case working(String)
        case ok(String)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * zoom) {
                SettingsSection(
                    footer: "Generating a commit message sends the staged diff to the provider you pick below. Nothing is sent while this is off."
                ) {
                    SettingsRow(title: "Enable AI features") {
                        // The title stays on the Toggle (hidden, not absent)
                        // so the switch keeps its accessible name.
                        Toggle("Enable AI features", isOn: $ai.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                if ai.isEnabled {
                    if choosingProvider {
                        providerChooser
                    } else {
                        endpointSection
                        messageSection
                    }
                }
            }
            .padding(20 * zoom)
        }
        // No frame of its own: SettingsRootView sizes every pane, so the
        // window holds still across pane switches.
        .onAppear {
            keyDraft = ai.apiKey
            // Never-finished setup lands on "who do you want to talk to",
            // not on a form pre-filled with someone else's answer. A local
            // endpoint legitimately has no key, so it doesn't count.
            if ai.isEnabled, ai.apiKey.isEmpty, !ai.isLocalEndpoint { choosingProvider = true }
        }
        .onChange(of: ai.isEnabled) { _, on in
            if on, ai.apiKey.isEmpty, !ai.isLocalEndpoint { choosingProvider = true }
        }
        .onDisappear { probe?.cancel() }
    }

    // MARK: - Sections

    private var endpointSection: some View {
        SettingsSection(
            title: "Provider",
            footer: ai.provider?.needsModelLookup == true && fetched.isEmpty
                ? "This endpoint decides its own model list — fetch it, or type a model id and press ⏎."
                : nil
        ) {
            SettingsRow(
                title: ai.provider?.displayName ?? "No provider",
                subtitle: (ai.provider?.baseUrl.isEmpty ?? true)
                    ? "Your own endpoint" : ai.provider?.baseUrl
            ) {
                Button("Change…") {
                    providerFilter = ""
                    choosingProvider = true
                }
            }
            SettingsDivider()
            SettingsRow(title: "Base URL") {
                TextField(ai.provider?.baseUrl ?? "https://…", text: $ai.baseURLOverride)
                    .textFieldStyle(.roundedBorder)
                    .zoomFont(12, design: .monospaced)
                    .frame(width: 300 * zoom)
                    // The placeholder is an example, not a name.
                    .accessibilityLabel("Base URL")
            }
            if !ai.isLocalEndpoint {
                SettingsDivider()
                SettingsRow(
                    title: "API Key",
                    subtitle: "Stored in a file only your account can read, never in preferences."
                ) {
                    SecureField("sk-…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .zoomFont(12, design: .monospaced)
                        .frame(width: 300 * zoom)
                        .accessibilityLabel("API Key")
                        .onChange(of: keyDraft) { _, new in ai.setAPIKey(new) }
                }
            }
            SettingsDivider()
            SettingsRow(title: "Model") {
                SearchablePicker(
                    placeholder: "Filter models",
                    rows: modelRows,
                    selection: ai.modelID,
                    allowsFreeText: true,
                    onSelect: { ai.modelID = $0 }
                )
                .frame(width: 300 * zoom)
                .accessibilityLabel("Model")
            }
            SettingsDivider()
            HStack(spacing: 8 * zoom) {
                if let status { statusLine(status) }
                Spacer(minLength: 12 * zoom)
                if case .working = status {
                    ProgressView().controlSize(.small)
                }
                Button("Fetch Models") { fetchModels() }
                Button("Test Connection") { testConnection() }
                    .disabled(ai.endpoint == nil)
            }
            .zoomFont(11)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 8 * zoom)
        }
    }

    private var messageSection: some View {
        SettingsSection(
            title: "Commit Messages",
            footer: "Extra rules are appended to the prompt — house rules, a scope vocabulary, anything the model keeps getting wrong."
        ) {
            SettingsRow(title: "Format") {
                Picker("Format", selection: $ai.style) {
                    ForEach(AISettings.Style.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280 * zoom)
            }
            SettingsDivider()
            SettingsRow(title: "Language") {
                Picker("Language", selection: $ai.language) {
                    ForEach(AISettings.Language.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(title: "Diff budget") {
                Picker("Diff budget", selection: $ai.budget) {
                    ForEach(AISettings.Budget.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(
                title: "Match this repository's commit style",
                subtitle: "Sends the last few commit messages along as a sample."
            ) {
                Toggle("Match this repository's commit style", isOn: $ai.matchRepoStyle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 6 * zoom) {
                Text("Extra rules").zoomFont(13)
                TextEditor(text: $ai.extraInstructions)
                    .zoomFont(11, design: .monospaced)
                    .scrollContentBackground(.hidden)
                    .padding(4 * zoom)
                    .frame(height: 60 * zoom)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1))
                    )
                    .accessibilityLabel("Extra rules")
            }
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 8 * zoom)
        }
    }

    // MARK: - Provider chooser

    /// The ids worth a card of their own, in showing order. Everything
    /// else is one filter away below.
    private static let featuredIDs = [
        "openai", "anthropic", "google", "deepseek", "openrouter", "ollama",
    ]

    /// One human sentence per famous provider — what the catalog's URL
    /// column can't say. Falls back to the base URL for the long tail.
    private static let taglines: [String: String] = [
        "openai": "GPT models, with an OpenAI API key.",
        "anthropic": "Claude models, with an Anthropic API key.",
        "google": "Gemini models, with a Google AI key.",
        "deepseek": "DeepSeek models, with a DeepSeek API key.",
        "openrouter": "One key that routes to many models.",
        "ollama": "Local models on this Mac — no key, nothing leaves it.",
        "custom-provider": "Any OpenAI-compatible endpoint you point it at.",
    ]

    private var featured: [ProviderInfo] {
        Self.featuredIDs.compactMap { AIProviderCatalog.provider(id: $0) }
    }

    /// The long tail: everything not already a card, filtered by the
    /// search field.
    private var others: [ProviderInfo] {
        let shown = Set(Self.featuredIDs + [AIProviderCatalog.custom.id])
        let needle = providerFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return AIProviderCatalog.all
            .filter { needle.isEmpty ? !shown.contains($0.id) : true }
            .filter {
                needle.isEmpty
                    || $0.displayName.lowercased().contains(needle)
                    || $0.id.lowercased().contains(needle)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func detail(for provider: ProviderInfo) -> String {
        Self.taglines[provider.id]
            ?? (provider.baseUrl.isEmpty ? "Your own endpoint." : provider.baseUrl)
    }

    private func choose(_ provider: ProviderInfo) {
        ai.selectProvider(provider)
        keyDraft = ai.apiKey
        fetched = []
        status = nil
        providerFilter = ""
        choosingProvider = false
    }

    @ViewBuilder
    private var providerChooser: some View {
        HStack {
            Text("Choose a provider")
                .zoomFont(13, weight: .semibold)
            Spacer()
            Button("Cancel") { choosingProvider = false }
                .controlSize(.small)
        }
        SettingsSection(
            footer: "API keys are stored in a file only your account can read, never in preferences."
        ) {
            ForEach(Array(featured.enumerated()), id: \.element.id) { index, provider in
                if index > 0 { SettingsDivider() }
                ProviderChoiceRow(
                    title: provider.displayName,
                    detail: detail(for: provider),
                    selected: provider.id == ai.providerID
                ) { choose(provider) }
            }
            SettingsDivider()
            ProviderChoiceRow(
                title: "Use another API key…",
                detail: Self.taglines[AIProviderCatalog.custom.id] ?? "",
                selected: ai.providerID == AIProviderCatalog.custom.id
            ) { choose(AIProviderCatalog.custom) }
        }
        SettingsSection(title: "All Providers") {
            TextField("Filter providers", text: $providerFilter)
                .textFieldStyle(.roundedBorder)
                .zoomFont(12)
                .accessibilityLabel("Filter providers")
                .padding(.horizontal, 12 * zoom)
                .padding(.vertical, 8 * zoom)
            ForEach(others, id: \.id) { provider in
                SettingsDivider()
                ProviderChoiceRow(
                    title: provider.displayName,
                    detail: detail(for: provider),
                    selected: provider.id == ai.providerID
                ) { choose(provider) }
            }
            if others.isEmpty {
                SettingsDivider()
                Text("No match — \"Use another API key\" above takes any OpenAI-compatible endpoint.")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                    .padding(12 * zoom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Pieces

    private func statusLine(_ status: Status) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch status {
            case .working(let message): return ("clock", .secondary, message)
            case .ok(let message): return ("checkmark.circle.fill", .green, message)
            case .failed(let message): return ("exclamationmark.triangle.fill", .orange, message)
            }
        }()
        return HStack(alignment: .top, spacing: 6 * zoom) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).textSelection(.enabled)
        }
        .zoomFont(11)
        .fixedSize(horizontal: false, vertical: true)
        // One element, so VoiceOver reads "OK, 12 models available" as a
        // sentence instead of an icon and a string.
        .accessibilityElement(children: .combine)
    }

    /// Catalog models plus whatever the endpoint reported, the fetched ones
    /// first — they are the list that is actually true right now.
    private var modelRows: [PickerRow] {
        var seen = Set<String>()
        var rows: [PickerRow] = []
        for model in fetched + (ai.provider?.modelList ?? []) where seen.insert(model.id).inserted {
            let context = model.contextWindow.map { "\($0 / 1000)k context" }
            rows.append(PickerRow(id: model.id, title: model.displayName, detail: context))
        }
        return rows
    }

    // MARK: - Actions

    /// The status line is plain text a VoiceOver user would only find by
    /// re-reading the pane; a probe finishing is worth saying out loud.
    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    private func fetchModels() {
        guard let provider = ai.provider, let baseURL = ai.baseURL else {
            status = .failed("Set a Base URL first.")
            return
        }
        // The model is what we're trying to discover, so any placeholder does.
        let endpoint = AIEndpoint(
            provider: provider, baseURL: baseURL, apiKey: ai.apiKey, model: ai.modelID
        )
        probe?.cancel()
        status = .working("Asking \(provider.displayName) for its models…")
        probe = Task {
            do {
                let models = try await AIGateway.models(endpoint: endpoint)
                fetched = models
                status = .ok("\(models.count) models available.")
                announce("\(models.count) models available.")
                if ai.modelID.isEmpty, let first = models.first { ai.modelID = first.id }
            } catch {
                status = .failed(error.localizedDescription)
                announce("Fetching models failed. \(error.localizedDescription)")
            }
        }
    }

    private func testConnection() {
        guard let endpoint = ai.endpoint else { return }
        probe?.cancel()
        status = .working("Sending a test prompt…")
        probe = Task {
            do {
                let reply = try await AIGateway.complete(
                    AIRequest(system: "Reply with exactly: ok", user: "ping", maxOutputTokens: 16),
                    endpoint: endpoint
                )
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                status = trimmed.isEmpty
                    ? .failed("Connected, but \(endpoint.model) replied with nothing.")
                    : .ok("\(endpoint.model) replied: \(trimmed.prefix(60))")
                announce(trimmed.isEmpty ? "Connection test failed." : "Connection test passed.")
            } catch {
                status = .failed(error.localizedDescription)
                announce("Connection test failed. \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Provider choice row

/// One provider the chooser offers: name, one plain sentence, chevron —
/// a real Button, so it's keyboard-reachable and announces as one.
private struct ProviderChoiceRow: View {
    @Environment(\.uiZoom) private var zoom
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * zoom) {
                VStack(alignment: .leading, spacing: 2 * zoom) {
                    Text(title).zoomFont(13, weight: .medium)
                    Text(detail)
                        .zoomFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12 * zoom)
                if selected {
                    Image(systemName: "checkmark")
                        .zoomFont(11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Current provider")
                }
                Image(systemName: "chevron.right")
                    .zoomFont(10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 8 * zoom)
            .frame(minHeight: 40 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Searchable picker

struct PickerRow: Identifiable, Hashable {
    let id: String
    let title: String
    var detail: String?
}

/// A Picker can't hold 2,500 models, and `List` is off the table app-wide
/// (see the zoom notes in TheGitApp). Same shape as the sidebar's filter
/// field over a LazyVStack.
private struct SearchablePicker: View {
    let placeholder: String
    let rows: [PickerRow]
    let selection: String
    var allowsFreeText = false
    let onSelect: (String) -> Void

    @Environment(\.uiZoom) private var zoom
    @State private var isPresented = false
    @State private var filter = ""

    var body: some View {
        Button {
            filter = ""
            isPresented = true
        } label: {
            HStack(spacing: 6 * zoom) {
                Text(currentTitle)
                    .lineLimit(1)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
            }
            .zoomFont(12)
            .padding(.horizontal, 8 * zoom)
            .padding(.vertical, 4 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
    }

    private var currentTitle: String {
        if let row = rows.first(where: { $0.id == selection }) { return row.title }
        return selection.isEmpty ? "Not set" : selection
    }

    private var matches: [PickerRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.id.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $filter)
                .textFieldStyle(.roundedBorder)
                .zoomFont(12)
                .padding(8 * zoom)
                // A model id the catalog has never heard of is a legitimate
                // answer for a self-hosted endpoint.
                .onSubmit {
                    guard allowsFreeText else { return }
                    let typed = filter.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty, !matches.contains(where: { $0.id == typed }) {
                        onSelect(typed)
                        isPresented = false
                    }
                }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { row in
                        Button {
                            onSelect(row.id)
                            isPresented = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 4 * zoom) {
                                // The tick sits in a gutter that is there
                                // whether or not it is filled, so titles line
                                // up down the list instead of the selected one
                                // stepping to the right.
                                Image(systemName: "checkmark")
                                    .zoomFont(10)
                                    .frame(width: 10 * zoom, alignment: .leading)
                                    .opacity(row.id == selection ? 1 : 0)
                                    // Decorative: the trait below says it.
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).zoomFont(12)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .zoomFont(10)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10 * zoom)
                            .padding(.vertical, 4 * zoom)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(row.id == selection ? .isSelected : [])
                    }
                    if matches.isEmpty {
                        Text(allowsFreeText ? "No match — press ⏎ to use what you typed." : "No match")
                            .zoomFont(11)
                            .foregroundStyle(.secondary)
                            .padding(10 * zoom)
                    }
                }
            }
        }
        .frame(width: 330 * zoom, height: 300 * zoom)
    }
}
