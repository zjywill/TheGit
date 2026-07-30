import AppKit
import SwiftUI

/// System font whose size multiplies by the UI zoom factor. Every fixed
/// font size in the app goes through this so Cmd+= / Cmd+- scale all text
/// together; the modifier reads the environment itself, so call sites
/// don't need their own @Environment property.
struct ZoomFontModifier: ViewModifier {
    @Environment(\.uiZoom) private var zoom
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default

    func body(content: Content) -> some View {
        content.font(.system(size: size * zoom, weight: weight, design: design))
    }
}

extension View {
    func zoomFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ZoomFontModifier(size: size, weight: weight, design: design))
    }
}

/// Press feedback for plain icon buttons: subtle scale-down, fast ease-out.
/// (Bordered buttons get this from AppKit for free; .plain ones don't.)
struct PressEffectButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var pressedOpacity: Double = 0.7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressEffectButtonStyle {
    static var pressEffect: PressEffectButtonStyle { PressEffectButtonStyle() }

    /// Same cue at row scale. A 6% shrink is calibrated for a 22pt icon;
    /// on a full-width row it reads as the panel flexing, not as a button
    /// answering, so a wide target moves far less and dims instead.
    static var rowPressEffect: PressEffectButtonStyle {
        PressEffectButtonStyle(scale: 0.985, pressedOpacity: 0.85)
    }
}

/// Reports whether the left button is down inside a view's bounds, without
/// touching the event.
///
/// A list row can't be a Button: it carries a single click, a double click,
/// a drag source, a drop target and a context menu, and a Button swallows
/// most of that. A gesture can't do it either — the zero-distance
/// DragGesture that would report the press is exactly the recogniser
/// `.draggable` needs, and the two fight over it. So: the same trick as
/// `RightClickCatcher`, watch the events and consume nothing. Nothing that
/// already works on a row can break, because nothing is intercepted.
struct PressCatcher: NSViewRepresentable {
    let onPress: (Bool) -> Void

    final class Coordinator {
        var onPress: ((Bool) -> Void)?
        weak var view: NSView?
        var monitor: Any?
        private var pressed = false

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
            ) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window
                else { return event }
                if event.type == .leftMouseDown {
                    let point = view.convert(event.locationInWindow, from: nil)
                    if view.bounds.contains(point) { self.set(true) }
                } else {
                    // Release on the mouse-up — and on the first drag too: a
                    // drag that becomes a real drag session never delivers its
                    // mouse-up here, and a row that stays lit after the pointer
                    // has left with a branch in hand is worse than no cue.
                    self.set(false)
                }
                return event // never consumed
            }
        }

        func set(_ value: Bool) {
            guard pressed != value else { return }
            pressed = value
            onPress?(value)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onPress = onPress
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onPress = onPress
        context.coordinator.install()
    }
}

extension Animation {
    /// Strong ease-out — cubic-bezier(0.23, 1, 0.32, 1). The built-in
    /// curves are too weak to read as intentional; this one moves
    /// immediately, which is what makes an entrance feel responsive.
    /// Use for anything entering the screen.
    static func easeOutStrong(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

/// The pull-request glyph as GitHub draws it — a two-dot rail, and an
/// elbow with an arrowhead dropping into a third dot — because that shape
/// is the one a GitHub user already reads as "pull request", and SF
/// Symbols has nothing that looks like it (arrow.triangle.pull doesn't).
/// Drawn on the octicon's own 16-unit grid so it can be checked against
/// the original coordinate for coordinate. Takes its color from
/// `foregroundStyle`, like the symbol it stands in for. Used on the
/// Dashboard's cards and in the sidebar's PR rows.
struct PullRequestGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 16
            let stroke = StrokeStyle(lineWidth: 1.7 * u, lineCap: .round)
            let r = 2.1 * u
            let leftX = 3.5 * u, rightX = 12.5 * u
            let topY = 3.5 * u, bottomY = 12.5 * u

            var lines = Path()
            // The rail, between its dots rather than through them: the
            // dots are hollow, and a line crossing one shows inside it.
            lines.move(to: CGPoint(x: leftX, y: topY + r))
            lines.addLine(to: CGPoint(x: leftX, y: bottomY - r))
            // The elbow: out of the arrowhead, around the corner, down
            // into the bottom-right dot.
            lines.move(to: CGPoint(x: 9.2 * u, y: topY))
            lines.addLine(to: CGPoint(x: 10 * u, y: topY))
            lines.addQuadCurve(
                to: CGPoint(x: rightX, y: topY + 2.5 * u),
                control: CGPoint(x: rightX, y: topY)
            )
            lines.addLine(to: CGPoint(x: rightX, y: bottomY - r))
            ctx.stroke(lines, with: .foreground, style: stroke)

            var dots = Path()
            for center in [
                CGPoint(x: leftX, y: topY),
                CGPoint(x: leftX, y: bottomY),
                CGPoint(x: rightX, y: bottomY),
            ] {
                dots.addEllipse(in: CGRect(
                    x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r
                ))
            }
            ctx.stroke(dots, with: .foreground, style: stroke)

            // The arrowhead, pointing back at the rail it came from.
            var head = Path()
            head.move(to: CGPoint(x: 6.9 * u, y: topY))
            head.addLine(to: CGPoint(x: 9.4 * u, y: topY - 2.2 * u))
            head.addLine(to: CGPoint(x: 9.4 * u, y: topY + 2.2 * u))
            head.closeSubpath()
            ctx.fill(head, with: .foreground)
        }
    }
}

extension Color {
    /// A forge label colour: GitHub sends "a2eeef", GitLab "#428BCA".
    /// Anything that isn't six hex digits is nil — a grey chip, never a
    /// wrong colour.
    init?(forgeHex: String?) {
        guard let raw = forgeHex?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return nil }
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// Perceived brightness of a forge label colour, 0–1 — decides whether
    /// the chip's text is black or white, same as GitHub does.
    static func forgeHexLuminance(_ hex: String?) -> Double {
        guard let raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return 1 }
        let stripped = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return 1 }
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}

/// A forge label as GitHub draws it: the label's own colour as the pill,
/// text flipped black or white by its brightness. A label whose colour we
/// don't know (GitLab listings) is a quiet grey outline instead.
struct LabelChip: View {
    let label: IssueLabel
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        if let color = Color(forgeHex: label.colorHex) {
            Text(label.name)
                .zoomFont(10, weight: .medium)
                .foregroundStyle(
                    Color.forgeHexLuminance(label.colorHex) > 0.6 ? .black : .white
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color))
        } else {
            Text(label.name)
                .zoomFont(10, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().strokeBorder(Color.primary.opacity(0.25)))
        }
    }
}
