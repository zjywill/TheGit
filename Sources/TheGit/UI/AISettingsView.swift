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
            VStack(alignment: .leading, spacing: 18 * zoom) {
                enableSection
                if ai.isEnabled {
                    Divider()
                    endpointSection
                    Divider()
                    messageSection
                }
            }
            .padding(20 * zoom)
        }
        .frame(width: 560 * zoom, height: 620 * zoom)
        .onAppear { keyDraft = ai.apiKey }
        .onDisappear { probe?.cancel() }
    }

    // MARK: - Sections

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 6 * zoom) {
            Toggle("Enable AI features", isOn: $ai.isEnabled)
                .zoomFont(13, weight: .medium)
            Text("Generating a commit message sends the staged diff to the provider you pick below. Nothing is sent while this is off.")
                .zoomFont(11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10 * zoom) {
            Text("Provider").zoomFont(13, weight: .semibold)

            field("Provider") {
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
            }

            field("Base URL") {
                TextField(ai.provider?.baseUrl ?? "https://…", text: $ai.baseURLOverride)
                    .textFieldStyle(.roundedBorder)
                    .zoomFont(12, design: .monospaced)
            }

            if !ai.isLocalEndpoint {
                field("API Key") {
                    VStack(alignment: .leading, spacing: 4 * zoom) {
                        SecureField("sk-…", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .zoomFont(12, design: .monospaced)
                            .onChange(of: keyDraft) { _, new in ai.setAPIKey(new) }
                        Text("Stored in your login keychain, never in preferences.")
                            .zoomFont(10)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            field("Model") {
                VStack(alignment: .leading, spacing: 6 * zoom) {
                    SearchablePicker(
                        placeholder: "Filter models",
                        rows: modelRows,
                        selection: ai.modelID,
                        allowsFreeText: true,
                        onSelect: { ai.modelID = $0 }
                    )
                    HStack(spacing: 8 * zoom) {
                        Button("Fetch Models") { fetchModels() }
                        Button("Test Connection") { testConnection() }
                            .disabled(ai.endpoint == nil)
                        if case .working = status {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .zoomFont(11)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if ai.provider?.needsModelLookup == true, fetched.isEmpty {
                        Text("This endpoint decides its own model list — fetch it, or type a model id and press ⏎.")
                            .zoomFont(10)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let status { statusLine(status) }
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 10 * zoom) {
            Text("Commit Messages").zoomFont(13, weight: .semibold)

            field("Format") {
                Picker("", selection: $ai.style) {
                    ForEach(AISettings.Style.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            field("Language") {
                Picker("", selection: $ai.language) {
                    ForEach(AISettings.Language.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }

            field("Diff budget") {
                Picker("", selection: $ai.budget) {
                    ForEach(AISettings.Budget.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }

            field("") {
                Toggle("Match this repository's commit style", isOn: $ai.matchRepoStyle)
                    .zoomFont(12)
                    .help("Sends the last few commit messages along as a sample.")
            }

            field("Extra rules") {
                VStack(alignment: .leading, spacing: 4 * zoom) {
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
                    Text("Appended to the prompt — house rules, a scope vocabulary, anything the model keeps getting wrong.")
                        .zoomFont(10)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pieces

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * zoom) {
            Text(label)
                .zoomFont(12)
                .foregroundStyle(.secondary)
                .frame(width: 90 * zoom, alignment: .trailing)
            content()
        }
    }

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
            Spacer(minLength: 0)
        }
        .zoomFont(11)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 100 * zoom)
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
                if ai.modelID.isEmpty, let first = models.first { ai.modelID = first.id }
            } catch {
                status = .failed(error.localizedDescription)
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
            } catch {
                status = .failed(error.localizedDescription)
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
