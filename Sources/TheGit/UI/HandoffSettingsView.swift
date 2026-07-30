import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Hand Off: which terminal an agent opens in.
///
/// One question, so the pane is the list of answers rather than a row with
/// a pop-up on it. A pop-up hides every option but the current one, and the
/// whole reason this setting exists is that nobody knew they had a choice —
/// the handoff kept opening in Terminal because `.command` files belong to
/// Terminal, not because anyone chose it.
///
/// Real app icons, not a text list: on a Mac an app is its icon first and
/// its name second, and the icon is also what makes "System default" legible
/// at a glance — you see Terminal's icon and understand where it's been
/// going all along.
struct HandoffSettingsView: View {
    @Environment(\.uiZoom) private var zoom
    /// The raw stored string: a bundle identifier, or "" for "whatever the
    /// system does", which is what an install that never opens this pane has.
    @AppStorage(HandoffTarget.storageKey) private var target = ""
    @State private var choices: [Choice] = []
    @ObservedObject private var agents = AgentTools.shared

    /// One row. `id` is what gets stored, so the system-default row stores
    /// "" and stays the system default even if that association changes.
    private struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage?
        /// True for the app this Mac opens `.command` files with, wherever
        /// it lands in the list — it isn't a separate row, it's a note on
        /// the row it already has. Two rows with the same icon would be a
        /// riddle, not a list.
        let isSystemDefault: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * zoom) {
                Text("Right-click a pull request or an issue and Hand Off opens Claude or Codex in that repository, already working on it. This is the window it opens in.")
                    .zoomFont(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsSection(
                    title: "Open handoffs in",
                    footer: "Only the terminals installed here are listed. Uninstall the one you picked and handoffs go back to the system default."
                ) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { SettingsDivider() }
                        ChoiceRow(
                            name: choice.name,
                            note: choice.isSystemDefault ? "System default" : nil,
                            icon: choice.icon,
                            selected: isSelected(choice)
                        ) { target = choice.id }
                    }
                }

                agentSection
            }
            .padding(20 * zoom)
        }
        // Sized by SettingsRootView, like every pane.
        .task { refresh() }
    }

    /// Who the handoff actually goes to. Read-only, and always shown rather
    /// than only in the failure case: the pane is where someone lands
    /// wondering why right-clicking shows no Hand Off menu, and "neither is
    /// installed" is the answer.
    private var agentSection: some View {
        SettingsSection(
            title: "Agents",
            footer: agents.available.isEmpty
                ? "Hand Off appears in no menu until one of them is installed. Tools says where to get them."
                : nil
        ) {
            ForEach(Array(AgentTool.allCases.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { SettingsDivider() }
                let installed = agents.available.contains(agent)
                SettingsRow(title: agent.name) {
                    HStack(spacing: 6 * zoom) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                            .zoomFont(12)
                            .foregroundStyle(installed ? Color.green : Color.secondary)
                        Text(installed ? "Ready" : "Not installed")
                            .zoomFont(11)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// An explicit pick wins; otherwise the row that is the system default
    /// is the one in effect — which is the truth, and keeps the list from
    /// ever showing nothing selected.
    private func isSelected(_ choice: Choice) -> Bool {
        target.isEmpty ? choice.isSystemDefault : target == choice.id
    }

    private func refresh() {
        AgentTools.shared.recheck()
        let workspace = NSWorkspace.shared
        let defaultApp = Self.systemDefaultTerminal()
        var rows = TerminalApp.installed.map { terminal in
            Choice(
                id: terminal.id,
                name: terminal.name,
                icon: terminal.url.map { workspace.icon(forFile: $0.path) },
                isSystemDefault: terminal.id == defaultApp?.id
            )
        }
        // The `.command` handler is usually a terminal we already list, and
        // then it's just a note on that row. When it's something else —
        // an editor, a terminal nobody has named yet — it earns a row of
        // its own, because it's the one actually in use.
        if let defaultApp, !rows.contains(where: { $0.isSystemDefault }) {
            rows.insert(
                Choice(
                    id: "",
                    name: defaultApp.name,
                    icon: workspace.icon(forFile: defaultApp.url.path),
                    isSystemDefault: true
                ),
                at: 0
            )
        }
        choices = rows
        // A terminal deleted since it was picked would leave nothing
        // selected. Put it back on the default it's going to use anyway.
        if !target.isEmpty && !rows.contains(where: { $0.id == target }) { target = "" }
    }

    /// Whatever LaunchServices opens a `.command` with, with its bundle
    /// identifier so it can be matched against the list. Asked of the type
    /// rather than of a file, so nothing is written to disk to find out.
    private static func systemDefaultTerminal() -> (id: String?, name: String, url: URL)? {
        guard let type = UTType(filenameExtension: "command"),
            let url = NSWorkspace.shared.urlForApplication(toOpen: type)
        else { return nil }
        return (
            Bundle(url: url)?.bundleIdentifier,
            url.deletingPathExtension().lastPathComponent,
            url
        )
    }
}

/// One row of a single-choice list: icon and name leading, a checkmark
/// trailing when it's the one in effect. The whole row is the target — you
/// pick by clicking anywhere on the line, the way macOS's own lists work.
private struct ChoiceRow: View {
    @Environment(\.uiZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    var note: String?
    let icon: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * zoom) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20 * zoom, height: 20 * zoom)
                        // The name is right there; the icon is decoration
                        // for anyone who can't see it.
                        .accessibilityHidden(true)
                }
                Text(name)
                    .zoomFont(13)
                if let note {
                    Text(note)
                        .zoomFont(10)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5 * zoom)
                        .padding(.vertical, 1 * zoom)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.07))
                        )
                }
                Spacer(minLength: 12 * zoom)
                Image(systemName: "checkmark")
                    .zoomFont(12, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    // Nothing appears from nothing: it comes in slightly
                    // small and settles, rather than blinking into place.
                    .scaleEffect(selected ? 1 : 0.8)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 7 * zoom)
            .frame(minHeight: 38 * zoom)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(
            reduceMotion ? .easeOut(duration: 0.1) : .easeOutStrong(0.18),
            value: selected
        )
        // The checkmark is the state. A screen reader gets it as selection
        // rather than as an image that may or may not be there.
        .accessibilityLabel(note.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Hover and press as background weight, and the press lands on mouse-down
/// rather than on release — the row has to feel like it heard the click
/// before it does anything about it.
///
/// Background rather than the usual `scale(0.97)`: these rows are the full
/// width of a card they're inset into, and a full-width row shrinking away
/// from its own container reads as a glitch rather than as a press.
private struct RowButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.05 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
