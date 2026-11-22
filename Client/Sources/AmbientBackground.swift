import CoreGraphics
import PortalPlayer
import SwiftUI

/// Where the icon sits. -> look-details
enum AmbientPlacement { case top, leftThird, center }

/// Shade over the icon: stops are (location, Background alpha); the last holds to the end. -> look-glow
enum ShadeStyle {
    case vertical([(Double, Double)])
    case horizontal([(Double, Double)])
    case radial([(Double, Double)])
}

/// The game's icon, drawn huge and blurred behind a screen. No art: plain Background. Decorative.
struct AmbientBackground: View {
    let art: Data?
    let side: CGFloat
    let opacity: Double
    let shade: ShadeStyle
    var blur: Double = 90
    var placement: AmbientPlacement = .top

    @State private var image: CGImage?
    private var key: ArtKey? { art.map(ArtKey.init) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bg: Color { Theme.color(Theme.palette.background) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                bg
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high)
                        .saturation(1.6)
                        .frame(width: side, height: side)
                        .mask { feather(.horizontal) }  // the bitmap's edges are clamped (opaque): fade them out
                        .mask { feather(.vertical, topBleeds: placement == .top) }  // the top edge of a .top glow bleeds off the screen
                        .opacity(opacity)
                        .position(center(in: geo.size))
                        .transition(.opacity)
                        .id(key)
                    shadeView(size: geo.size)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? Theme.motion.reduced : Theme.motion.ambient), value: key)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: key) {
            guard let art else { image = nil; return }
            let radius = AmbientImage.bitmapBlur(points: blur, iconSide: Double(side))
            let cacheKey = "\(key.map { "\($0)" } ?? "")-\(Int(radius * 10))"
            if let hit = AmbientCache.shared.image(cacheKey) { image = hit; return }
            let made = await Task.detached(priority: .userInitiated) { AmbientImage.make(png: art, blurRadius: radius) }.value
            if let made { AmbientCache.shared.store(made, cacheKey) }
            guard !Task.isCancelled else { return }  // another icon took over (perhaps from the cache) while this one rendered
            image = made
        }
    }

    /// Mask that eases each edge from clear to opaque (smoothstep) over `blur x 2.5` pt, at least a quarter of the
    /// side, so no end of the glow reads as an edge -> look-glow
    private func feather(_ axis: Axis, topBleeds: Bool = false) -> some View {
        let f = min(0.5, max(blur * 2.5, Double(side) / 4) / Double(side))
        let ramp = (0...8).map { i -> (t: Double, a: Double) in
            let t = Double(i) / 8
            return (t, t * t * (3 - 2 * t))
        }
        var stops: [Gradient.Stop] = topBleeds ? [.init(color: bg, location: 0)]
            : ramp.map { .init(color: bg.opacity($0.a), location: $0.t * f) }
        stops += ramp.reversed().map { .init(color: bg.opacity($0.a), location: 1 - $0.t * f) }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: axis == .horizontal ? .leading : .top,
                              endPoint: axis == .horizontal ? .trailing : .bottom)
    }

    private func center(in size: CGSize) -> CGPoint {
        switch placement {
        case .top: CGPoint(x: size.width / 2, y: side / 2)
        case .leftThird: CGPoint(x: size.width / 3, y: size.height / 2)
        case .center: CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }

    private func gradient(_ stops: [(Double, Double)]) -> Gradient {
        Gradient(stops: stops.map { .init(color: bg.opacity($0.1), location: $0.0) })
    }

    @ViewBuilder private func shadeView(size: CGSize) -> some View {
        switch shade {
        case let .vertical(s): Rectangle().fill(LinearGradient(gradient: gradient(s), startPoint: .top, endPoint: .bottom))
        case let .horizontal(s): Rectangle().fill(LinearGradient(gradient: gradient(s), startPoint: .leading, endPoint: .trailing))
        case let .radial(s):
            Rectangle().fill(RadialGradient(gradient: gradient(s), center: .center, startRadius: 0,
                                            endRadius: max(size.width, size.height) / 2))
        }
    }
}

/// A cheap identity for an icon: size plus its first and last bytes (the PNG header holds the dimensions, the end
/// the final data), so views never compare whole `Data` values.
struct ArtKey: Hashable, CustomStringConvertible {
    let count: Int
    let head: [UInt8]
    let tail: [UInt8]
    init(_ data: Data) { count = data.count; head = Array(data.prefix(64)); tail = Array(data.suffix(64)) }
    var description: String { "\(count)-\(head.hashValue)-\(tail.hashValue)" }
}

/// One blurred bitmap per icon and blur, at most `countLimit` (64 x 64 KB).
final class AmbientCache: @unchecked Sendable {  // NSCache is thread-safe
    static let shared = AmbientCache()
    static let countLimit = 64
    private let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = AmbientCache.countLimit
        return c
    }()
    func image(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }
    func store(_ image: CGImage, _ key: String) { cache.setObject(image, forKey: key as NSString) }
}
