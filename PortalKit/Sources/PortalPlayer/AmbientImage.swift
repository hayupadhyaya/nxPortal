import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// The blurred bitmap behind a screen: rendered once per icon at a small size, drawn scaled. -> look-glow
public enum AmbientImage {
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxSide = 4096
    /// A thumbnail of at most `maxPixel` per side; nil over `maxBytes` or `maxSide` (read from the header, before any decode).
    static func decode(_ png: Data, maxPixel: Int) -> CGImage? {
        guard png.count <= maxBytes, let src = CGImageSourceCreateWithData(png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxSide, h <= maxSide else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The bounded decode for a view (a tile's icon): at most `maxPixel` a side, nil past the caps.
    public static func thumbnail(_ png: Data, maxPixel: Int) -> CGImage? { decode(png, maxPixel: maxPixel) }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// `side` x `side` bitmap of the icon, Gaussian-blurred by `blurRadius` bitmap pixels, edges clamped (no fade to clear).
    public static func make(png: Data, side: Int = 128, blurRadius: Double) -> CGImage? {
        guard side > 0, let image = decode(png, maxPixel: max(256, side)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = ctx.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let blurred = CIImage(cgImage: small).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
        return context.createCGImage(blurred, from: extent)
    }

    /// Screen-point blur to bitmap-pixel blur: points / iconSide x bitmapSide. -> look-details
    public static func bitmapBlur(points: Double, iconSide: Double, bitmapSide: Int = 128) -> Double {
        points / iconSide * Double(bitmapSide)
    }
}
