import AppKit
import SwiftUI

/// Settings › Tools: every external binary the app drives, with where it
/// was found — or how to get it. Doubles as the screenshot to ask for
/// when someone reports "pull requests don't show up".
struct ToolsSettingsView: View {
    @Environment(\.uiZoom) private var zoom

    /// One probed tool. Path nil means not installed; version nil with a
    /// path means the binary was found but wouldn't run --version.
    private struct ToolStatus: Identifiable {
        let tool: DevTool
        let path: String?
        let version: String?
        var id: String { tool.id }
    }

    @State private var statuses: [ToolStatus] = []
    @State private var brewInstalled = true
    /// The tool whose install command was just copied, for the one-word
    /// button acknowledgement. Cleared on a timer.
    @State private var copied: DevTool?

    private var required: [ToolStatus] { statuses.filter { $0.tool == .git } }
    private var optional: [ToolStatus] { statuses.filter { $0.tool != .git } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * zoom) {
                HStack(alignment: .top, spacing: 12 * zoom) {
                    Text("TheGit ships no engines of its own — these command-line tools do the actual work.")
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        Task { await probe() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Check again — after installing something, for instance.")
                    .accessibilityLabel("Check tools again")
                }
                if !required.isEmpty {
                    SettingsSection(title: "Required") {
                        ForEach(required) { row(for: $0) }
                    }
                }
                if !optional.isEmpty {
                    SettingsSection(
                        title: "Optional — each unlocks a feature",
                        footer: brewInstalled
                            ? nil
                            : "Homebrew wasn't found, so the buttons above open each tool's own installer page. With Homebrew (brew.sh) installed, they turn into copyable one-line commands."
                    ) {
                        ForEach(Array(optional.enumerated()), id: \.element.id) { index, status in
                            if index > 0 { SettingsDivider() }
                            row(for: status)
                        }
                    }
                }
            }
            .padding(20 * zoom)
        }
        // Sized by SettingsRootView, like every pane.
        .task { await probe() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for status: ToolStatus) -> some View {
        HStack(alignment: .center, spacing: 10 * zoom) {
            Image(systemName: status.path == nil ? "circle.dashed" : "checkmark.circle.fill")
                .zoomFont(14)
                .foregroundStyle(status.path == nil ? Color.secondary : Color.green)
                // The icon is the row's status; say it, don't show it.
                .accessibilityLabel(status.path == nil ? "Not installed" : "Installed")
            VStack(alignment: .leading, spacing: 2 * zoom) {
                Text(status.tool.title)
                    .zoomFont(13)
                Text(status.tool.purpose)
                    .zoomFont(10)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12 * zoom)
            if let path = status.path {
                VStack(alignment: .trailing, spacing: 2 * zoom) {
                    // Version first — it's the part worth reading aloud in
                    // a bug report; the path explains which install won.
                    Text(status.version ?? path)
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if status.version != nil {
                        Text(path)
                            .zoomFont(10, design: .monospaced)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
                .frame(maxWidth: 220 * zoom, alignment: .trailing)
            } else {
                missingControls(for: status.tool)
            }
        }
        .padding(.horizontal, 12 * zoom)
        .padding(.vertical, 8 * zoom)
        .frame(minHeight: 40 * zoom)
    }

    /// What a missing tool's row offers. Git is special: the Command Line
    /// Tools installer beats any brew line, and it's one click from here.
    @ViewBuilder
    private func missingControls(for tool: DevTool) -> some View {
        if tool == .git {
            Button("Install Command Line Tools…") {
                Task { await Toolchain.installCommandLineTools() }
            }
            .zoomFont(11)
        } else {
            switch Toolchain.hint(for: tool) {
            case .command(let line):
                HStack(spacing: 6 * zoom) {
                    Text(line)
                        .zoomFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .textSelection(.enabled)
                    Button(copied == tool ? "Copied" : "Copy") {
                        RepoState.copyToPasteboard(line)
                        copied = tool
                        AccessibilityNotification.Announcement("Copied \(line)").post()
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if copied == tool { copied = nil }
                        }
                    }
                    .zoomFont(11)
                    .accessibilityLabel("Copy install command for \(tool.title)")
                }
            case .website(let url):
                Button("Open install page…") {
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .zoomFont(11)
                .help(url)
                .accessibilityLabel("Open install page for \(tool.title)")
            }
        }
    }

    // MARK: - Probing

    private func probe() async {
        brewInstalled = Toolchain.brewInstalled
        // Somebody who just installed an agent is exactly who clicks this
        // button, and the answer this pane reads is the same one the Hand
        // Off menus read — so ask the shell again, then republish.
        await Shell.resolveLoginPath()
        AgentTools.shared.recheck()
        var rows: [ToolStatus] = []
        for tool in DevTool.allCases {
            let path = tool == .git ? Toolchain.installedGit() : Shell.which(tool.binary)
            let version = path == nil ? nil : await Toolchain.version(of: tool)
            rows.append(ToolStatus(tool: tool, path: path, version: version))
        }
        statuses = rows
    }
}
