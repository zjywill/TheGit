import AppKit
import SwiftUI

// MARK: - Neo-brutalism design system for TheGit
//
// A deliberately loud, high-contrast skin: hard black outlines, offset
// **non-blurred** shadows (the neo-brutalist "stamp" shadow), flat
// high-saturation accent colours and rectilinear corners. Everything here is
// layered on top of the existing SwiftUI structure — no view is replaced,
// the modifiers are composed.

// MARK: Palette

extension Color {
    /// Neo-brutalist palette. Centralised so the whole skin reads as one
    /// voice no matter which surface pulls from it.
    enum Neo {
        /// Ink — the near-black all borders, text and shadows use.
        static let ink = Color(red: 0.07, green: 0.07, blue: 0.07)
        /// Paper — the flat warm off-white cards sit on.
        static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
        /// The load-bearing accent: electric butter yellow.
        static let accent = Color(red: 1.00, green: 0.90, blue: 0.06)
        /// Secondary pops. Kept tight — one yellow, one red, one blue, one
        /// green — so the skin stays loud but never rainbow.
        static let danger = Color(red: 1.00, green: 0.30, blue: 0.28)
        static let info = Color(red: 0.23, green: 0.43, blue: 1.00)
        static let good = Color(red: 0.18, green: 0.78, blue: 0.34)
        /// The punchy "off-white sections" tone behind the top bar.
        static let chrome = Color(red: 0.99, green: 0.98, blue: 0.95)
    }
}

// MARK: Core strokes & shadows

/// Hard shadow. Neo-brutalism's trademark is the shadow that does NOT blur:
/// it is a solid offset copy of the shape, usually 3–5pt down and to the
/// right. SwiftUI's `.shadow` with radius 0 draws exactly that.
struct NeoHardShadow: ViewModifier {
    var y: CGFloat = 4
    var x: CGFloat = 4
    var color: Color = Color.Neo.ink

    func body(content: Content) -> some View {
        content.shadow(color: color, radius: 0, x: x, y: y)
    }
}

extension View {
    /// Stamp a solid, un-blurred offset shadow under `self`.
    func neoShadow(y: CGFloat = 4, x: CGFloat = 4) -> some View {
        modifier(NeoHardShadow(y: y, x: x, color: Color.Neo.ink))
    }

    /// The shared border weight. Thick enough to read as drawn on, thin
    /// enough not to swallow a row of small controls.
    func neoBorder(width: CGFloat = 2) -> some View {
        overlay(Rectangle().strokeBorder(Color.Neo.ink, lineWidth: width))
    }
}

// MARK: Accent wiring

/// Make `Color.accentColor` resolve to the neo yellow everywhere, without a
/// site-by-site find-and-replace (the codebase leans on `accentColor` for
/// active tab, active branch, focus — exactly the "this is current" moments
/// that deserve the loudest colour).
extension ShapeStyle where Self == Color {
    static var neoAccent: Color { Color.Neo.accent }
}

// MARK: Buttons

/// A neo-brutalist push button: flat fill, 2pt ink border, hard shadow that
/// "depresses" on press.
struct NeoBrutalButtonStyle: ButtonStyle {
    var fill: Color = Color.Neo.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Rectangle().fill(fill))
            .neoBorder()
            .contentShape(Rectangle())
            // The whole point of the hard shadow is that it compresses into
            // the shape when pressed, like the button is being stamped into
            // the page.
            .offset(x: configuration.isPressed ? 4 : 0,
                    y: configuration.isPressed ? 4 : 0)
            .shadow(color: Color.Neo.ink, radius: 0,
                    x: configuration.isPressed ? 0 : 4,
                    y: configuration.isPressed ? 0 : 4)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == NeoBrutalButtonStyle {
    static var neoBrutal: NeoBrutalButtonStyle { NeoBrutalButtonStyle() }
}

// MARK: Cards & tiles

/// The bento surface the Dashboard and its activity tiles sit on: paper fill,
/// hard border, hard shadow. Rectangular — round corners are the opposite of
/// the language this skin speaks.
struct NeoBrutalCard: ViewModifier {
    var fill: Color = Color.Neo.paper

    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(fill))
            .overlay(Rectangle().strokeBorder(Color.Neo.ink, lineWidth: 2))
            .neoShadow()
    }
}

extension View {
    /// Wrap `self` in the skin's standard raised card.
    func neoCard(fill: Color = Color.Neo.paper) -> some View {
        modifier(NeoBrutalCard(fill: fill))
    }
}

/// A section heading in the skin's voice: heavy, uppercase, no softness.
struct NeoSectionTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .heavy, design: .default))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Color.Neo.ink)
    }
}

// MARK: Root skin

/// Applied once at the window root. Sets the shared accent so every existing
/// `accentColor` usage flips to the skin's yellow, and warms the base
/// background so cards read against it.
struct NeoBrutalRoot: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .tint(Color.Neo.accent)
            .background(Color.Neo.chrome)
    }
}

extension View {
    /// Activate the neo-brutalist skin for the whole window.
    func neoBrutal() -> some View {
        modifier(NeoBrutalRoot())
    }
}
