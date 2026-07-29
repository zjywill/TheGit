import SwiftUI

/// System Settings' grouped-card grammar, rebuilt on plain stacks: a small
/// header outside the card, a rounded surface of rows split by inset
/// hairlines, a caption footer under the card. Rebuilt rather than used —
/// `Form(.grouped)` is table-backed, and AppKit table views are banned
/// app-wide (macOS 26 reentrant-layout crash; see the zoom notes in
/// TheGitApp).
struct SettingsSection<Content: View>: View {
    @Environment(\.uiZoom) private var zoom
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * zoom) {
            if let title {
                Text(title)
                    .zoomFont(11, weight: .semibold)
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10 * zoom)
            }
            VStack(spacing: 0) { content() }
                // primary.opacity, not a fixed NSColor: reads as a raised
                // card in both appearances, like System Settings' groups.
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.07))
                )
            if let footer {
                Text(footer)
                    .zoomFont(10)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10 * zoom)
            }
        }
    }
}

/// One card row: label (and optional caption) leading, control trailing —
/// System Settings' mapping, so the eye scans labels down the left and
/// values down the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.uiZoom) private var zoom
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12 * zoom) {
            VStack(alignment: .leading, spacing: 2 * zoom) {
                Text(title).zoomFont(13)
                if let subtitle {
                    Text(subtitle)
                        .zoomFont(10)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12 * zoom)
            control()
        }
        .padding(.horizontal, 12 * zoom)
        .padding(.vertical, 8 * zoom)
        .frame(minHeight: 36 * zoom)
    }
}

/// The hairline between two rows, inset from the leading edge the way
/// System Settings insets it — the card's outline owns the edges.
struct SettingsDivider: View {
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        Divider().padding(.leading, 12 * zoom)
    }
}
