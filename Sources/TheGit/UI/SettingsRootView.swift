import SwiftUI

/// The Settings window's shell: a hand-rolled sidebar on the left, one
/// pane on the right. Hand-rolled because the obvious `List` selection
/// sidebar is table-backed and banned app-wide (macOS 26 reentrant-layout
/// crash — see the zoom notes in TheGitApp); same ScrollView-and-stacks
/// recipe as the repo sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case ai
    case handoff
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .ai: return "AI"
        case .handoff: return "Hand Off"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .ai: return "sparkles"
        case .handoff: return "arrowshape.turn.up.right"
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

    /// Height of the (unified-toolbar) title bar the window now draws its
    /// content under. Fixed, not zoomed: the traffic lights are AppKit's and
    /// stay the same size at every zoom level, so the room made for them has
    /// to as well.
    private static let titleBarHeight: CGFloat = 52

    /// How far the sidebar capsule floats off the window's edges, and how
    /// round it is. Both fixed rather than zoomed: this is window chrome,
    /// sized against the traffic lights, which don't zoom either.
    private static let capsuleInset: CGFloat = 8
    /// Concentric with the window: Tahoe rounds window corners to ~26pt, so
    /// a panel floating 8pt inside them wants 26 − 8 — a shared centre, not
    /// a shared radius, is what stops the two curves from clashing.
    private static let capsuleRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        // The sidebar is a capsule floating clear of the window's edges with
        // the traffic lights sitting on it — the shape macOS 26 gives every
        // stock sidebar. Two halves of it: the window drops its title bar
        // (SettingsWindowChrome), and the content stops reserving the safe
        // area that title bar used to occupy.
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowChrome())
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
            // Below the traffic lights, which now sit on this capsule.
            .padding(.top, Self.titleBarHeight - Self.capsuleInset)
        }
        .frame(width: 168 * zoom)
        // Glass, clipped to the capsule and outlined the way the stock one
        // is — the outline is what reads as "a panel on the window" rather
        // than "a column of it".
        .background(SidebarMaterial())
        .clipShape(RoundedRectangle(cornerRadius: Self.capsuleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.capsuleRadius)
                .stroke(Color.primary.opacity(0.10))
        )
        .padding(.leading, Self.capsuleInset)
        .padding(.vertical, Self.capsuleInset)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // The pane's name, where the window title used to be — the title
            // bar is gone, and System Settings likewise titles the right half
            // rather than the window. Its baseline sits level with the
            // traffic lights on the capsule beside it.
            HStack {
                Text(pane.title)
                    .zoomFont(15, weight: .semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20 * zoom)
            .frame(height: Self.titleBarHeight, alignment: .bottom)
            .padding(.bottom, 6 * zoom)
            Group {
                switch pane {
                case .appearance: AppearanceSettingsView()
                case .ai: AISettingsView()
                case .handoff: HandoffSettingsView()
                case .tools: ToolsSettingsView()
                }
            }
            // A floor, not a fixed size: the pane still asks for the same
            // room whichever one is showing — so switching panes doesn't move
            // the window — but it now stretches to whatever the window
            // actually is, instead of leaving a band of bare window under it.
            // The floor is only what the widest row (Appearance's zoom
            // picker) needs to not clip — every pane scrolls vertically, so
            // height can go well under content height.
            .frame(minWidth: 500 * zoom, minHeight: 400 * zoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Drops the Settings window's title bar so the sidebar can own the top-left
/// corner: transparent bar, no title, content drawn full height under it.
/// The bar itself stays in the style mask — it's still what you drag the
/// window by, and what the traffic lights hang off.
///
/// Applied on every key/main transition, not once: the SwiftUI `Settings`
/// scene reasserts window properties when the app is deactivated and
/// reactivated, which quietly undid all of this on the first ⌘-tab away.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Deferred: on the first pass the view has no window yet, and
        // restyling a window mid-layout is the reentrancy that macOS 26
        // punishes.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow) {
            apply(to: window)
            guard self.window !== window else { return }
            self.window = window
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            // Key and occlusion cover every way the scene gets a chance to
            // reassert: app switch, window reorder, space change.
            observers = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    self?.apply(to: window)
                }
            }
        }

        /// Idempotent, so re-running it on every notification is free when
        /// nothing was undone.
        private func apply(to window: NSWindow) {
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            // The Settings scene builds its window without .resizable — a
            // holdover from preference panels being fixed-size. The panes
            // here are min-sized and stretch, so let the window follow.
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            // An empty unified toolbar, for its geometry alone: it's what
            // moves the traffic lights down and in from the corner so they
            // sit on the sidebar capsule the way System Settings' do —
            // without it they hug the window's top-left at bare-titlebar
            // spacing.
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "SettingsChromeToolbar")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// `NSVisualEffectView` in sidebar material — SwiftUI's `.regularMaterial`
/// blends within the window, which over an opaque window background is just
/// a flat grey.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Pinned active rather than following the window: on this window the
        // follow behavior didn't reliably come back from an app switch — the
        // glass stayed flat until relaunch. A capsule that doesn't dim with
        // deactivation is the smaller wrongness.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
                    footer: "On a GitLab remote, avatars come from that instance — including a self-hosted one — by matching the commit author against its user list through `glab`, so uploaded faces work with no token to paste here. Everyone else falls back to Gravatar and GitHub. This is the one feature that talks to a server you didn't configure, which is why it's off until you turn it on."
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
