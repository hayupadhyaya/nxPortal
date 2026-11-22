import XCTest
@testable import PortalPlayer

final class ArtPaletteTests: XCTestCase {
    private func hsl(h: Double, s: Double, l: Double) -> RGBA { RGBA.fromHSL(h: h, s: s, l: l) }
    private func pixels(_ c: RGBA, _ n: Int) -> [RGBA] { Array(repeating: c, count: n) }

    func testRed() {
        let p = ArtPalette.from(pixels: pixels(RGBA(0xFF0000), 64))
        XCTAssertTrue(p.hasGlow)
        let h = p.vivid.hsl
        XCTAssertTrue(h.h < 1 || h.h > 359, "hue \(h.h)")
        XCTAssertLessThanOrEqual(h.l, 0.55 + 1e-9)
    }

    func testGreyHasNoGlow() {
        let p = ArtPalette.from(pixels: pixels(RGBA(0x808080), 64))
        XCTAssertEqual(p, .slate)
        XCTAssertFalse(p.hasGlow)
    }

    func testNearBlackDropped() {
        let p = ArtPalette.from(pixels: pixels(RGBA(0x2040FF), 48) + pixels(RGBA(0x101010), 16))
        XCTAssertEqual(p.vivid.hsl.h, RGBA(0x2040FF).hsl.h, accuracy: 1)
        XCTAssertEqual(p.vivid.hsl.s, 1, accuracy: 0.01)
    }

    func testDeepIsTheDarkestSaturatedPixel() {
        let purple = RGBA(0x3A1C71), pink = RGBA(0xFF6EC7)
        let p = ArtPalette.from(pixels: pixels(purple, 32) + pixels(pink, 32))
        XCTAssertEqual(p.deep, purple)
    }

    func testDeterministic() {
        let px = pixels(RGBA(0x3A1C71), 20) + pixels(RGBA(0xFF6EC7), 20) + pixels(RGBA(0x10A0FF), 24)
        XCTAssertEqual(ArtPalette.from(pixels: px), ArtPalette.from(pixels: px))
    }

    func testTintContrastForEveryHueBucket() {
        let d = LookTokens.dark
        for bucket in 0..<12 {
            // the bucket's centre hue, full saturation, at the lightness clamp (the worst case)
            let c = hsl(h: Double(bucket) * 30 + 15, s: 1, l: 0.55)
            let vivid = ArtPalette.from(pixels: pixels(c, 64)).vivid
            let tint = ArtPalette.tint(vivid, alpha: 0.33)
            XCTAssertGreaterThanOrEqual(Contrast.ratio(d.text, tint), 4.5, "bucket \(bucket)")
        }
    }

    func testPNG() {
        XCTAssertNotNil(ArtPalette.from(png: ImageFixtures.gradient()))
        XCTAssertNil(ArtPalette.from(png: Data([1, 2, 3])))
    }

    func testTransparentPaddingIgnored() {
        // a red square with transparent padding: the padding is not read as darkened red
        let png = ImageFixtures.fill(RGBA(0xFF0000), side: 64, inset: 16)
        let p = ArtPalette.from(png: png)!
        XCTAssertEqual(p.vivid.hsl.l, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.vivid.r, 1, accuracy: 0.02)
        XCTAssertEqual(ArtPalette.from(pixels: pixels(RGBA(0xFF0000, alpha: 0.4), 60) + pixels(RGBA(0x00FF00), 4)).vivid.hsl.h,
                       120, accuracy: 1)
    }

    func testTieTakesTheLowerHue() {
        let p = ArtPalette.from(pixels: pixels(hsl(h: 200, s: 1, l: 0.5), 10) + pixels(hsl(h: 100, s: 1, l: 0.5), 10))
        XCTAssertEqual(p.vivid.hsl.h, 100, accuracy: 1)
    }

    func testLowSaturationDeep() {
        let c = hsl(h: 30, s: 0.3, l: 0.5)
        let p = ArtPalette.from(pixels: pixels(c, 64))
        XCTAssertTrue(p.hasGlow)
        XCTAssertEqual(p.deep.hsl.l, 0.2, accuracy: 0.001)
        XCTAssertEqual(p.deep.hsl.h, p.vivid.hsl.h, accuracy: 0.5)
        XCTAssertEqual(p.deep.hsl.s, p.vivid.hsl.s, accuracy: 0.01)
    }

    func testProgressEndIsTwentyDegreesOn() {
        let p = ArtPalette.from(pixels: pixels(hsl(h: 100, s: 1, l: 0.5), 64))
        XCTAssertEqual(p.progressEnd.hsl.h, 120, accuracy: 1)
    }
}
