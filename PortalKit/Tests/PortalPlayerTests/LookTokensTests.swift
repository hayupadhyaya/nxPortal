import XCTest
@testable import PortalPlayer

final class LookTokensTests: XCTestCase {
    private let d = LookTokens.dark

    func testExtremes() {
        XCTAssertEqual(Contrast.ratio(RGBA(0xFFFFFF), RGBA(0x000000)), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(RGBA(0x123456), RGBA(0x123456)), 1, accuracy: 0.001)
    }

    func testNamedPairs() {
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.secondaryText, d.background), 9.5)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.tertiaryText, d.background), 6.3)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.accentText, d.background), 8.0)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.onAccent, d.accentFill), 4.5)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.onPlatter, d.platter), 15)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(d.destructive, d.thickGlass.over(d.background)), 4.5)
        let l = LookTokens.light
        XCTAssertGreaterThanOrEqual(Contrast.ratio(l.secondaryText, l.background), 7.0)
    }

    func testTextOnEverySurface() {
        let surfaces = [d.background, d.glass.over(d.background), d.thickGlass.over(d.background)]
        for (name, c) in [("secondary", d.secondaryText), ("tertiary", d.tertiaryText), ("accentText", d.accentText),
                          ("warning", d.warning), ("destructive", d.destructive)] {
            for (i, s) in surfaces.enumerated() {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(c, s), 4.5, "\(name) on surface \(i)")
            }
        }
    }

    /// Every text colour a screen draws on the grouped surface (sidebar, sheets) and on the fill tokens, 4.5:1.
    /// Tertiary is not drawn on `fill2` (the current Mac's row uses secondary), destructive not on a fill: only on the
    /// grouped surface, the background and the wrong-code boxes (glass tinted with itself).
    func testTextOnGroupedSurfaceAndFills() {
        for palette in [LookTokens.dark, LookTokens.light] { checkGroupedAndFills(palette) }
    }

    private func checkGroupedAndFills(_ d: LookPalette) {
        let glass = d.glass.over(d.background), thick = d.thickGlass.over(d.background), grouped = d.groupedSurface
        let fills: [(String, RGBA)] = [("fill on grouped", d.fill.over(grouped)), ("fill2 on grouped", d.fill2.over(grouped)),
                                       ("fill on glass", d.fill.over(glass)), ("fill2 on glass", d.fill2.over(glass)),
                                       ("fill2 on thick glass", d.fill2.over(thick)), ("fill on background", d.fill.over(d.background)),
                                       ("fill2 on background", d.fill2.over(d.background))]
        let plain: [(String, RGBA)] = [("grouped", grouped), ("glass on grouped", d.glass.over(grouped))]
        let wrongCodeBox = RGBA(r: d.destructive.r, g: d.destructive.g, b: d.destructive.b, a: LookTokens.wrongCodeTint).over(d.glass.over(grouped))
        func check(_ name: String, _ c: RGBA, _ surfaces: [(String, RGBA)]) {
            for (surface, s) in surfaces { XCTAssertGreaterThanOrEqual(Contrast.ratio(c, s), 4.5, "\(name) on \(surface)") }
        }
        for (name, c) in [("text", d.text), ("secondary", d.secondaryText), ("accentText", d.accentText), ("warning", d.warning)] {
            check(name, c, plain + fills)
        }
        check("tertiary", d.tertiaryText, plain + fills.filter { !$0.0.hasPrefix("fill2") })
        check("destructive", d.destructive, plain + [("wrong-code box", wrongCodeBox)])
    }

    /// The initials of a game without an icon sit on its Slate square (the top and bottom stops).
    func testInitialsOnBothSlateStops() {
        for t in [d, LookTokens.light] {
            for stop in [t.slateTop, t.slateBottom] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.initials, stop), 4.5)
            }
        }
    }

    /// A tile's name and its caption ("Rebuild needed", "Paused") are drawn over the library's ambient glow: a mid-tone icon
    /// colour at the opacity of the platform (iPhone .30, iPad .38, Apple TV .70) under the shade at the top of the grid
    /// (`LibraryView.ambient`).
    func testTileNameAndCaptionOverAMidToneGlow() {
        let midTone = RGBA(0x808080)
        for (name, opacity, shade) in [("iPhone", 0.30, 0.85 * 0.3 / 0.7), ("iPad", 0.38, 0.80 * 0.3 / 0.6), ("Apple TV", 0.70, 0.35 * 0.3 / 0.45)] {
            let glow = RGBA(r: midTone.r, g: midTone.g, b: midTone.b, a: opacity).over(d.background)
            let shaded = RGBA(r: 0, g: 0, b: 0, a: shade).over(glow)
            XCTAssertGreaterThanOrEqual(Contrast.ratio(d.text, shaded), 4.5, "name, \(name)")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(d.tileCaption, shaded), 4.5, "caption, \(name)")
        }
    }

    /// Every text the library draws over its glow, over a black, a mid-grey and a white icon, at each platform's opacity and the
    /// shade at the height it sits (`LibraryView.ambient`): Primary and the tile caption straight on the glow (iPad's "N games",
    /// the tile names); on Apple TV the focus caption and Refresh sit on thick glass (Secondary and the accent colour hold only
    /// on a ground: they fail over a white icon's glow, so they are not drawn straight on it).
    func testLibraryTextOverTheGlowOfAnyIcon() {
        func shade(_ stops: [(Double, Double)], at y: Double) -> Double {
            var prev = stops[0]
            for s in stops.dropFirst() {
                if y <= s.0 { return prev.1 + (s.1 - prev.1) * (y - prev.0) / (s.0 - prev.0) }
                prev = s
            }
            return prev.1
        }
        let ipad = (opacity: 0.38, stops: [(0.0, 0.0), (0.6, 0.80)])
        let tv = (opacity: 0.70, stops: [(0.0, 0.0), (0.45, 0.35), (1.0, 0.90)])
        func ground(_ icon: RGBA, _ p: (opacity: Double, stops: [(Double, Double)]), _ y: Double) -> RGBA {
            let glow = RGBA(r: icon.r, g: icon.g, b: icon.b, a: p.opacity).over(d.background)
            return RGBA(r: d.background.r, g: d.background.g, b: d.background.b, a: shade(p.stops, at: y)).over(glow)
        }
        for icon in [RGBA(0x000000), RGBA(0x808080), RGBA(0xFFFFFF)] {
            for (name, p, ys) in [("iPad", ipad, [0.17, 0.5]), ("Apple TV tile names", tv, [0.88])] {
                for y in ys {
                    for (what, c) in [("text", d.text), ("tileCaption", d.tileCaption)] {
                        XCTAssertGreaterThanOrEqual(Contrast.ratio(c, ground(icon, p, y)), 4.5, "\(what) over a \(icon) icon, \(name), at \(y)")
                    }
                }
            }
            for y in [0.05, 0.28, 0.36] {  // Refresh, the focus caption's heights
                let glass = d.thickGlass.over(ground(icon, tv, y))
                for (what, c) in [("text", d.text), ("tileCaption", d.tileCaption)] {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(c, glass), 4.5, "\(what) on glass over a \(icon) icon, Apple TV, at \(y)")
                }
            }
        }
    }

    func testNothingOnAppleTvIsUnderTheTextFloor() {
        XCTAssertEqual(LookTokens.tvTextFloor, 29)
        XCTAssertGreaterThanOrEqual(LookTokens.numbersPanel(tv: true).points, LookTokens.tvTextFloor, "the numbers panel on a television")
        XCTAssertEqual(LookTokens.numbersPanel(tv: false).points, 11, "iPhone and iPad keep the spec's 11 pt")
        XCTAssertGreaterThanOrEqual(TVText.points(TVText.small), LookTokens.tvTextFloor, "what footnote and caption become")
        XCTAssertLessThan(TVText.points(.footnote), LookTokens.tvTextFloor, "why footnote is replaced")
        XCTAssertLessThan(TVText.points(.caption), LookTokens.tvTextFloor, "why caption is replaced")
        for s in [TVText.Style.subheadline, .body, .callout, .headline, .title3] {
            XCTAssertGreaterThanOrEqual(TVText.points(s), LookTokens.tvTextFloor, "\(s)")
        }
    }

    /// A focused row is the platter: its secondary text and its checkmark are the platter's text colour.
    func testTextOnTheFocusedPlatter() {
        for t in [d, LookTokens.light] {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.onPlatter, t.platter), 15)
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.onPlatterSecondary.over(t.platter), t.platter), 4.5)
        }
    }

    func testOverIsOpaqueAndExact() {
        let g = d.glass.over(d.background)
        XCTAssertEqual(g.a, 1, accuracy: 1e-9)
        // glass (40,42,56)/255 at .50 over (8,9,13)/255
        XCTAssertEqual(g.r, (40 * 0.5 + 8 * 0.5) / 255, accuracy: 0.0005)
        XCTAssertEqual(g.g, (42 * 0.5 + 9 * 0.5) / 255, accuracy: 0.0005)
        XCTAssertEqual(g.b, (56 * 0.5 + 13 * 0.5) / 255, accuracy: 0.0005)
        XCTAssertEqual(RGBA(0x08090D).over(RGBA(0xFFFFFF)).a, 1)
    }

    func testValuesFromTheSpec() {
        XCTAssertEqual(d.background, RGBA(0x08090D))
        XCTAssertEqual(d.glass, RGBA(0x282A38, alpha: 0.50))
        XCTAssertEqual(d.thickGlass, RGBA(0x1E202A, alpha: 0.78))
        XCTAssertEqual(d.onAccent, RGBA(0xFFFFFF))
        XCTAssertEqual(LookTokens.light.background, RGBA(0xEEF0F5))
        XCTAssertEqual(LookTokens.radii.card, 26)
        XCTAssertEqual(LookTokens.radii.iconFraction, 0.225)
        XCTAssertEqual(LookTokens.motion.focus, 0.18)
        XCTAssertEqual(LookTokens.motion.reduced, 0.15)
    }
}

/// The pairs the numbers panel and the in-play menu draw over the live picture, which can be any colour: tested over a
/// black, a mid-grey and a white picture (the worst cases), in both palettes, at 4.5:1.
final class PlayOverlayContrastTests: XCTestCase {
    private let pictures: [(String, RGBA)] = [("black picture", RGBA(0x000000)), ("grey picture", RGBA(0x808080)), ("white picture", RGBA(0xFFFFFF))]
    private let palettes: [(String, LookPalette)] = [("dark", LookTokens.dark), ("light", LookTokens.light)]

    func testTheNumbersPanelTextOnItsChip() {
        for (pn, p) in palettes {
            for (name, pic) in pictures {
                let chip = p.panelBacking.over(pic)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(LookTokens.panelText, chip), 4.5, "panel text, \(pn) palette, \(name)")
            }
        }
    }

    /// The menu card is thick glass over the scrim over the picture: its headers, captions, footers and rows, and the
    /// buttons (fill 2 on the card), including Quit's destructive colour.
    func testTheInPlayMenuTextOverTheScrimOverAnyPicture() {
        for (pn, p) in palettes {
            for (name, pic) in pictures {
                let card = p.thickGlass.over(p.scrim.over(pic))
                let button = p.fill2.over(card), row = p.glass.over(card)
                func check(_ what: String, _ c: RGBA, _ s: RGBA) {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(c, s), 4.5, "\(what), \(pn), \(name)")
                }
                check("title on card", p.text, card)
                check("group header on card", p.secondaryText, card)
                check("group caption on card (Secondary: Tertiary fails over a bright picture)", p.secondaryText, card)
                check("footer on card", p.secondaryText, card)
                check("text on button", p.text, button)
                check("Quit's label on its fill", p.text, p.fill.over(card))
                XCTAssertGreaterThanOrEqual(Contrast.ratio(p.destructive, card), 3, "Quit's red ring (a control edge, 3:1), \(pn), \(name)")
                check("text on row", p.text, row)
                check("secondary on row", p.secondaryText, row)
                check("accent text on row", p.accentText, row)
            }
        }
    }

    /// The on-screen controller keeps the runtime's own look: white at these opacities, black text when a key is pressed.
    func testTheOnScreenControllersColours() {
        for p in [LookTokens.dark, LookTokens.light] {
            XCTAssertEqual(p.touchIdle, RGBA(0xFFFFFF, alpha: 0.14))
            XCTAssertEqual(p.touchPressed, RGBA(0xFFFFFF, alpha: 0.45))
            XCTAssertEqual(p.touchOutline, RGBA(0xFFFFFF, alpha: 0.38))
            XCTAssertEqual(p.touchRing, RGBA(0xFFFFFF, alpha: 0.06))
            XCTAssertEqual(p.touchLabel, RGBA(0xFFFFFF, alpha: 0.6))
            XCTAssertEqual(p.touchLabelPressed, RGBA(0x000000, alpha: 0.7))
        }
    }
}
