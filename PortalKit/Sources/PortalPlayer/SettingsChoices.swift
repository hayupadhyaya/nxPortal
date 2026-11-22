import Foundation

/// The values the size, frame-rate, bitrate and sound-buffer pickers offer (Settings and the in-play menu); the app's views
/// only name them -> .claude/client.md § settings
public enum SettingsChoices {
    public struct Size: Hashable, Sendable {
        public var width: UInt16, height: UInt16
        public init(width: UInt16, height: UInt16) { self.width = width; self.height = height }
    }
    public static let sizes = [Size(width: 1280, height: 720), Size(width: 1920, height: 1080), Size(width: 2560, height: 1440)]
    public static let rates: [UInt8] = [30, 60]
    /// Mbit/s.
    public static let bitrates = [10, 20, 30, 50, 80, 100, 150, 200]
    /// Milliseconds.
    public static let buffers = [10, 25, 50, 75, 100]

    /// `list`, and `current` as its own last entry when it is not in it (else a picker shows nothing selected).
    public static func list<T: Hashable>(_ list: [T], current: T) -> [T] { list.contains(current) ? list : list + [current] }

    public static func sizes(for s: ClientSettings) -> [Size] { list(sizes, current: Size(width: s.maxWidth, height: s.maxHeight)) }
    public static func rates(for s: ClientSettings) -> [UInt8] { list(rates, current: s.maxFps) }
    public static func bitrates(for s: ClientSettings) -> [Int] { list(bitrates, current: s.bitrateMbps) }
    public static func buffers(for s: ClientSettings) -> [Int] { list(buffers, current: s.audioBufferMs) }
}
