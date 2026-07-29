import SwiftUI

/// The Settings window (⌘,). One screen: which model to talk to, and how
/// it should write.
struct AISettingsView: View {
    @ObservedObject private var ai = AISettings.shared
    @Environment(\.uiZoom) private var zoom

    @State private var keyDraft = ""
    /// Models the endpoint reported, merged over the catalog's list.
    @State private var fetched: [AIModel] = []
    @State private var status: Status?
    @State private var probe: Task<Void, Never>?

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
                    endpointSection
                    messageSection
                }
            }
            .padding(20 * zoom)
        }
        // No frame of its own: SettingsRootView sizes every pane, so the
        // window holds still across pane switches.
        .onAppear { keyDraft = ai.apiKey }
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
            SettingsRow(title: "Provider") {
                SearchablePicker(
                    placeholder: "Filter providers",
                    rows: providerRows,
                    selection: ai.providerID,
                    onSelect: { id in
                        guard let provider = AIProviderCatalog.provider(id: id) else { return }
                        ai.selectProvider(provider)
                        keyDraft = ai.apiKey
                        fetched = []
                        status = nil
                    }
                )
                .frame(width: 300 * zoom)
                .accessibilityLabel("Provider")
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
                    subtitle: "Stored in your login keychain, never in preferences."
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

    private var providerRows: [PickerRow] {
        AIProviderCatalog.all.map {
            PickerRow(id: $0.id, title: $0.name, detail: $0.baseUrl.isEmpty ? "your own endpoint" : $0.baseUrl)
        }
    }

    /// Catalog models plus whatever the endpoint reported, the fetched ones
    /// first — they are the list that is actually true right now.
    private var modelRows: [PickerRow] {
        var seen = Set<String>()
        var rows: [PickerRow] = []
        for model in fetched + (ai.provider?.models ?? []) where seen.insert(model.id).inserted {
            let context = model.ctx.map { "\($0 / 1000)k context" }
            rows.append(PickerRow(id: model.id, title: model.name, detail: context))
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
        status = .working("Asking \(provider.name) for its models…")
        probe = Task {
            do {
                let models = try await AIClient.models(endpoint: endpoint)
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
                let reply = try await AIClient.complete(
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
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4 * zoom) {
                                    if row.id == selection {
                                        Image(systemName: "checkmark").zoomFont(10)
                                    }
                                    Text(row.title).zoomFont(12)
                                }
                                if let detail = row.detail {
                                    Text(detail)
                                        .zoomFont(10)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10 * zoom)
                            .padding(.vertical, 4 * zoom)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
