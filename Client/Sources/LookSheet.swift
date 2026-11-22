#if DEBUG
import CoreGraphics
import ImageIO
import PortalPlayer
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only component sheet for the shared look; opened by `-autoLookSheet` (`-autoLookPage 2` = the second page
/// on a compact screen). Every colour comes from the palette. -> .claude/client.md § look
struct LookSheet: View {
    private let p = Theme.palette
    private let art: Data? = LookSheet.icon()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var segment = 0
    @State private var toggle = true

    private var page: Int { CommandLine.arguments.firstIndex(of: "-autoLookPage").flatMap { Int(CommandLine.arguments[$0 + 1]) } ?? 1 }
    private var palette: ArtPalette { art.flatMap(ArtPalette.from(png:)) ?? .slate }

    #if os(tvOS)
    private let side: CGFloat = 230, margin: CGFloat = 90, compact = false
    #else
    private var side: CGFloat { sizeClass == .compact ? 68 : 108 }
    private var margin: CGFloat { sizeClass == .compact ? 20 : 36 }
    private var compact: Bool { sizeClass == .compact }
    #endif

    /// The library's per-screen numbers (spec § look-glow table).
    private var ambient: AmbientBackground {
        #if os(tvOS)
        AmbientBackground(art: art, side: 1300, opacity: 0.70, shade: .vertical([(0, 0), (0.45, 0.35), (1, 0.90)]), blur: 140)
        #else
        compact ? AmbientBackground(art: art, side: 640, opacity: 0.30, shade: .vertical([(0, 0), (0.7, 0.85)]), blur: 90)
                : AmbientBackground(art: art, side: 900, opacity: 0.38, shade: .vertical([(0, 0), (0.6, 0.80)]), blur: 120)
        #endif
    }

    var body: some View {
        ScrollView {
                Group {
                    if compact {
                        VStack(alignment: .leading, spacing: 20) { if page == 1 { first } else { second } }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .top, spacing: 36) {
                            VStack(alignment: .leading, spacing: 24) { first }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 24) { second }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(margin)
        }
        .background { ambient }
        .foregroundStyle(Theme.color(p.text))
    }

    // MARK: pieces

    @ViewBuilder private var first: some View {
        Text("Look").font(.largeTitle.bold())
        header("Tiles")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 16), spacing: 12, alignment: .top)], spacing: 28) {
            // The first control takes the system's focus at launch on Apple TV (nothing forced there).
            tile("Focused", .focused); tile("Idle", .idle); tile("Preparing", .preparing)
            tile("Greyed", .greyed); tile("No icon", .slate)
        }
        .padding(.vertical, 18)
        header("Buttons")
        HStack(spacing: 14) {
            button("Play", fill: p.platter, text: p.onPlatter)
            button("Options", fill: p.fill2, text: p.text)
            button("Quit game", fill: p.fill, text: p.destructive)
        }
        #if !os(tvOS)
        HStack(spacing: 36) {
            button("Focused", fill: p.platter, text: p.onPlatter, forced: true)
            button("Glass focused", fill: p.fill2, text: p.text, forced: true)
        }
        .padding(.vertical, 10)
        #endif
    }

    @ViewBuilder private var second: some View {
        header("Rows")
        VStack(spacing: 0) {
            row("Mac", value: "Test Mac", last: false)
            toggleRow
            row("Bitrate", value: "30 Mbit/s", forced: forcedRow, last: true)
        }
        .glass(radius: Theme.radii.group)
        header("Banner")
        HStack(spacing: 12) {
            Circle().fill(Theme.color(p.warning)).frame(width: 8, height: 8)
            Text("Cannot reach Test Mac").font(.subheadline)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glass(.thick, radius: Theme.radii.banner)
        header("Segmented control")
        HStack(spacing: 0) {
            ForEach(Array(["Off", "Basic", "Full"].enumerated()), id: \.offset) { i, name in
                Text(name).font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                    .background { if segment == i { Capsule().fill(Theme.color(p.platter)) } }
                    .foregroundStyle(Theme.color(segment == i ? p.onPlatter : p.text))
                    .onTapGesture { segment = i }
            }
        }
        .background(Capsule().fill(Theme.color(p.fill2)))
        header("Progress")
        VStack(alignment: .leading, spacing: 8) {
            progress(0.36)
            Text("Preparing graphics, 36 %").font(.footnote).monospacedDigit()
                .foregroundStyle(Theme.color(p.secondaryText))
        }
        Text("Hints use tertiary text.").font(.caption).foregroundStyle(Theme.color(p.tertiaryText))
        Text("Pair a Mac…").font(.subheadline).foregroundStyle(Theme.color(p.accentText))
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.color(p.secondaryText))
    }

    private enum TileState { case idle, focused, preparing, greyed, slate }

    private func tile(_ name: String, _ state: TileState) -> some View {
        let r = side * Theme.radii.iconFraction
        #if os(tvOS)
        let forced: Bool? = nil  // the focus engine decides
        #else
        let forced: Bool? = state == .focused ? true : nil
        #endif
        return PortalTile(name: name, side: side, forced: forced, dimmed: state == .greyed) {
            ZStack {
                if state == .slate {
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.color(p.slateTop), Theme.color(p.slateBottom)],
                                             startPoint: .top, endPoint: .bottom))
                    Text("NP").font(.title2.bold()).foregroundStyle(Theme.color(p.initials))
                } else if let art, let img = UIImage(data: art) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                }
                if state == .preparing {
                    RoundedRectangle(cornerRadius: r, style: .continuous).fill(Theme.color(p.scrim))
                    Text("36 %").font(.headline).monospacedDigit()
                }
            }
            .opacity(state == .greyed ? 0.4 : 1)
        }
    }

    private func button(_ title: String, fill: RGBA, text: RGBA, forced: Bool? = nil) -> some View {
        Button {} label: {
            Text(title).font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 20).frame(minHeight: 44)
        }
        .buttonStyle(.portal(.button, fill: fill, text: text, forced: forced))
    }

    #if os(tvOS)
    private let forcedRow: Bool? = nil
    #else
    private let forcedRow: Bool? = true
    #endif

    private func row(_ title: String, value: String, forced: Bool? = nil, last: Bool) -> some View {
        Button {} label: {
            HStack {
                Text(title).font(.body)
                Spacer()
                RowValue(value: value)
            }
            .padding(.horizontal, 18).frame(minHeight: 50)
        }
        .buttonStyle(.portal(.row, forced: forced))
        .overlay(alignment: .bottom) {
            if !last { Theme.color(p.separator).frame(height: 1).padding(.leading, 18) }
        }
    }

    /// A row's value: secondary text, the platter's text at 68 % when the row is focused.
    private struct RowValue: View {
        let value: String
        @Environment(\.portalFocused) private var focused
        var body: some View {
            Text(value).font(.body)
                .foregroundStyle(Theme.color(focused ? Theme.palette.onPlatterSecondary : Theme.palette.secondaryText))
        }
    }

    private var toggleRow: some View {
        Toggle("Smooth picture", isOn: $toggle).tint(Theme.color(p.positive))
            .padding(.horizontal, 18).frame(minHeight: 50)
            .overlay(alignment: .bottom) { Theme.color(p.separator).frame(height: 1).padding(.leading, 18) }
    }

    private func progress(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.color(p.fill2))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.color(palette.vivid), Theme.color(palette.progressEnd)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    /// A gradient icon drawn from the palette's own colours.
    private static func icon() -> Data? {
        let p = Theme.palette, n = 512
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func cg(_ c: RGBA) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [cg(p.warning), cg(p.destructive), cg(p.accentFill)] as CFArray, locations: [0, 0.5, 1])
        ctx.drawLinearGradient(g!, start: .zero, end: CGPoint(x: n, y: n), options: [])
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
#endif
