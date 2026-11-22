#!/usr/bin/env swift
// The app icon "Doorway" on every platform, drawn from one recipe (CoreGraphics, no outside art, deterministic: same bytes every run).
// usage: swift scripts/make_icons.swift [--check] <repo root>
// --check: draws into a temporary folder and fails when a committed image or Contents.json differs from what it draws
// (nothing in the repository is written)
// Writes: Client iOS icon 1024; the tvOS brand asset (App Icon 400x240 @1x/@2x, App Store 1280x768, each Back / Middle / Front;
// Top Shelf 1920x720 and Wide 2320x720 @1x/@2x); the Host's 16...1024 PNGs. Refuses a path outside the repository. Exits non-zero
// when a check after writing fails -> .claude/build.md § icons
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
let checkOnly = args.first == "--check"
guard args.count == (checkOnly ? 2 : 1) else {
    FileHandle.standardError.write(Data("usage: swift scripts/make_icons.swift [--check] <repo root>\n".utf8)); exit(2)
}
let repo = URL(fileURLWithPath: args.last!).standardizedFileURL.resolvingSymlinksInPath()
let fm = FileManager.default
guard fm.fileExists(atPath: repo.appendingPathComponent(".git").path), fm.fileExists(atPath: repo.appendingPathComponent("PortalKit/Package.swift").path) else {
    FileHandle.standardError.write(Data("not a repository root: \(repo.path)\n".utf8)); exit(2)
}

/// Where the images are drawn: the repository, or with `--check` a fresh temporary folder laid out the same way.
let out: URL = checkOnly
    ? fm.temporaryDirectory.appendingPathComponent("make_icons-\(UUID().uuidString)").resolvingSymlinksInPath()
    : repo

/// `url` with every symbolic link in the part that exists resolved (the rest is appended as it is).
func resolved(_ url: URL) -> URL {
    var head = url.standardizedFileURL, tail: [String] = []
    while !fm.fileExists(atPath: head.path), head.pathComponents.count > 1 {
        tail.insert(head.lastPathComponent, at: 0)
        head = head.deletingLastPathComponent()
    }
    return tail.reduce(head.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
}

/// Every path written goes through here: inside the output folder (symbolic links resolved first) or nothing.
func inside(_ url: URL) -> URL {
    let p = resolved(url).path
    guard p.hasPrefix(out.path + "/"), !p.contains("/../") else {
        FileHandle.standardError.write(Data("refusing a path outside the repository: \(p)\n".utf8)); exit(2)
    }
    return url
}

// MARK: the recipe (256 units; y down)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

enum Part { case field, shadow, glow, spill, lit }
let layerBack: Set<Part> = [.field], layerMiddle: Set<Part> = [.shadow, .glow, .spill], layerFront: Set<Part> = [.lit]
let everything: Set<Part> = [.field, .shadow, .glow, .spill, .lit]

/// Where the doorway stands on a canvas: its foot (x centre, y), its unit (pixels per recipe unit), how wide the glow spreads.
struct Stage { var cx: Double, foot: Double, unit: Double, glowWidth: Double, glowHeight: Double, spillWidth: Double }

func arch(_ ctx: CGContext, centre cx: Double, foot: Double, width: Double, top: Double) {
    let r = width / 2
    ctx.move(to: CGPoint(x: cx - r, y: foot))
    ctx.addLine(to: CGPoint(x: cx - r, y: top + r))
    ctx.addArc(center: CGPoint(x: cx, y: top + r), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)  // y down: a rising arch
    ctx.addLine(to: CGPoint(x: cx + r, y: foot))
    ctx.closePath()
}

/// Draws into a y-down context of w x h pixels. `field` is how the full-bleed background is painted.
func draw(_ ctx: CGContext, _ w: Double, _ h: Double, _ parts: Set<Part>, _ s: Stage, field: () -> Void) {
    let u = s.unit
    if parts.contains(.field) { field() }
    if parts.contains(.shadow) {
        ctx.saveGState()
        arch(ctx, centre: s.cx, foot: s.foot, width: 100 * u, top: s.foot - 174 * u)
        ctx.setFillColor(color(0x0E0B2A, 0.55)); ctx.fillPath()
        ctx.restoreGState()
    }
    if parts.contains(.glow) {
        ctx.saveGState()
        ctx.translateBy(x: s.cx, y: s.foot); ctx.scaleBy(x: s.glowWidth / 2, y: s.glowHeight / 2)
        ctx.drawRadialGradient(gradient([(0, color(0x9DB4FF, 0.9)), (1, color(0x9DB4FF, 0))]), startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }
    if parts.contains(.spill) {
        ctx.saveGState()
        ctx.move(to: CGPoint(x: s.cx - 38 * u, y: s.foot)); ctx.addLine(to: CGPoint(x: s.cx + 38 * u, y: s.foot))
        ctx.addLine(to: CGPoint(x: s.cx + s.spillWidth / 2, y: h)); ctx.addLine(to: CGPoint(x: s.cx - s.spillWidth / 2, y: h))
        ctx.closePath()
        ctx.setFillColor(color(0xDDE5FF, 0.28)); ctx.fillPath()
        ctx.restoreGState()
    }
    if parts.contains(.lit) {
        ctx.saveGState()
        arch(ctx, centre: s.cx, foot: s.foot, width: 76 * u, top: s.foot - 162 * u)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (1, color(0xBFD0FF))]),
                               start: CGPoint(x: s.cx, y: s.foot - 162 * u), end: CGPoint(x: s.cx, y: s.foot), options: [])
        ctx.restoreGState()
    }
}

func fieldIcon(_ ctx: CGContext, _ w: Double, _ h: Double) {  // linear 135 degrees, corner to corner
    ctx.drawLinearGradient(gradient([(0, color(0x6E8BFF)), (0.55, color(0x7B4DFF)), (1, color(0x1A1240))]),
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func fieldShelf(_ ctx: CGContext, _ w: Double, _ h: Double) {  // dark, left to right
    ctx.drawLinearGradient(gradient([(0, color(0x08090D)), (1, color(0x1A1240))]),
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: files

var written: [(url: URL, w: Int, h: Int)] = []

func context(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
    return ctx
}

func save(_ ctx: CGContext, _ w: Int, _ h: Int, to url: URL) {
    let url = inside(url)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
    written.append((url, w, h))
}

func json(_ obj: Any, to url: URL) {
    let url = inside(url)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    jsons.append(url)
}
var jsons: [URL] = []

/// The icon canvas: the doorway centred, its foot at 214 of 256 units.
func iconStage(_ w: Double, _ h: Double) -> Stage {
    let u = h / 256
    return Stage(cx: w / 2, foot: 214 * u, unit: u, glowWidth: 172 * u, glowHeight: 36 * u, spillWidth: 150 * u)
}
func shelfStage(_ w: Double, _ h: Double) -> Stage {
    let u = h * 0.5 / 162  // the lit arch is half the height
    return Stage(cx: w / 2, foot: h * 0.72, unit: u, glowWidth: w * 0.56, glowHeight: h * 0.22, spillWidth: 110 * u)
}

func png(_ w: Int, _ h: Int, parts: Set<Part>, opaque: Bool, stage: (Double, Double) -> Stage, field: @escaping (CGContext, Double, Double) -> Void, to url: URL) {
    let ctx = context(w, h, opaque: opaque)
    let (fw, fh) = (Double(w), Double(h))
    draw(ctx, fw, fh, parts, stage(fw, fh), field: { field(ctx, fw, fh) })
    save(ctx, w, h, to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]

// iOS: opaque, square corners (the system masks)
let ios = out.appendingPathComponent("Client/Resources/Assets.xcassets/AppIcon.appiconset")
png(1024, 1024, parts: everything, opaque: true, stage: iconStage, field: fieldIcon, to: ios.appendingPathComponent("icon-1024.png"))

// Host: the same doorway on the macOS shape (a rounded square inset in the canvas, as macOS icons are drawn)
let host = out.appendingPathComponent("Host/Resources/Assets.xcassets/AppIcon.appiconset")
for side in [16, 32, 64, 128, 256, 512, 1024] {
    let ctx = context(side, side, opaque: false)
    let w = Double(side), inset = w * 100 / 1024, body = w - 2 * inset
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: body, height: body), cornerWidth: body * 0.225, cornerHeight: body * 0.225, transform: nil))
    ctx.clip()
    ctx.translateBy(x: inset, y: inset)
    draw(ctx, body, body, everything, iconStage(body, body), field: { fieldIcon(ctx, body, body) })
    ctx.restoreGState()
    save(ctx, side, side, to: host.appendingPathComponent("icon-\(side).png"))
}

// tvOS
let tv = out.appendingPathComponent("Client/Resources/Assets-tvOS.xcassets")
let brand = tv.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
if !checkOnly { try? fm.removeItem(at: inside(brand)) }

func imageset(_ dir: URL, _ w: Int, _ h: Int, scales: [Int], draw drawFile: (Int, Int, URL) -> Void) {
    var images: [[String: Any]] = []
    for s in scales {
        let name = "image@\(s)x.png"
        drawFile(w * s, h * s, dir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "tv", "scale": "\(s)x"])
    }
    json(["images": images, "info": info], to: dir.appendingPathComponent("Contents.json"))
}

func imagestack(_ dir: URL, _ w: Int, _ h: Int, scales: [Int]) {
    json(["layers": [["filename": "Front.imagestacklayer"], ["filename": "Middle.imagestacklayer"], ["filename": "Back.imagestacklayer"]], "info": info],
         to: dir.appendingPathComponent("Contents.json"))
    for (name, parts, opaque) in [("Front", layerFront, false), ("Middle", layerMiddle, false), ("Back", layerBack, true)] as [(String, Set<Part>, Bool)] {
        let l = dir.appendingPathComponent("\(name).imagestacklayer")
        json(["info": info], to: l.appendingPathComponent("Contents.json"))
        imageset(l.appendingPathComponent("Content.imageset"), w, h, scales: scales) { pw, ph, url in
            png(pw, ph, parts: parts, opaque: opaque, stage: iconStage, field: fieldIcon, to: url)
        }
    }
}

imagestack(brand.appendingPathComponent("App Icon - App Store.imagestack"), 1280, 768, scales: [1])
imagestack(brand.appendingPathComponent("App Icon.imagestack"), 400, 240, scales: [1, 2])
for (name, w, h) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    imageset(brand.appendingPathComponent("\(name).imageset"), w, h, scales: [1, 2]) { pw, ph, url in
        png(pw, ph, parts: everything, opaque: true, stage: shelfStage, field: fieldShelf, to: url)
    }
}
json(["assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
], "info": info], to: brand.appendingPathComponent("Contents.json"))

// MARK: checks (exit non-zero on the first failure)

var failures: [String] = []
func fail(_ s: String) { failures.append(s) }

/// RGBA pixels of a file, y down.
func pixels(_ url: URL) -> (w: Int, h: Int, rgba: [UInt8], hasAlpha: Bool)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    _ = props
    // PNG colour type (IHDR, byte 25): 2 = RGB, 6 = RGB with alpha; the file is what ships, not the decoded image.
    let head = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
    return (w, h, buf, head.count < 26 || head[25] != 2)
}

/// The columns (first, last) holding any pixel with alpha > 0.
func litColumns(_ p: (w: Int, h: Int, rgba: [UInt8], hasAlpha: Bool)) -> (Int, Int)? {
    var first = Int.max, last = -1
    for y in 0..<p.h { for x in 0..<p.w where p.rgba[(y * p.w + x) * 4 + 3] > 0 { first = min(first, x); last = max(last, x) } }
    return last < 0 ? nil : (first, last)
}

for f in written {
    let rel = f.url.path.replacingOccurrences(of: out.path + "/", with: "")
    guard let p = pixels(f.url) else { fail("\(rel): unreadable"); continue }
    if p.w != f.w || p.h != f.h { fail("\(rel): \(p.w)x\(p.h), slot \(f.w)x\(f.h)") }
    if rel == "Client/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png", p.hasAlpha { fail("\(rel): the iOS icon has an alpha channel") }
    if rel.contains("Back.imagestacklayer") || rel.contains("/Top Shelf Image"), p.hasAlpha || stride(from: 3, to: p.rgba.count, by: 4).contains(where: { p.rgba[$0] != 255 }) {
        fail("\(rel): must be fully opaque")
    }
    for (layer, share) in [("Front.imagestacklayer", 0.60), ("Middle.imagestacklayer", 0.80)] where rel.contains(layer) {
        guard let (a, b) = litColumns(p) else { fail("\(rel): nothing drawn"); continue }
        let margin = Double(p.w) * (1 - share) / 2
        if Double(a) < margin || Double(b + 1) > Double(p.w) - margin {
            fail("\(rel): lit pixels span columns \(a)...\(b) of \(p.w), outside the centre \(Int(share * 100)) %")
        }
    }
}
if checkOnly {
    // The committed files must be byte for byte what the recipe draws (it is deterministic).
    for drawn in written.map(\.url) + jsons {
        let rel = drawn.path.replacingOccurrences(of: out.path + "/", with: "")
        let committed = repo.appendingPathComponent(rel)
        if (try? Data(contentsOf: committed)) != (try? Data(contentsOf: drawn)) { fail("\(rel): differs from what the script draws") }
    }
    try? fm.removeItem(at: out)
}
if failures.isEmpty {
    print(checkOnly ? "checked \(written.count) images and \(jsons.count) Contents.json: the committed files are what the script draws"
                    : "wrote \(written.count) images; sizes, alpha and parallax-safe areas checked")
} else {
    for f in failures { FileHandle.standardError.write(Data("CHECK FAILED: \(f)\n".utf8)) }
    exit(1)
}
