import Foundation
import PortalKit

/// The stream sizes a game's own render size allows -> .claude/client.md § settings
public enum RenderSizes {
    public static let ownSize = "this game's own size"
    public static let yourSetting = "your size setting"
    /// Why a size is not offered.
    public static let aboveNote = "Above what this game renders"

    /// `all` in the order shown; a size is `enabled` when it is not known to be above the game. Nothing known: all.
    /// An exact size: none above it. A lower bound (a side reached the cap, the game may render more): up to the first size larger than it on both sides,
    /// so a person can raise the cap and learn the real size.
    public static func offered(all: [(UInt16, UInt16)], known: RenderSize?) -> [(size: (UInt16, UInt16), enabled: Bool)] {
        guard let known else { return all.map { ($0, true) } }
        func within(_ s: (UInt16, UInt16), _ limit: (w: UInt16, h: UInt16)) -> Bool { s.0 <= limit.w && s.1 <= limit.h }
        let limit: (w: UInt16, h: UInt16)
        if known.exact {
            limit = (known.width, known.height)
        } else if let next = all.first(where: { $0.0 > known.width && $0.1 > known.height }) {
            limit = (next.0, next.1)
        } else {
            return all.map { ($0, true) }
        }
        return all.map { ($0, within($0, limit)) }
    }

    /// The size a stream of this setting and game is, and why: the game's own size when it is below the cap, else the setting.
    public static func effective(cap: (UInt16, UInt16), known: RenderSize?) -> (width: Int, height: Int, reason: String) {
        if let known, known.exact, known.width < cap.0 || known.height < cap.1 {
            return (Int(min(cap.0, known.width)), Int(min(cap.1, known.height)), ownSize)
        }
        return (Int(cap.0), Int(cap.1), yourSetting)
    }

    /// The Host's own minimum picture (320 x 180) and a bound no real picture passes.
    public static let minimum = (width: UInt16(320), height: UInt16(180))
    public static let maximum: UInt16 = 16384

    /// A report worth keeping: between the Host's minimum size and `maximum` on both sides.
    public static func plausible(_ r: RenderSize) -> Bool {
        r.width >= minimum.width && r.height >= minimum.height && r.width <= maximum && r.height <= maximum
    }

    /// The size to keep after `new` arrives, nil = keep `old`. A lower bound at or under what is kept (exact or a bound) adds
    /// nothing: a bound only grows. An exact size replaces anything but a bound it is strictly below.
    public static func merged(old: RenderSize?, new: RenderSize) -> RenderSize? {
        guard let old else { return new }
        if old == new { return nil }
        let atOrUnder = new.width <= old.width && new.height <= old.height
        if !new.exact { return atOrUnder ? nil : new }
        let same = new.width == old.width && new.height == old.height
        return !old.exact && atOrUnder && !same ? nil : new
    }

    /// The note under a size choice: the line (when a game is known), then why some sizes are off.
    public static func note(line: String?, someAbove: Bool) -> String? {
        let parts = [line, someAbove ? aboveNote : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The one line every place shows: "1920 × 1080 · this game's own size".
    public static func line(width: Int, height: Int, reason: String) -> String { "\(width) × \(height) · \(reason)" }
}

/// What each game was last seen to render, by title ID, on this device (no game names): at most `limit` titles, the
/// least recently used (reported) dropped first.
public struct RenderMemory: Sendable {
    // UserDefaults is documented thread-safe; it is only not annotated Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    static let key = "knownRender", orderKey = "knownRenderOrder"
    public static let limit = 200
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var all: [String: RenderSize] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: RenderSize].self, from: $0) } ?? [:]
    }

    /// Oldest first.
    private var order: [String] { defaults.stringArray(forKey: Self.orderKey) ?? [] }

    /// Counts as a use of `titleID` (the least recently used title is the one dropped at the bound), changed or not.
    public func touch(_ titleID: String) {
        let ids = order.filter { $0 != titleID }
        guard all[titleID] != nil else { return }
        defaults.set(ids + [titleID], forKey: Self.orderKey)
    }

    public func set(_ r: RenderSize, for titleID: String) {
        var list = all
        var ids = order.filter { $0 != titleID && list[$0] != nil }
        list[titleID] = r
        ids.append(titleID)
        for id in list.keys where !ids.contains(id) { ids.insert(id, at: 0) }  // stored before the order was kept
        while ids.count > Self.limit { list[ids.removeFirst()] = nil }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
        defaults.set(ids, forKey: Self.orderKey)
    }
}
