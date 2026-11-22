import CoreGraphics
import Foundation
import ImageIO

/// The two colours an icon lends the screen. Pure; computed once per icon. -> .claude/client.md § look
public struct ArtPalette: Equatable, Sendable, Codable {
    public var vivid: RGBA
    public var deep: RGBA
    /// False: no icon, or a grey one; the screen draws no ambient layer.
    public var hasGlow: Bool

    public static let slate = ArtPalette(vivid: LookTokens.dark.slateTop, deep: LookTokens.dark.slateBottom, hasGlow: false)

    /// Spec § look-glow steps 1-5 over the 8 x 8 pixels (un-premultiplied; alpha under 0.5 ignored).
    public static func from(pixels: [RGBA]) -> ArtPalette {
        typealias Kept = (c: RGBA, h: Double, s: Double, l: Double)
        let kept: [Kept] = pixels.filter { $0.a >= 0.5 }.compactMap { c in
            let v = c.hsl
            guard v.l <= 0.9, v.l >= 0.08, v.s >= 0.25 else { return nil }
            return (c, v.h, v.s, v.l)
        }
        guard !kept.isEmpty else { return .slate }
        var counts = [Int](repeating: 0, count: 12)
        for k in kept { counts[min(11, Int(k.h / 30))] += 1 }
        var best = 0
        for b in 1..<12 where counts[b] > counts[best] { best = b }  // a tie keeps the lower hue
        let members = kept.filter { min(11, Int($0.h / 30)) == best }
        let n = Double(members.count)
        let avg = RGBA(r: members.reduce(0) { $0 + $1.c.r } / n, g: members.reduce(0) { $0 + $1.c.g } / n,
                       b: members.reduce(0) { $0 + $1.c.b } / n)
        let v = avg.hsl
        let vivid = RGBA.fromHSL(h: v.h, s: v.s, l: min(v.l, 0.55))
        var deep: Kept?
        for k in kept where k.s >= 0.35 && (deep == nil || k.l < deep!.l) { deep = k }
        let deepColour = deep?.c ?? RGBA.fromHSL(h: v.h, s: v.s, l: 0.2)
        return ArtPalette(vivid: vivid, deep: deepColour, hasGlow: true)
    }

    /// nil when `png` does not decode.
    public static func from(png: Data) -> ArtPalette? {
        guard let image = AmbientImage.decode(png, maxPixel: 64) else { return nil }
        let side = 8
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        let drew = raw.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        let pixels: [RGBA] = stride(from: 0, to: raw.count, by: 4).map { i in
            let a = Double(raw[i + 3]) / 255
            guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
            return RGBA(r: min(1, Double(raw[i]) / 255 / a), g: min(1, Double(raw[i + 1]) / 255 / a),
                        b: min(1, Double(raw[i + 2]) / 255 / a), a: a)
        }
        return from(pixels: pixels)
    }

    /// Vivid at `alpha` over glass over Background: the Continue card's worst point. -> look-access
    public static func tint(_ vivid: RGBA, alpha: Double) -> RGBA {
        let d = LookTokens.dark
        var v = vivid
        v.a = alpha
        return v.over(d.glass.over(d.background))
    }

    /// The end of a progress bar's gradient: Vivid turned 20 degrees.
    public var progressEnd: RGBA {
        let v = vivid.hsl
        return RGBA.fromHSL(h: v.h + 20, s: v.s, l: v.l)
    }
}
