#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Game bundles with icons drawn in code (flat colours, gradients, noise) for tests and `portal-hostd --fake`: no real
/// artwork anywhere -> .claude/host.md § library
public enum FakeArt {
    public enum Paint: Sendable {
        /// One sRGB colour, 0xRRGGBB.
        case flat(UInt32)
        /// Top-left to bottom-right.
        case gradient(UInt32, UInt32)
        /// Random pixels (a PNG that does not compress), from `seed`.
        case noise(seed: UInt64)
    }

    /// A `side` x `side` image.
    public static func image(_ paint: Paint, side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch paint {
        case let .flat(c):
            ctx.setFillColor(color(c))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        case let .gradient(a, b):
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(a), color(b)] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
        case let .noise(seed):
            var state = seed | 1
            let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(side * side) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                bytes[i * 4] = UInt8(truncatingIfNeeded: state)
                bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[i * 4 + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    /// Writes `image` as an `.icns` (or a `.png` when the URL says so).
    public static func write(_ image: CGImage, to url: URL) throws {
        let type = url.pathExtension == "png" ? UTType.png : UTType.icns
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // An `.icns` takes 1024 only as the 512 @2x slot (144 dpi).
        let dpi: [CFString: Any] = type == .icns && image.width == 1024 ? [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] : [:]
        CGImageDestinationAddImage(dest, image, dpi as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A made-up `launcher.json` list (labels of our own, nothing of a real game; the variables are ones of the Host's player allow-list, or its reader drops them) for screenshots and tests of the
    /// per-game options: two sections, basic and more rows, a range with a `base`, a `needs` row and a kind nobody knows.
    public static var sampleOptions: [[String: Any]] {
        func row(_ env: String, _ kind: String, _ section: String, _ label: String, _ note: String, _ def: String,
                 _ extra: [String: Any] = [:]) -> [String: Any] {
            ["env": env, "kind": kind, "section": section, "label": label, "note": note, "default": def].merging(extra) { $1 }
        }
        return [
            row("DM_FPS_TARGET", "choice", "Game", "Frame rate", "", "60", ["options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"]),
            row("DM_RENDER_SCALE", "range", "Game", "Render scale", "", "1.0",
                ["min": 0.5, "max": 1.0, "step": 0.05, "level": "basic", "base": ["docked": [1920, 1080], "handheld": [1280, 720]]]),
            row("DM_UPSCALER", "choice", "Game", "Upscaling", "", "std",
                ["options": [["std", "Standard"], ["sharp", "Sharper"], ["soft", "Softer"]], "level": "basic"]),
            row("DM_LANG", "choice", "Game", "Language", "", "en",
                ["options": [["en", "English (US)"], ["fr", "French"], ["de", "German"]], "level": "basic"]),
            row("DM_PSO_PREBUILD", "toggle", "Performance", "Frame buffering", "Smoother motion, a little more delay", "on",
                ["on": "on", "off": "off", "level": "basic"]),
            row("DM_FPS_HOLD", "toggle", "Performance", "Hold frames", "", "off", ["on": "on", "off": "off", "level": "basic"]),
            row("DM_RUMBLE_MIN", "range", "Performance", "Lowest rate", "Only while frames are held", "30",
                ["min": 10, "max": 60, "step": 5, "needs": "DM_FPS_HOLD=on"]),
            row("DM_RUMBLE_GAIN", "dial", "Performance", "Shadow detail", "", "High"),
            row("DM_PSO_MTL4", "toggle", "Performance", "Keep a cache", "", "on", ["on": "on", "off": "off"]),
            row("DM_OPMODE", "choice", "Game", "Fog", "", "full", ["options": [["full", "Full"], ["light", "Light"], ["none", "None"]]]),
        ]
    }

    /// `dir/<name>.app` with `DMTitleID`, `DMStream`, and (with `paint`) `CFBundleIconFile` "AppIcon" naming
    /// `Contents/Resources/AppIcon.icns`; with `options` a `Contents/Resources/dm/launcher.json` holding that list; returns the bundle.
    @discardableResult
    public static func makeApp(in dir: URL, titleID: String, name: String, streamable: Bool = true,
                               paint: Paint?, side: Int = 1024, options: [[String: Any]]? = nil) throws -> URL {
        let app = dir.appendingPathComponent(name + ".app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var plist: [String: Any] = ["DMTitleID": titleID, "CFBundleName": name, "DMStream": streamable]
        if let paint {
            plist["CFBundleIconFile"] = "AppIcon"
            try write(image(paint, side: side), to: resources.appendingPathComponent("AppIcon.icns"))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let options {
            let dm = resources.appendingPathComponent("dm")
            try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["schema": 1, "settings": options]).write(to: dm.appendingPathComponent("launcher.json"))
        }
        return app
    }
}
#endif
