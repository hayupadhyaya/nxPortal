import PortalPlayer
import SwiftUI

enum GlassThickness { case regular, thick }

extension View {
    /// Tinted glass behind the view: rows, groups, cards (regular); sheets, menus, banners (thick). -> look-shape
    func glass(_ thickness: GlassThickness = .regular, radius: CGFloat, tint: RGBA? = nil) -> some View {
        modifier(GlassBackground(thickness: thickness, radius: radius, tint: tint))
    }
}

private struct GlassBackground: ViewModifier {
    let thickness: GlassThickness
    let radius: CGFloat
    let tint: RGBA?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var p: LookPalette { Theme.palette }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    private var thick: Bool { thickness == .thick }
    private var edge: Color { Theme.color(contrast == .increased ? p.edgeIncreased : p.glassEdge) }
    private var fill: Color { Theme.color(thick ? p.thickGlass : p.glass) }

    func body(content: Content) -> some View {
        content
            .background { surface }
            .overlay { shape.strokeBorder(edge, lineWidth: 1).allowsHitTesting(false) }
            .overlay {  // 1 pt inner line along the top only
                shape.strokeBorder(Theme.color(p.topLine), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: max(radius, 8)) }
                    .allowsHitTesting(false)
            }
            .shadow(color: Theme.color(p.shadow).opacity(thick ? 0.45 : 0.30), radius: thick ? 30 : 15, y: thick ? 24 : 10)
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(Theme.color(thick ? p.thickSurface : p.groupedSurface))
        } else if #available(iOS 26, tvOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint.map { Theme.color($0) } ?? fill), in: shape)
        } else {
            ZStack {
                shape.fill(thick ? .thinMaterial : .ultraThinMaterial)
                shape.fill(fill)
                if let tint { shape.fill(Theme.color(tint)) }
            }
        }
    }
}
