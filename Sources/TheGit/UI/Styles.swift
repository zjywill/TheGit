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

extension Animation {
    /// Strong ease-out — cubic-bezier(0.23, 1, 0.32, 1). The built-in
    /// curves are too weak to read as intentional; this one moves
    /// immediately, which is what makes an entrance feel responsive.
    /// Use for anything entering the screen.
    static func easeOutStrong(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}
