#if os(macOS)
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A game's icon as the device gets it: a PNG of at most `maxEdge` pixels a side and `maxBytes` -> .claude/host.md § library
public struct GameArtwork {
    /// An icon file larger than this is not read (an `.icns` with every size is a few MB).
    static let maxFileBytes = 64 * 1024 * 1024

    /// `Contents/Resources/<CFBundleIconFile>` (`.icns` added when it has no extension); nil without the key or the file.
    public static func iconURL(forBundle url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleIconFile"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        var icon = url.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        if icon.pathExtension.isEmpty { icon.appendPathExtension("icns") }
        return FileManager.default.isReadableFile(atPath: icon.path) ? icon : nil
    }

    /// The bundle's icon: its largest representation scaled down to `maxEdge`, re-encoded at 256, then 128 when the PNG is
    /// over `maxBytes`; nil when there is no icon or it does not decode.
    public static func png(forBundle url: URL, maxEdge: Int = 512, maxBytes: Int = 512 * 1024) -> Data? {
        guard let icon = iconURL(forBundle: url) else { return nil }
        return png(icon: icon, maxEdge: maxEdge, maxBytes: maxBytes)
    }

    static func png(icon: URL, maxEdge: Int, maxBytes: Int) -> Data? {
        guard let size = (try? icon.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
              let src = CGImageSourceCreateWithURL(icon as CFURL, nil) else { return nil }
        var best: (index: Int, side: Int)?
        for i in 0..<CGImageSourceGetCount(src) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            if best == nil || max(w, h) > best!.side { best = (i, max(w, h)) }
        }
        guard let best else { return nil }
        // The thumbnail call decodes at the asked size; the full bitmap of a huge representation is never made.
        for edge in [maxEdge, 256, 128] where edge <= maxEdge {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: min(edge, best.side)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, best.index, options as CFDictionary),
                  let data = encode(image) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// SHA-256 of the PNG, 64 lowercase hex characters (the cache key with the title ID).
    public static func hash(_ png: Data) -> String {
        SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
