import PortalPlayer
import SwiftUI

/// The shared look's colours as SwiftUI values; tokens live in `PortalPlayer.LookTokens`. -> .claude/client.md § look
enum Theme {
    /// Dark only in 1.0.
    static let palette = LookTokens.dark
    static let radii = LookTokens.radii
    static let motion = LookTokens.motion

    /// A button's minimum height (`§ look-space`): 44 pt, Apple TV 76.
    static let buttonHeight: CGFloat = {
        #if os(tvOS)
        76
        #else
        44
        #endif
    }()

    static func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }

    /// Spring for focus moves (180 ms feel); cross-fade only under Reduce Motion.
    static func focusAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: motion.reduced) : .spring(response: 0.35, dampingFraction: 0.8)
    }
}

extension Font {
    /// footnote and caption, which are under a television's text floor (`LookTokens.tvTextFloor`, `TVText`): subheadline there.
    static var small: Font {
        #if os(tvOS)
        .subheadline
        #else
        .footnote
        #endif
    }
    static var tiny: Font {
        #if os(tvOS)
        .subheadline
        #else
        .caption
        #endif
    }
}
