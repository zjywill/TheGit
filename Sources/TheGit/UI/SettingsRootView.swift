import SwiftUI

/// The Settings window's shell: a hand-rolled sidebar on the left, one
/// pane on the right. Hand-rolled because the obvious `List` selection
/// sidebar is table-backed and banned app-wide (macOS 26 reentrant-layout
/// crash — see the zoom notes in TheGitApp); same ScrollView-and-stacks
/// recipe as the repo sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case ai
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .ai: return "AI"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .ai: return "sparkles"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// Sidebar group the pane sits under. Two groups for three items is
    /// deliberately a little roomy — it's the slot structure new panes
    /// (Git behavior, integrations, updates) drop into.
    var group: String {
        self == .appearance ? "General" : "Features"
    }
}

struct SettingsRootView: View {
    @Environment(\.uiZoom) private var zoom
    @State private var pane: SettingsPane = .appearance

    private var groups: [(name: String, panes: [SettingsPane])] {
        var seen: [String: [SettingsPane]] = [:]
        var order: [String] = []
        for pane in SettingsPane.allCases {
            if seen[pane.group] == nil { order.append(pane.group) }
            seen[pane.group, default: []].append(pane)
        }
        return order.map { ($0, seen[$0] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch pane {
                case .appearance: AppearanceSettingsView()
                case .ai: AISettingsView()
                case .tools: ToolsSettingsView()
                }
            }
            // The shell owns the size, so every pane switch keeps the
            // window still instead of it hopping between content sizes.
            .frame(width: 560 * zoom, height: 620 * zoom)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.name) { group in
                    Text(group.name.uppercased())
                        .zoomFont(10, weight: .semibold)
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10 * zoom)
                        .padding(.top, group.name == groups.first?.name ? 0 : 14 * zoom)
                        .padding(.bottom, 2 * zoom)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.panes) { item in
                        PaneButton(pane: item, selected: item == pane) {
                            pane = item
                        }
                    }
                }
            }
            .padding(10 * zoom)
        }
        .frame(width: 168 * zoom)
        .background(Color.primary.opacity(0.03))
    }
}

private struct PaneButton: View {
    @Environment(\.uiZoom) private var zoom
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7 * zoom) {
                Image(systemName: pane.icon)
                    .zoomFont(12)
                    .frame(width: 18 * zoom)
                Text(pane.title)
                    .zoomFont(13, weight: selected ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8 * zoom)
            .frame(height: 26 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        selected
                            ? Color.accentColor
                            : hovering ? Color.primary.opacity(0.06) : .clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Appearance

/// Zoom and avatars, which used to live only in the View menu — a menu is
/// a fine shortcut but a poor home: nothing there explains what the
/// setting does or costs.
struct AppearanceSettingsView: View {
    @Environment(\.uiZoom) private var zoom
    @AppStorage("uiZoomLevel") private var zoomLevel = UIZoom.defaultLevel
    @ObservedObject private var avatars = AvatarStore.shared

    /// Writes land on the next runloop turn, same as the ⌘=/⌘− commands:
    /// a zoom change relays out every window, and doing that inside the
    /// picker's update transaction is the reentrant-layout pattern that
    /// crashes macOS 26.
    private var deferredZoomLevel: Binding<Int> {
        Binding(
            get: { zoomLevel },
            set: { new in DispatchQueue.main.async { zoomLevel = new } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * zoom) {
                SettingsSection(
                    title: "Interface",
                    footer: "Scales all text and layout in every window. ⌘= and ⌘− do the same from the keyboard."
                ) {
                    SettingsRow(title: "UI zoom") {
                        Picker("UI zoom", selection: deferredZoomLevel) {
                            ForEach(0..<UIZoom.levels.count, id: \.self) { level in
                                Text("\(Int(UIZoom.levels[level] * 100))%").tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280 * zoom)
                    }
                }
                SettingsSection(
                    title: "Commit Graph",
                    footer: "Avatars are looked up on Gravatar and GitHub by commit author email — the one feature that talks to a server you didn't configure, which is why it's off until you turn it on."
                ) {
                    SettingsRow(title: "Author avatars") {
                        Toggle("Author avatars", isOn: $avatars.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .padding(20 * zoom)
        }
    }
}
