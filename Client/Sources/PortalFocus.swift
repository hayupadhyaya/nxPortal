import PortalPlayer
import SwiftUI

enum FocusKind { case tile, button, row }

/// True inside a control drawn with the focus look, while the system has focus on it.
extension EnvironmentValues {
    @Entry var portalFocused = false
}

/// The one focus look outside play, applied through the control itself so `isFocused` is true where it is read:
/// `Button { } label: { … }.buttonStyle(.portal(.button))`. `forced` pins a state (the component sheet only).
/// `PortalFocusable` is the same look with an action. -> .claude/client.md § look
extension ButtonStyle where Self == PortalButtonStyle {
    static func portal(_ kind: FocusKind, radius: CGFloat? = nil, fill: RGBA? = nil, text: RGBA? = nil,
                       forced: Bool? = nil) -> PortalButtonStyle {
        PortalButtonStyle(kind: kind, radius: radius, fill: fill, text: text, forced: forced)
    }
}

struct PortalButtonStyle: ButtonStyle {
    let kind: FocusKind
    let radius: CGFloat?
    let fill: RGBA?  // idle background of a button or row; focus turns it into the platter
    let text: RGBA?
    let forced: Bool?

    func makeBody(configuration: Configuration) -> some View {
        PortalFocusBody(kind: kind, radius: radius, fill: fill, text: text, forced: forced) { configuration.label }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)  // a touch press; touch never shows the focus look
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A focusable that acts: a `Button` drawn with the focus look, so it has the button trait for VoiceOver and runs
/// `action` on every default activation (tap, Select on the remote, Return / Space, a controller's A).
struct PortalFocusable<Content: View>: View {
    let kind: FocusKind
    var radius: CGFloat?
    var fill: RGBA?
    var text: RGBA?
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) { content }.buttonStyle(.portal(kind, radius: radius, fill: fill, text: text))
    }
}

/// Reads `isFocused` from inside the focusable's own content, the only place it is true.
struct PortalFocusBody<Content: View>: View {
    let kind: FocusKind
    let radius: CGFloat?
    let fill: RGBA?
    let text: RGBA?
    let forced: Bool?
    @ViewBuilder var content: Content
    @Environment(\.isFocused) private var engineFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var on: Bool { forced ?? engineFocused }
    private var p: LookPalette { Theme.palette }

    private func shape(_ extra: CGFloat) -> AnyShape {
        if kind == .button { return AnyShape(Capsule()) }
        let r = (radius ?? (kind == .tile ? 24 : Theme.radii.row)) + extra
        return AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }

    private var scale: CGFloat { kind == .tile ? 1.10 : kind == .button ? 1.06 : 1.025 }
    private var shadowOpacity: Double { kind == .tile ? 0.55 : 0.45 }
    private var shadowRadius: CGFloat { kind == .tile ? 22 : kind == .button ? 15 : 17 }
    private var shadowY: CGFloat { kind == .tile ? 22 : 14 }
    private var platter: Bool { on && kind != .tile }

    var body: some View {
        content
            .environment(\.portalFocused, on)
            .background {
                if platter { shape(0).fill(Theme.color(p.platter)) }  // a glass button / a row becomes the platter
                else if let fill { shape(0).fill(Theme.color(fill)) }
            }
            .foregroundStyle(Theme.color(platter ? p.onPlatter : (text ?? p.text)))
            .overlay {
                if on && kind == .tile {
                    shape(0).fill(LinearGradient(stops: [.init(color: Theme.color(p.sheen), location: 0),
                                                         .init(color: .clear, location: 0.42)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .allowsHitTesting(false)
                }
            }
            .overlay { if on && kind != .row { ring } }
            .shadow(color: Theme.color(p.shadow).opacity(on ? shadowOpacity : 0), radius: shadowRadius, y: shadowY)
            .modifier(Lift(active: on && kind == .tile && !reduceMotion))
            .scaleEffect(on && !reduceMotion ? scale : 1)
            .animation(Theme.focusAnimation(reduceMotion: reduceMotion), value: on)
            .focusEffectDisabled()  // the system effect is off everywhere; this one look draws instead
    }

    /// A band `width` thick whose outer edge is `out` pt beyond the content (corner radius = shape + out).
    private func band(_ out: CGFloat, _ width: CGFloat, _ color: Color) -> some View {
        shape(out).stroke(color, lineWidth: width).padding(-(out - width / 2))
    }

    /// 3 pt gap of Background, a 3 pt ring, a faint ring 8 pt beyond it. Corner = shape + gap + ring.
    private var ring: some View {
        ZStack {
            band(3, 3, Theme.color(p.background))
            band(6, 3, Theme.color(p.focusRing))
            band(14, 2, Theme.color(p.halo))
        }
        .allowsHitTesting(false)
    }
}

/// A tile lifts 3 % of its height.
private struct Lift: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.visualEffect { view, proxy in view.offset(y: active ? -proxy.size.height * 0.03 : 0) }
    }
}

/// The shared tile layout: the icon is the button (it scales and carries the ring), its name sits outside it
/// and never scales; `nameGap` clears the ring's reach below the icon (ring + scale + shadow, about 18 pt).
struct PortalTile<Icon: View>: View {
    let name: String
    let side: CGFloat
    var forced: Bool?
    var dimmed = false
    /// With `focus`: the screen's own focus value for this tile (restoring focus to it).
    var focusKey: String?
    var focus: FocusState<String?>.Binding?
    var action: () -> Void = {}
    @ViewBuilder var icon: Icon
    @FocusState private var focused: Bool
    static var nameGap: CGFloat { 22 }

    var body: some View {
        VStack(spacing: Self.nameGap) {
            Button(action: action) {
                icon.frame(width: side, height: side)
            }
            .buttonStyle(.portal(.tile, radius: side * Theme.radii.iconFraction, forced: forced))
            .focused($focused)
            .modifier(ScreenFocus(key: focusKey, focus: focus))
            .disabled(dimmed)
            Text(name).font(.subheadline)
                .fontWeight((forced ?? focused) ? .bold : .regular)
                .foregroundStyle(Theme.color(Theme.palette.text))
                .lineLimit(1)
        }
        .frame(width: side + 16)
        .zIndex((forced ?? focused) ? 1 : 0)
    }
}

private struct ScreenFocus: ViewModifier {
    let key: String?
    let focus: FocusState<String?>.Binding?
    func body(content: Content) -> some View {
        if let key, let focus { content.focused(focus, equals: key) } else { content }
    }
}
