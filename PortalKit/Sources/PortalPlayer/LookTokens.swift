import Foundation

/// sRGB colour with alpha, components 0...1. -> .claude/client.md § look
public struct RGBA: Equatable, Sendable, Codable {
    public var r, g, b, a: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// Source-over: `self` drawn on `below`; opaque when `below` is.
    public func over(_ below: RGBA) -> RGBA {
        let outA = a + below.a * (1 - a)
        guard outA > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ x: Double, _ y: Double) -> Double { (x * a + y * below.a * (1 - a)) / outA }
        return RGBA(r: mix(r, below.r), g: mix(g, below.g), b: mix(b, below.b), a: outA)
    }

    /// WCAG relative luminance (alpha ignored).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Hue in degrees 0..<360, saturation and lightness 0...1.
    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        guard d > 1e-12 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    static func fromHSL(h: Double, s: Double, l: Double, a: Double = 1) -> RGBA {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return RGBA(r: r1 + m, g: g1 + m, b: b1 + m, a: a)
    }
}

public enum Contrast {
    /// WCAG contrast ratio of two opaque colours, 1...21.
    public static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// Corner radii in points. -> look-shape
public struct Radii: Sendable {
    public let chip = 8.0, row = 16.0, group = 24.0, banner = 18.0, card = 26.0, cardPhone = 22.0, cardTV = 40.0
    public let sidebar = 30.0, sheet = 36.0, sheetPhone = 32.0, menu = 38.0, menuTV = 48.0
    /// An icon's radius as a fraction of its side.
    public let iconFraction = 0.225
}

/// Durations in seconds. -> look-motion
public struct Motion: Sendable {
    public let focus = 0.18, ambient = 0.45, sheet = 0.35, menu = 0.22, banner = 0.26, reduced = 0.15
}

/// Every colour a screen draws with; views hold no literal. -> look-colour
public struct LookPalette: Sendable {
    public var background, groupedSurface, glass, thickGlass, glassEdge, separator, fill, fill2: RGBA
    public var text, secondaryText, tertiaryText, accentFill, onAccent, accentText: RGBA
    public var positive, warning, destructive, platter, onPlatter, focusRing: RGBA
    public var slateTop, slateBottom, initials: RGBA
    /// Reduce Transparency stand-in for thick glass.
    public var thickSurface: RGBA
    /// The numbers panel's backing; scrims behind text; the first-run radial; shadow colour (views set the opacity).
    public var chip, scrim, accentGlow, shadow: RGBA
    /// The on-screen controller.
    /// Focus sheen, the second ring, the glass top line, the Increase Contrast edge.
    public var sheen, halo, topLine, edgeIncreased: RGBA
    public var touchIdle, touchPressed, touchOutline, touchRing, touchLabel, touchLabelPressed: RGBA
}

extension LookPalette {
    /// A tile's caption ("Rebuild needed", "Paused") over the ambient glow: Secondary fails there at the Apple TV's opacity (tested).
    public var tileCaption: RGBA { text }
    /// Secondary text and the checkmark on a focused row (the platter): the platter's text colour at 68 %.
    public var onPlatterSecondary: RGBA { RGBA(r: onPlatter.r, g: onPlatter.g, b: onPlatter.b, a: 0.68) }
    /// A switch's on track: accent text over the game picture (the menu, the options), where the fill fails 3:1 over a white
    /// picture (tested); the fill on an opaque surface (Settings).
    public func switchTint(overPicture: Bool) -> RGBA { overPicture ? accentText : accentFill }
    /// The numbers panel's backing: the chip colour at the spec's upper opacity (.66), so its text holds 4.5:1 over a white
    /// picture too (tested).
    public var panelBacking: RGBA { RGBA(r: chip.r, g: chip.g, b: chip.b, a: LookTokens.panelChipAlpha) }
}

public enum LookTokens {
    /// The Destructive tint of a wrong-code box; its digit is Destructive text on it (tested at 4.5:1).
    public static let wrongCodeTint = 0.12
    /// The numbers panel's chip opacity (the spec allows .55 to .66) and its text: light on the dark chip in either palette.
    public static let panelChipAlpha = 0.66
    public static var panelText: RGBA { dark.text }
    /// Text and spinner over the dimmed picture of the "reconnecting" screen (the palette's scrim sits between): light in either palette.
    public static var troubleText: RGBA { dark.text }
    /// Apple TV: no text under this many points (`§ look-type`); the numbers panel and every small style use it.
    public static let tvTextFloor = 29.0
    /// The numbers panel's text size and padding: 11 pt on iPhone and iPad, a television's floor on Apple TV.
    public static func numbersPanel(tv: Bool) -> (points: Double, padX: Double, padY: Double) {
        tv ? (tvTextFloor, 24, 14) : (11, 10, 7)
    }
    public static let radii = Radii()
    public static let motion = Motion()

    private static let white = RGBA(0xFFFFFF), black = RGBA(0x000000)

    public static let dark = LookPalette(
        background: RGBA(0x08090D), groupedSurface: RGBA(0x14161C),
        glass: RGBA(0x282A38, alpha: 0.50), thickGlass: RGBA(0x1E202A, alpha: 0.78),
        glassEdge: RGBA(0xFFFFFF, alpha: 0.16), separator: RGBA(0xFFFFFF, alpha: 0.09),
        fill: RGBA(0xFFFFFF, alpha: 0.07), fill2: RGBA(0xFFFFFF, alpha: 0.13),
        text: RGBA(0xF5F6FA), secondaryText: RGBA(0xAEB4C2), tertiaryText: RGBA(0x8D93A3),
        accentFill: RGBA(0x3F66F2), onAccent: white, accentText: RGBA(0x8FA8FF),
        positive: RGBA(0x30D158), warning: RGBA(0xFFB547), destructive: RGBA(0xFF6B6B),
        platter: RGBA(0xF5F6FA), onPlatter: RGBA(0x0B0C10), focusRing: white,
        slateTop: RGBA(0x3D414E), slateBottom: RGBA(0x23262F), initials: RGBA(0xDADEE8),
        thickSurface: RGBA(0x1E2029),
        chip: RGBA(0x0A0C12, alpha: 0.55), scrim: RGBA(0x000000, alpha: 0.45),
        accentGlow: RGBA(0x6E8BFF, alpha: 0.30), shadow: black,
        sheen: RGBA(0xFFFFFF, alpha: 0.38), halo: RGBA(0xFFFFFF, alpha: 0.16), topLine: RGBA(0xFFFFFF, alpha: 0.30),
        edgeIncreased: RGBA(0xFFFFFF, alpha: 0.35),
        touchIdle: RGBA(0xFFFFFF, alpha: 0.14), touchPressed: RGBA(0xFFFFFF, alpha: 0.45),
        touchOutline: RGBA(0xFFFFFF, alpha: 0.38), touchRing: RGBA(0xFFFFFF, alpha: 0.06),
        touchLabel: RGBA(0xFFFFFF, alpha: 0.6), touchLabelPressed: RGBA(0x000000, alpha: 0.7))

    /// Kept for later; not shipped in 1.0.
    public static let light = LookPalette(
        background: RGBA(0xEEF0F5), groupedSurface: RGBA(0xFFFFFF),
        glass: RGBA(0xFFFFFF, alpha: 0.58), thickGlass: RGBA(0xFFFFFF, alpha: 0.84),
        glassEdge: RGBA(0xFFFFFF), separator: RGBA(0x000000, alpha: 0.08),
        fill: RGBA(0x000000, alpha: 0.045), fill2: RGBA(0x000000, alpha: 0.085),
        text: RGBA(0x0B0C10), secondaryText: RGBA(0x4A5060), tertiaryText: RGBA(0x5B6172),
        accentFill: RGBA(0x3F66F2), onAccent: white, accentText: RGBA(0x2A4FD0),
        positive: RGBA(0x24A148), warning: RGBA(0x7A4F00), destructive: RGBA(0xB42318),
        platter: RGBA(0x0B0C10), onPlatter: RGBA(0xFFFFFF), focusRing: RGBA(0x0B0C10),
        slateTop: RGBA(0x3D414E), slateBottom: RGBA(0x23262F), initials: RGBA(0xDADEE8),
        thickSurface: RGBA(0xFFFFFF),
        chip: RGBA(0x0A0C12, alpha: 0.55), scrim: RGBA(0x000000, alpha: 0.45),
        accentGlow: RGBA(0x6E8BFF, alpha: 0.30), shadow: black,
        sheen: RGBA(0xFFFFFF, alpha: 0.38), halo: RGBA(0xFFFFFF, alpha: 0.16), topLine: RGBA(0xFFFFFF, alpha: 0.30),
        edgeIncreased: RGBA(0xFFFFFF, alpha: 0.35),
        touchIdle: RGBA(0xFFFFFF, alpha: 0.14), touchPressed: RGBA(0xFFFFFF, alpha: 0.45),
        touchOutline: RGBA(0xFFFFFF, alpha: 0.38), touchRing: RGBA(0xFFFFFF, alpha: 0.06),
        touchLabel: RGBA(0xFFFFFF, alpha: 0.6), touchLabelPressed: RGBA(0x000000, alpha: 0.7))
}

/// The tvOS point sizes of the text styles the app uses (Apple's table) and the style that stands for "small" on Apple TV:
/// footnote (23) and caption (25) are under the floor, so the app's views use `small` there (`Font.small` / `.tiny`).
public enum TVText {
    public enum Style: Sendable { case caption2, caption, footnote, subheadline, body, callout, headline, title3 }
    public static func points(_ s: Style) -> Double {
        switch s {
        case .caption2, .footnote: 23
        case .caption: 25
        case .subheadline, .body: 29
        case .callout: 31
        case .headline: 38
        case .title3: 48
        }
    }
    /// What `.footnote` and `.caption` become on Apple TV.
    public static let small: Style = .subheadline
}
