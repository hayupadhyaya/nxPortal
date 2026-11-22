import CryptoKit
import Foundation

public enum Role: Sendable { case client, host }

/// One key per direction and channel -> .claude/portalkit.md § sealing
public struct SessionKeys: Sendable {
    public let clientToHostControl, hostToClientControl, clientToHostMedia, hostToClientMedia: SymmetricKey

    public static func derive(role: Role, identity: Identity, ephemeral: Curve25519.KeyAgreement.PrivateKey,
                              peerKey: Data, peerEphemeral: Data) throws -> SessionKeys {
        let peerStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let peerEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let ss = try identity.key.sharedSecretFromKeyAgreement(with: peerStatic)
        let se = try ephemeral.sharedSecretFromKeyAgreement(with: peerEph)
        let ikm = ss.withUnsafeBytes { Data($0) } + se.withUnsafeBytes { Data($0) }
        let own = ephemeral.publicKey.rawRepresentation
        let salt = role == .client ? own + peerEphemeral : peerEphemeral + own
        let input = SymmetricKey(data: ikm)
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt,
                                   info: Data(("nxportal v1 " + label).utf8), outputByteCount: 32)
        }
        return SessionKeys(clientToHostControl: key("c2h ctl"), hostToClientControl: key("h2c ctl"),
                           clientToHostMedia: key("c2h media"), hostToClientMedia: key("h2c media"))
    }
}
