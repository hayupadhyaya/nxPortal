import CryptoKit
import Foundation

public enum SealError: Error, Equatable { case tampered, replayed, wrongSession, malformed }

private let tagSize = 16
private let headerSize = 16

/// 4 zero bytes, then the u64 counter little-endian.
private func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
    var w = ByteWriter()
    w.u32(0); w.u64(counter)
    return try! ChaChaPoly.Nonce(data: w.data)  // always 12 bytes
}

private func seal(_ plaintext: Data, key: SymmetricKey, counter: UInt64, aad: Data) throws -> Data {
    let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(counter), authenticating: aad)
    return Data(box.ciphertext + box.tag)  // rebased to index 0
}

private func open(_ sealed: Data, key: SymmetricKey, counter: UInt64, aad: Data) throws -> Data {
    guard sealed.count >= tagSize else { throw SealError.malformed }
    let split = sealed.endIndex - tagSize
    do {
        let box = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: sealed[sealed.startIndex..<split],
                                           tag: sealed[split...])
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    } catch {
        throw SealError.tampered
    }
}

/// Control stream, one direction: ciphertext || tag; the counter is implicit and in order.
public struct StreamSealer {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    public init(key: SymmetricKey) { self.key = key }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let out = try PortalKit.seal(plaintext, key: key, counter: counter, aad: Data())
        counter += 1
        return out
    }
}

public struct StreamOpener {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    public init(key: SymmetricKey) { self.key = key }

    /// Advances only on success.
    public mutating func open(_ sealed: Data) throws -> Data {
        let out = try PortalKit.open(sealed, key: key, counter: counter, aad: Data())
        counter += 1
        return out
    }
}

/// `u8 type | u8 recoveryGroup (0) | u16 0 | u32 sessionID | u64 counter | ciphertext | tag`; header is AAD.
public struct DatagramSealer {
    private let key: SymmetricKey
    private let sessionID: UInt32
    private var counter: UInt64 = 0
    public init(key: SymmetricKey, sessionID: UInt32) { self.key = key; self.sessionID = sessionID }

    public mutating func seal(type: UInt8, body: Data) throws -> Data {
        var w = ByteWriter()
        w.u8(type); w.u8(0); w.u16(0); w.u32(sessionID); w.u64(counter)
        let header = w.data
        let sealed = try PortalKit.seal(body, key: key, counter: counter, aad: header)
        counter += 1
        return header + sealed
    }
}

public struct DatagramOpener {
    private let key: SymmetricKey
    private let sessionID: UInt32
    private var highest: UInt64?
    private var mask: UInt64 = 0  // bit i set = counter (highest - i) seen
    public init(key: SymmetricKey, sessionID: UInt32) { self.key = key; self.sessionID = sessionID }

    /// The replay window moves only after authentication succeeds.
    public mutating func open(_ datagram: Data) throws -> (type: UInt8, body: Data) {
        guard datagram.count >= headerSize + tagSize else { throw SealError.malformed }
        var r = ByteReader(datagram)
        let type = try r.u8(); _ = try r.u8(); _ = try r.u16()
        let session = try r.u32()
        let counter = try r.u64()
        guard session == sessionID else { throw SealError.wrongSession }
        if let highest, counter <= highest {
            let d = highest - counter
            if d > 63 || mask & (1 << d) != 0 { throw SealError.replayed }
        }
        let body = try PortalKit.open(Data(datagram.dropFirst(headerSize)), key: key, counter: counter,
                                      aad: Data(datagram.prefix(headerSize)))
        if let h = highest, counter <= h {
            mask |= 1 << (h - counter)
        } else {
            let shift = counter - (highest ?? counter)
            mask = shift >= 64 ? 0 : mask << shift
            mask |= 1
            highest = counter
        }
        return (type, body)
    }
}
