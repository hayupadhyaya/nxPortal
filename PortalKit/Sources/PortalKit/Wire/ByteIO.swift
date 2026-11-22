import Foundation

/// Little-endian packing helpers shared by the wire files; internal.
struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { append(v) }
    mutating func u32(_ v: UInt32) { append(v) }
    mutating func u64(_ v: UInt64) { append(v) }
    mutating func i32(_ v: Int32) { append(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { append(v.bitPattern) }
    mutating func vec3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    mutating func bytes(_ d: Data) { data.append(d) }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var pos: Int

    init(_ data: Data) { self.data = data; self.pos = data.startIndex }

    var remaining: Int { data.endIndex - pos }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw WireError.malformed
        }
    }
    mutating func u16() throws -> UInt16 { try int() }
    mutating func u32() throws -> UInt32 { try int() }
    mutating func u64() throws -> UInt64 { try int() }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func vec3() throws -> SIMD3<Float> { SIMD3(try f32(), try f32(), try f32()) }
    mutating func bytes(_ n: Int) throws -> Data { try take(n) }
    /// The rest of the message.
    mutating func rest() -> Data { let d = Data(data[pos...]); pos = data.endIndex; return d }
    /// Throws `.malformed` when bytes are left over.
    func finish() throws { if remaining != 0 { throw WireError.malformed } }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw WireError.malformed }
        defer { pos += n }
        return Data(data[pos..<pos + n])  // rebased to index 0
    }

    private mutating func int<T: FixedWidthInteger>() throws -> T {
        let s = try take(MemoryLayout<T>.size)
        var v: T = 0
        for (i, b) in s.enumerated() { v |= T(truncatingIfNeeded: b) << (8 * i) }
        return v
    }
}

/// u32-LE length-prefixed message buffer; both framers use it.
/// Dead after the first error: later pushes rethrow it.
struct LengthPrefixedBuffer {
    let maxMessage: Int
    private var buffer = Data()
    private var failure: WireError?

    init(maxMessage: Int) { self.maxMessage = maxMessage }

    static func frame(_ payload: Data) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        return w.data
    }

    mutating func fail(_ e: WireError) -> WireError { failure = e; return e }

    mutating func push(_ bytes: Data) throws -> [Data] {
        if let failure { throw failure }
        buffer.append(bytes)
        var out: [Data] = []
        while buffer.count >= 4 {
            var r = ByteReader(buffer.prefix(4))
            let len = Int(try r.u32())
            if len == 0 { throw fail(.malformed) }
            if len > maxMessage { throw fail(.tooLarge) }
            guard buffer.count >= 4 + len else { break }
            out.append(Data(buffer.dropFirst(4).prefix(len)))
            buffer = Data(buffer.dropFirst(4 + len))
        }
        return out
    }
}
