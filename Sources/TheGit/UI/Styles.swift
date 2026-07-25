import SwiftUI

/// Press feedback for plain icon buttons: subtle scale-down, fast ease-out.
/// (Bordered buttons get this from AppKit for free; .plain ones don't.)
struct PressEffectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressEffectButtonStyle {
    static var pressEffect: PressEffectButtonStyle { PressEffectButtonStyle() }
}
