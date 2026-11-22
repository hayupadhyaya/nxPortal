import PortalPlayer
import SwiftUI

/// The colour of secondary text and glyphs inside a portal row: the palette's own, or `onPlatterSecondary` while the row is
/// focused (a focused row is the platter, so a colour set by hand would be unreadable on it; tested in `LookTokensTests`).
struct RowTone: ViewModifier {
    enum Tone { case secondary, tertiary, accent }
    let tone: Tone
    @Environment(\.portalFocused) private var focused
    private var p: LookPalette { Theme.palette }

    func body(content: Content) -> some View {
        content.foregroundStyle(Theme.color(focused ? p.onPlatterSecondary : resting))
    }

    private var resting: RGBA {
        switch tone {
        case .secondary: p.secondaryText
        case .tertiary: p.tertiaryText
        case .accent: p.accentText
        }
    }
}

extension View {
    func rowTone(_ tone: RowTone.Tone) -> some View { modifier(RowTone(tone: tone)) }
}
