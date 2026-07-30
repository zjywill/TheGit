import AppKit
import SwiftUI

/// Holds at most one error toast, and owns the animation for it.
///
/// Its own view on purpose: `.animation(value:)` up on RepoView would enlist
/// every other change in the same transaction, and an error almost always
/// lands together with the refresh that follows the command that failed — the
/// graph must not slide about because a strip appeared over it. Empty, this
/// layer is zero-sized, so every click in the window goes where it did before.
struct ErrorToastLayer: View {
    @ObservedObject var repo: RepoState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let notice = repo.errorNotice {
                ErrorToast(notice: notice) { repo.errorNotice = nil }
                    .padding(.bottom, 14)
                    // Out the way it came in. Reduced motion keeps the
                    // fade — the news still has to announce itself — and
                    // drops the travel.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .easeOutStrong(0.28),
            value: repo.errorNotice
        )
    }
}

/// One failed command, said once, over the graph instead of in front of it.
///
/// It goes away by itself, because the alert it replaces was dismissed
/// unread nine times out of ten and this one costs nothing to ignore. Two
/// things make that safe: the timer is scaled to how much there is to read,
/// and a pointer resting on the strip holds it open indefinitely.
struct ErrorToast: View {
    let notice: ErrorNotice
    let dismiss: () -> Void
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomFont(12)
                // The one tinted thing here, same as the update banner: red
                // across a whole strip reads as a state the repo is in, and
                // this is one command, already over.
                .foregroundStyle(.red)
                // Aligned to the first line of text, not to the block.
                .padding(.top, 1 * zoom)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.summary)
                    .zoomFont(12, weight: .medium)
                    // Three lines is the longest a strip can be and still
                    // read as a strip; past that, Copy carries the rest.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                // Which command, not what happened — so it goes under, dim,
                // and truncated in the middle: the subcommand at the front
                // and the argument that usually names the file at the back
                // are the identifying halves.
                if let command = notice.command {
                    Text(command)
                        .zoomFont(10, design: .monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // A git error gets pasted into a search box or an issue more
            // often than it gets read twice, so this hands over the whole
            // thing — command included — rather than the part that fitted.
            Button {
                RepoState.copyToPasteboard(notice.detail)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy")
                    // Both words in one width: the strip must not resize
                    // under the pointer that just clicked it.
                    .frame(minWidth: 42 * zoom)
                    .zoomFont(11, weight: .medium)
                    .padding(.horizontal, 8 * zoom)
                    .padding(.vertical, 3 * zoom)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressEffect)
            .accessibilityLabel("Copy error text")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .zoomFont(9, weight: .bold)
                    .frame(width: 20 * zoom, height: 20 * zoom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            // An SF Symbol carries no name; without this it announces as a
            // bare "button".
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // Wide enough for a sentence, narrow enough to stay a strip. No
        // greedy child inside, so a short message gets a short toast.
        .frame(maxWidth: 460 * zoom, alignment: .leading)
        // A floating layer over content, not a region of the window:
        // material and a shadow, and no scrim — dimming the window would
        // make this exactly the interruption it exists to stop being.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        // Hairline: the graph behind this is busy, and a shadow alone leaves
        // the top edge of the strip undefined against a light background.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        // What the three lines had to cut, on hover, before Copy is needed.
        .help(notice.detail)
        .onHover { hovering = $0 }
        .task(id: notice.id) {
            copied = false
            // Nothing here takes focus — that is the whole point — so
            // VoiceOver would otherwise never learn that anything happened.
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: notice.summary,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
            // Scaled to the reading, not a flat four seconds: a 140-character
            // git sentence needs twice as long as "Nothing is staged".
            let seconds = min(14, max(6, Double(notice.summary.count) / 14))
            try? await Task.sleep(for: .seconds(seconds))
            // A pointer on the strip means someone is still reading it (and
            // is where the tooltip with the full text comes from), so the
            // countdown finishes only once it leaves.
            while hovering && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !Task.isCancelled { dismiss() }
        }
    }
}
