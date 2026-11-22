import Foundation

/// Video data is 4-byte big-endian length-prefixed NAL units, as VideoToolbox emits them.
public enum HEVC {
    /// `nil` when a length overruns the buffer or fewer than 4 bytes remain for a length.
    public static func nalUnits(_ data: Data) -> [Data]? {
        var out: [Data] = []
        var pos = data.startIndex
        while pos < data.endIndex {
            guard data.endIndex - pos >= 4 else { return nil }
            let len = data[pos..<pos + 4].reduce(0) { ($0 << 8) | Int($1) }
            pos += 4
            guard len <= data.endIndex - pos else { return nil }
            out.append(Data(data[pos..<pos + len]))
            pos += len
        }
        return out
    }

    /// NAL types 32, 33, 34: the first of each; `nil` if any is missing or the data is malformed.
    public static func parameterSets(_ data: Data) -> (vps: Data, sps: Data, pps: Data)? {
        guard let nals = nalUnits(data) else { return nil }
        func first(_ type: UInt8) -> Data? {
            nals.first { !$0.isEmpty && ($0[$0.startIndex] >> 1) & 0x3F == type }
        }
        guard let vps = first(32), let sps = first(33), let pps = first(34) else { return nil }
        return (vps, sps, pps)
    }

    /// Each length replaced by `00 00 00 01`; malformed input gives empty data.
    public static func annexB(_ data: Data) -> Data {
        guard let nals = nalUnits(data) else { return Data() }
        var out = Data(capacity: data.count)
        for n in nals { out.append(contentsOf: [0, 0, 0, 1]); out.append(n) }
        return out
    }
}
