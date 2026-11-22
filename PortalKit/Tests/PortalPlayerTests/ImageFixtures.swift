import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PortalPlayer

/// PNGs generated in the tests; no files, no outside art.
enum ImageFixtures {
    /// A `side` x `side` PNG: `paint` draws in a top-left-origin context of that size, on transparent.
    static func png(side: Int, paint: (CGContext) -> Void) -> Data {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx)
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// A flat colour `width` x `height` PNG (small on disk whatever its size).
    static func flat(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func gradient(side: Int = 512) -> Data {
        png(side: side) { ctx in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let g = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1),
                                                            CGColor(red: 0.1, green: 0.3, blue: 1, alpha: 1)] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: side, y: side), options: [])
        }
    }

    static func fill(_ c: RGBA, side: Int = 64, inset: Int = 0) -> Data {
        png(side: side) { ctx in
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset))
        }
    }
}
