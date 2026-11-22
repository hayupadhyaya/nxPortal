import CryptoKit
import Foundation

/// -> .claude/portalkit.md § pairing
public enum PairingLimits {
    public static let tries = 3
    public static let lifetime: TimeInterval = 120
}

public enum PairingCode {
    /// Uniform over 0...999999, zero-padded to 6 ASCII digits.
    public static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let n = UInt32.random(in: 0...999_999, using: &rng)
        let s = String(n)
        return String(repeating: "0", count: 6 - s.count) + s
    }
}

public enum PairingError: Error, Equatable { case hostProofInvalid, refused(PairResult) }

/// The key and proof inputs both sides compute identically.
private struct PairingTranscript {
    let macKey: SymmetricKey
    let input: Data

    init(code: String, clientKey: Data, clientEphemeral: Data, hostKey: Data, hostEphemeral: Data,
         salt: Data, ownEphemeral: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data) throws {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let secret = try ownEphemeral.sharedSecretFromKeyAgreement(with: peer)
        macKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("nxportal pair".utf8), outputByteCount: 32)
        input = Data(code.utf8) + clientKey + clientEphemeral + hostKey + hostEphemeral
    }

    var clientProof: Data { Data(HMAC<SHA256>.authenticationCode(for: input, using: macKey)) }
    var hostProof: Data { Data(HMAC<SHA256>.authenticationCode(for: input + Data("host".utf8), using: macKey)) }

    func clientProofIsValid(_ proof: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input, using: macKey)
    }
    func hostProofIsValid(_ proof: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input + Data("host".utf8), using: macKey)
    }
}

public struct PairingHost {
    private let identity: Identity
    private let name: String
    private let code: String
    private let startedAt: Date
    private var triesLeft = PairingLimits.tries
    private var locked = false
    private var succeeded = false
    private var transcript: PairingTranscript?
    private var pendingPeer: PairedPeer?
    public private(set) var paired: PairedPeer?

    public init(identity: Identity, name: String, code: String, startedAt: Date) {
        self.identity = identity; self.name = name; self.code = code; self.startedAt = startedAt
    }

    /// A repeat call replaces the exchange; tries and start time are kept.
    public mutating func challenge(for start: PairStart) throws -> PairChallenge {
        var rng = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        return try challenge(for: start, ephemeral: Curve25519.KeyAgreement.PrivateKey(), salt: salt)
    }

    /// The same with the random parts given (known-answer tests).
    mutating func challenge(for start: PairStart, ephemeral: Curve25519.KeyAgreement.PrivateKey, salt: Data) throws -> PairChallenge {
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: start.clientKey)
        let hostEphemeral = ephemeral.publicKey.rawRepresentation
        transcript = try PairingTranscript(
            code: code, clientKey: start.clientKey, clientEphemeral: start.clientEphemeral,
            hostKey: identity.publicKey, hostEphemeral: hostEphemeral, salt: salt,
            ownEphemeral: ephemeral, peerEphemeral: start.clientEphemeral)
        pendingPeer = PairedPeer(key: start.clientKey, name: DeviceName.clean(start.name) ?? DeviceName.fallback)
        return PairChallenge(hostKey: identity.publicKey, hostEphemeral: hostEphemeral, salt: salt, hostName: name)
    }

    public mutating func verify(proof: Data, at now: Date) -> PairResult {
        if locked || succeeded { return .locked }
        if now > startedAt.addingTimeInterval(PairingLimits.lifetime) { return .expired }
        if let transcript, let pendingPeer, transcript.clientProofIsValid(proof) {
            succeeded = true
            paired = pendingPeer
            return .ok(hostProof: transcript.hostProof)
        }
        triesLeft -= 1
        if triesLeft <= 0 { locked = true; return .locked }
        return .wrongCode(triesLeft: triesLeft)
    }
}

public struct PairingClient {
    private let identity: Identity
    private let name: String
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var transcript: PairingTranscript?
    private var host: PairedPeer?

    public init(identity: Identity, name: String) { self.identity = identity; self.name = name }

    public mutating func start() -> PairStart { start(ephemeral: Curve25519.KeyAgreement.PrivateKey()) }

    /// The same with the ephemeral key given (known-answer tests).
    mutating func start(ephemeral e: Curve25519.KeyAgreement.PrivateKey) -> PairStart {
        ephemeral = e
        return PairStart(clientKey: identity.publicKey, clientEphemeral: e.publicKey.rawRepresentation, name: name)
    }

    public mutating func proof(for challenge: PairChallenge, code: String) throws -> Data {
        guard let ephemeral else { throw WireError.malformed }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: challenge.hostKey)
        let t = try PairingTranscript(
            code: code, clientKey: identity.publicKey, clientEphemeral: ephemeral.publicKey.rawRepresentation,
            hostKey: challenge.hostKey, hostEphemeral: challenge.hostEphemeral, salt: challenge.salt,
            ownEphemeral: ephemeral, peerEphemeral: challenge.hostEphemeral)
        transcript = t
        host = PairedPeer(key: challenge.hostKey, name: challenge.hostName)
        return t.clientProof
    }

    public func finish(_ result: PairResult) throws -> PairedPeer {
        guard case let .ok(hostProof) = result else { throw PairingError.refused(result) }
        guard let transcript, let host, transcript.hostProofIsValid(hostProof) else {
            throw PairingError.hostProofInvalid
        }
        return host
    }
}
