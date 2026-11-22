import Foundation

public struct AssembledFrame: Equatable, Sendable {
    public var frame: UInt32, key: Bool, captureNs: UInt64, width: UInt16, height: UInt16, data: Data
    /// The tap marked it a repair frame (predicted from an acknowledged frame).
    public var repair: Bool
    public init(frame: UInt32, key: Bool, repair: Bool = false, captureNs: UInt64, width: UInt16, height: UInt16, data: Data) {
        self.frame = frame; self.key = key; self.repair = repair; self.captureNs = captureNs
        self.width = width; self.height = height; self.data = data
    }
}

/// Cuts one encoded frame into video fragments -> .claude/portalkit.md § video
public enum FrameSplitter {
    /// Every payload but the last is exactly `Wire.maxVideoPayload`; empty data is one empty fragment.
    public static func split(frame: UInt32, key: Bool, repair: Bool = false, captureNs: UInt64, width: UInt16, height: UInt16,
                             data: Data) -> [VideoFragment] {
        let size = Wire.maxVideoPayload
        let count = max(1, (data.count + size - 1) / size)
        precondition(count <= Int(UInt16.max), "frame exceeds 65535 fragments")
        return (0..<count).map { i in
            let start = data.startIndex + i * size
            let end = min(start + size, data.endIndex)
            return VideoFragment(frame: frame, index: UInt16(i), count: UInt16(count), key: key, repair: repair, captureNs: captureNs,
                                 width: width, height: height, payload: Data(data[start..<end]))
        }
    }
}
